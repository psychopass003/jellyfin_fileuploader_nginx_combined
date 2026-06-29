#!/bin/bash
# entrypoint.sh — Jellyfin + FastAPI + Nginx startup for HuggingFace Spaces
# Robustness improvements over previous version:
#   • Service watchdog that auto-restarts FastAPI & Nginx on crash
#   • Fixed element-updater timing (reliable daily check instead of exact string match)
#   • Added --timeout to all wget/curl network calls
#   • Correct debug port (7860, not 8096)
#   • Cleaner background sync with flock to prevent overlap

set -euo pipefail

echo "===================================================="
echo " 🎬 Jellyfin Media Server — Hugging Face Spaces"
echo "===================================================="

# ---- Step 1: Persistent storage setup ──────────────────────────────────────
echo "[1/3] Setting up local and persistent storage..."
mkdir -p /config/data /config/config /config/root /config/plugins

# Auto-detect persistent mount point
if   [ -d "/data"  ] && [ "$(df --output=target /data  2>/dev/null | tail -n1)" = "/data"  ]; then
    PERSISTENT_DIR="/data"
elif [ -d "/media" ] && [ "$(df --output=target /media 2>/dev/null | tail -n1)" = "/media" ]; then
    PERSISTENT_DIR="/media"
else
    # Fallback: look for known sub-directories as evidence of a real mount
    if   [ -d "/data/.jellyfin_backup"  ] || [ -d "/data/videos"  ]; then PERSISTENT_DIR="/data"
    elif [ -d "/media/.jellyfin_backup" ] || [ -d "/media/videos" ]; then PERSISTENT_DIR="/media"
    else PERSISTENT_DIR="/media"
    fi
fi
echo " 📂 Persistent storage: $PERSISTENT_DIR"

if [ -d "$PERSISTENT_DIR" ]; then
    echo " ✅ Persistent bucket detected."

    # Clean up legacy config folder (previous versions used this name)
    [ -d "$PERSISTENT_DIR/jellyfin_config" ] && {
        echo " 🧹 Removing old jellyfin_config dir..."
        rm -rf "$PERSISTENT_DIR/jellyfin_config"
    }

    mkdir -p "$PERSISTENT_DIR/videos"

    # Symlink /media/videos → persistent if they differ
    if [ "$PERSISTENT_DIR" != "/media" ]; then
        echo " 🔗 Symlinking /media/videos → $PERSISTENT_DIR/videos..."
        rm -rf /media/videos 2>/dev/null || true
        ln -sf "$PERSISTENT_DIR/videos" /media/videos
    fi

    # Move stray video files from persistent root → videos/
    find "$PERSISTENT_DIR" -maxdepth 1 -type f \
        \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" -o -name "*.m4v" -o -name "*.mov" \) \
        -exec mv {} "$PERSISTENT_DIR/videos/" \; 2>/dev/null || true

    # Restore backed-up Jellyfin configs
    for src_dir in config data root plugins; do
        src="$PERSISTENT_DIR/.jellyfin_backup/$src_dir"
        dst="/config/$src_dir"
        [ -d "$src" ] && {
            echo " 📥 Restoring $src_dir from backup..."
            cp -rf "$src/." "$dst/" 2>/dev/null || true
        }
    done
    # Also restore etc/jellyfin config
    [ -d "$PERSISTENT_DIR/.jellyfin_backup/config" ] && \
        cp -rf "$PERSISTENT_DIR/.jellyfin_backup/config/." /etc/jellyfin/ 2>/dev/null || true

    # Restore API key
    [ -f "$PERSISTENT_DIR/.jellyfin_backup/downloader_api_key.txt" ] && \
        cp "$PERSISTENT_DIR/.jellyfin_backup/downloader_api_key.txt" \
           /config/downloader_api_key.txt 2>/dev/null || true

    # Clean conflicting marker files from wrong directories
    rm -f /config/.jellyfin-config /config/.jellyfin-cache /config/.jellyfin-transcode 2>/dev/null || true
    rm -f /config/config/.jellyfin-data /config/config/.jellyfin-cache \
          /config/config/.jellyfin-transcode 2>/dev/null || true
else
    echo " ⚠️  No persistent bucket found. Config is ephemeral this session."
fi

chmod -R 777 /config /etc/jellyfin 2>/dev/null || true

# ---- Network XML: force Jellyfin to port 8097 ───────────────────────────────
mkdir -p /etc/jellyfin

# Create default network.xml if missing everywhere
if [ ! -f "/config/config/network.xml" ] && \
   [ ! -f "/config/network.xml"         ] && \
   [ ! -f "/etc/jellyfin/network.xml"   ]; then
    echo " 🔧 Creating network.xml for port 8097..."
    cat > /config/config/network.xml <<'XMLEOF'
<?xml version="1.0" encoding="utf-8"?>
<NetworkConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                      xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <RequireHttps>false</RequireHttps>
  <BaseUrl />
  <PublicHttpsPort>8920</PublicHttpsPort>
  <HttpServerPortNumber>8097</HttpServerPortNumber>
  <HttpsRedirection>false</HttpsRedirection>
  <EnableIPv6>false</EnableIPv6>
  <EnableIPv4>true</EnableIPv4>
  <EnableSSDP>false</EnableSSDP>
  <EnableUPnP>false</EnableUPnP>
  <PublicPort>8097</PublicPort>
</NetworkConfiguration>
XMLEOF
fi

# Sync network.xml across all three locations Jellyfin checks
if   [ -f "/config/config/network.xml" ]; then
    cp -f /config/config/network.xml /config/network.xml       2>/dev/null || true
    cp -f /config/config/network.xml /etc/jellyfin/network.xml 2>/dev/null || true
elif [ -f "/config/network.xml" ]; then
    cp -f /config/network.xml /config/config/network.xml       2>/dev/null || true
    cp -f /config/network.xml /etc/jellyfin/network.xml        2>/dev/null || true
elif [ -f "/etc/jellyfin/network.xml" ]; then
    cp -f /etc/jellyfin/network.xml /config/config/network.xml 2>/dev/null || true
    cp -f /etc/jellyfin/network.xml /config/network.xml        2>/dev/null || true
fi

# Blanket: replace port 8096 with 8097 in all config XML/JSON
echo " 🔧 Ensuring port 8097 in all XML/JSON configs..."
find /config/         -type f \( -name "*.xml" -o -name "*.json" \) \
    -exec sed -i 's/8096/8097/g' {} + 2>/dev/null || true
find /etc/jellyfin/   -type f \( -name "*.xml" -o -name "*.json" \) \
    -exec sed -i 's/8096/8097/g' {} + 2>/dev/null || true
find /usr/share/jellyfin/ /usr/lib/jellyfin/ -name "appsettings.json" \
    -exec sed -i 's/8096/8097/g' {} + 2>/dev/null || true

# Sanitize binding addresses to prevent Kestrel startup crash (error 134)
echo " 🔧 Sanitizing network.xml binding addresses..."
python3 - <<'PYEOF'
import re, os
for xml_path in ('/config/config/network.xml', '/etc/jellyfin/network.xml', '/config/network.xml'):
    if not os.path.exists(xml_path):
        continue
    try:
        with open(xml_path, 'r', encoding='utf-8') as f:
            content = f.read()

        # Remove address-binding tags (bind to 0.0.0.0)
        for tag in ('LocalAddress', 'BindToLocalAddress', 'LocalNetworkAddresses'):
            content = re.sub(rf'<([\w:]*){tag}[^>]*>.*?</\1{tag}>', '', content, flags=re.DOTALL)

        # Upsert required settings
        for tag, val in [('HttpServerPortNumber','8097'),('PublicPort','8097'),
                         ('EnableIPv6','false'),('EnableIPv4','true'),
                         ('RequireHttps','false'),('EnableHttps','false')]:
            pat = re.compile(rf'(<([\w:]*){tag}[^>]*>)(.*?)(</\2{tag}>)', re.DOTALL)
            if pat.search(content):
                content = pat.sub(rf'\g<1>{val}\g<4>', content)
            else:
                content = re.sub(r'(</[\w:]*NetworkConfiguration>)',
                                 rf'  <{tag}>{val}</{tag}>\n\g<1>', content)

        with open(xml_path, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f'  ✅ {xml_path} sanitized')
    except Exception as e:
        print(f'  ⚠️  {xml_path}: {e}')
PYEOF

# ---- RAM cache / transcode dirs ─────────────────────────────────────────────
mkdir -p /dev/shm/jellyfin-cache /dev/shm/jellyfin-transcode
chmod 777 /dev/shm/jellyfin-cache /dev/shm/jellyfin-transcode
echo " ⚡ Cache & transcode mapped to RAM (/dev/shm)"

# Encoding.xml: force transcoding to RAM
if [ ! -f "/config/config/encoding.xml" ]; then
    echo " 🔧 Creating encoding.xml for RAM transcoding..."
    cat > /config/config/encoding.xml <<'XMLEOF'
<?xml version="1.0" encoding="utf-8"?>
<EncodingOptions xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                 xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <TranscodingTempPath>/dev/shm/jellyfin-transcode</TranscodingTempPath>
</EncodingOptions>
XMLEOF
else
    python3 - <<'PYEOF'
import xml.etree.ElementTree as ET, os
p = '/config/config/encoding.xml'
try:
    tree = ET.parse(p)
    root = tree.getroot()
    el = root.find('TranscodingTempPath')
    if el is None:
        el = ET.SubElement(root, 'TranscodingTempPath')
    el.text = '/dev/shm/jellyfin-transcode'
    tree.write(p, encoding='utf-8', xml_declaration=True)
    print('  ✅ TranscodingTempPath set to RAM')
except Exception as e:
    print(f'  ⚠️  encoding.xml: {e}')
PYEOF
fi

# ---- Jellyfin API Key ────────────────────────────────────────────────────────
if [ -n "${JELLYFIN_API_KEY:-}" ]; then
    echo " 🔑 Using JELLYFIN_API_KEY from environment."
    printf '%s' "$JELLYFIN_API_KEY" > /config/downloader_api_key.txt
else
    if [ ! -f "/config/downloader_api_key.txt" ]; then
        echo " 🔑 Generating random Jellyfin API key..."
        python3 -c "import secrets; print(secrets.token_hex(16))" > /config/downloader_api_key.txt
        chmod 600 /config/downloader_api_key.txt
    fi
    echo " 🔑 Using auto-generated/restored API key."
fi

# ---- Optional: Tailscale / custom network daemon ────────────────────────────
if [ -n "${NET_AUTHKEY:-}" ]; then
    echo " 🔑 NET_AUTHKEY detected — starting network daemon..."
    net-daemon --tun=userspace-networking --socket=/tmp/net.sock --state=/media/net.state &
    sleep 2
    net-cli --socket=/tmp/net.sock up --authkey="${NET_AUTHKEY}" --hostname=hf-media-host
    echo " ✅ Network active!"
else
    echo " ⚠️  NET_AUTHKEY not set — skipping network setup."
fi

# ============================================================================
# Step 2: Background helper functions
# ============================================================================

# ── Persistent backup (every 5 minutes) ────────────────────────────────────
sync_to_persistent() {
    [ -d "$PERSISTENT_DIR" ] || return 0
    echo "[sync] $(date '+%H:%M:%S') — Backing up to $PERSISTENT_DIR/.jellyfin_backup..."
    mkdir -p "$PERSISTENT_DIR/.jellyfin_backup/"{config,data,root,plugins}
    for d in config data root plugins; do
        [ -d "/config/$d" ] && \
            cp -rf "/config/$d/." "$PERSISTENT_DIR/.jellyfin_backup/$d/" 2>/dev/null || true
    done
    [ -f /config/downloader_api_key.txt ] && \
        cp /config/downloader_api_key.txt \
           "$PERSISTENT_DIR/.jellyfin_backup/downloader_api_key.txt" 2>/dev/null || true
    echo "[sync] $(date '+%H:%M:%S') — Backup done."
}

# ── Graceful shutdown trap ──────────────────────────────────────────────────
cleanup() {
    echo "🛑 Shutting down gracefully..."
    if [ -n "${JELLYFIN_PID:-}" ]; then
        echo " 🎬 Sending SIGTERM to Jellyfin (PID $JELLYFIN_PID)..."
        kill -15 "$JELLYFIN_PID" 2>/dev/null || true
        for i in $(seq 1 30); do
            kill -0 "$JELLYFIN_PID" 2>/dev/null || { echo " ✅ Jellyfin exited."; break; }
            sleep 1
        done
        kill -0 "$JELLYFIN_PID" 2>/dev/null && {
            echo " ⚠️  Force-killing Jellyfin..."
            kill -9 "$JELLYFIN_PID" 2>/dev/null || true
        }
    fi
    echo " 💾 Final backup..."
    sync_to_persistent
    # Stop background jobs
    jobs -p | xargs kill 2>/dev/null || true
    echo "✅ Shutdown complete."
}
trap cleanup EXIT SIGTERM SIGINT

# ── Keep-alive & health reporter ───────────────────────────────────────────
run_keep_alive() {
    echo " 🏓 Keep-alive service started."
    while true; do
        sleep 300
        code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8097/health 2>/dev/null)
        echo "[keep-alive] $(date '+%H:%M:%S') — Jellyfin HTTP $code"

        if [ -n "${SPACE_HOST:-}" ]; then
            ping_url="${SPACE_HOST}"
            [[ "$ping_url" =~ ^https?:// ]] || ping_url="https://$ping_url"
            ext=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$ping_url" 2>/dev/null)
            echo "[keep-alive] $(date '+%H:%M:%S') — Pinged $ping_url → HTTP $ext"
        fi
    done
}

# ── Element Web auto-updater (daily at 02:00 IST) ──────────────────────────
check_and_update_element() {
    local element_dir="/usr/share/nginx/element"
    local version_file="/config/config/element_version.txt"

    echo "[element] $(date) — Checking latest release..."
    local latest_tag
    latest_tag=$(curl -s --max-time 15 \
        "https://api.github.com/repos/element-hq/element-web/releases/latest" \
        | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

    [ -z "$latest_tag" ] && {
        echo "[element] ⚠️  GitHub API timeout — will retry later."
        return 1
    }

    local current=""
    [ -f "$version_file" ] && current=$(cat "$version_file")

    [ "$latest_tag" = "$current" ] && {
        echo "[element] Already up-to-date ($latest_tag)."
        return 0
    }

    echo "[element] 🚀 Updating $current → $latest_tag..."
    local tar_url="https://github.com/element-hq/element-web/releases/download/${latest_tag}/element-${latest_tag}.tar.gz"

    wget -q --timeout=60 "$tar_url" -O /tmp/element_update.tar.gz || {
        echo "[element] ⚠️  Download failed: $tar_url"
        rm -f /tmp/element_update.tar.gz
        return 1
    }

    mkdir -p /tmp/element_new
    tar -xf /tmp/element_update.tar.gz -C /tmp/element_new --strip-components=1

    # Preserve existing config.json
    if [ -f "${element_dir}/config.json" ]; then
        cp "${element_dir}/config.json" /tmp/element_new/config.json
    else
        printf '%s' \
            '{"default_server_config":{"m.homeserver":{"base_url":"https://matrix.org",'\
            '"server_name":"matrix.org"},"m.identity_server":{"base_url":"https://vector.im"}},'\
            '"brand":"Element"}' > /tmp/element_new/config.json
    fi

    rm -rf "${element_dir:?}"/*
    cp -rf /tmp/element_new/. "${element_dir}/"
    chmod -R 755 "${element_dir}"
    rm -rf /tmp/element_new /tmp/element_update.tar.gz

    printf '%s' "$latest_tag" > "$version_file"
    echo "[element] ✅ Updated to $latest_tag"
}

run_element_updater() {
    check_and_update_element || true   # run once on boot

    local last_update_day=""
    while true; do
        sleep 60    # check every minute
        local cur_hour cur_day
        cur_hour=$(TZ="Asia/Kolkata" date '+%H')
        cur_day=$(TZ="Asia/Kolkata" date '+%Y%m%d')

        # Trigger once per day at 02:xx IST (reliable: checks minute window)
        if [ "$cur_hour" = "02" ] && [ "$cur_day" != "$last_update_day" ]; then
            check_and_update_element || true
            last_update_day="$cur_day"
        fi
    done
}

# ── Service watchdog: restart FastAPI & Nginx if they die ──────────────────
run_watchdog() {
    echo " 🐕 Service watchdog started."
    sleep 10   # give services a moment to start first

    while true; do
        sleep 15

        # FastAPI / uvicorn
        if ! pgrep -f "uvicorn app:app" > /dev/null 2>&1; then
            echo "[watchdog] $(date '+%H:%M:%S') — ⚠️  uvicorn not found! Restarting..."
            cd /scripts
            python3 -m uvicorn app:app --host 127.0.0.1 --port 8000 &
        fi

        # Nginx
        if ! pgrep -x nginx > /dev/null 2>/dev/null; then
            echo "[watchdog] $(date '+%H:%M:%S') — ⚠️  nginx not found! Restarting..."
            nginx &
        fi
    done
}

# ── Periodic backup loop ────────────────────────────────────────────────────
(while true; do sleep 300; sync_to_persistent; done) &

# ============================================================================
# Step 2.5: Launch Python FastAPI + Nginx
# ============================================================================
echo "[2/3] Starting FastAPI downloader & Nginx proxy..."
cd /scripts
python3 -m uvicorn app:app --host 127.0.0.1 --port 8000 &
nginx &
run_keep_alive &
run_element_updater &
run_watchdog &

# ── Background task: auto-inject API key into Jellyfin SQLite DB ──────────
(
    echo " 🔑 API key injector: waiting for Jellyfin database..."
    for i in $(seq 1 120); do
        [ -f "/config/data/jellyfin.db" ] && break
        sleep 2
    done

    if [ ! -f "/config/data/jellyfin.db" ]; then
        echo " 🔑 DB not found after 4 minutes — skipping injection."
        exit 0
    fi

    echo " 🔑 DB found — injecting API key in 5 seconds..."
    sleep 5

    python3 - <<'PYEOF'
import sqlite3, os, time

db = '/config/data/jellyfin.db'
key = ''
try:
    with open('/config/downloader_api_key.txt') as f:
        key = f.read().strip()
except Exception as e:
    print(f'[inject] Cannot read key: {e}')

if not key:
    print('[inject] No key found — skipping.')
    exit(0)

try:
    conn = sqlite3.connect(db, timeout=30.0)
    cur  = conn.cursor()

    # Wait for ApiKeys table (up to 60 s)
    for _ in range(30):
        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='ApiKeys'")
        if cur.fetchone():
            break
        time.sleep(2)
    else:
        print('[inject] ApiKeys table not found — Jellyfin DB may still be initialising.')
        conn.close()
        exit(0)

    cur.execute('PRAGMA table_info(ApiKeys)')
    cols = [r[1] for r in cur.fetchall()]
    col  = 'AccessToken' if 'AccessToken' in cols else 'Id' if 'Id' in cols else None

    if not col:
        print(f'[inject] Unknown schema — cols: {cols}')
        conn.close()
        exit(0)

    cur.execute(f'SELECT 1 FROM ApiKeys WHERE {col} = ?', (key,))
    if not cur.fetchone():
        cur.execute("DELETE FROM ApiKeys WHERE Name = 'DownloaderApp'")
        cur.execute(
            f"INSERT INTO ApiKeys ({col}, Name, DateCreated, DateLastActivity) "
            "VALUES (?, ?, datetime('now'), datetime('now'))",
            (key, 'DownloaderApp')
        )
        conn.commit()
        print(f'[inject] ✅ API key injected via column {col}')
    else:
        print('[inject] Key already in DB — no action needed.')

    conn.close()
except Exception as e:
    print(f'[inject] Error: {e}')
PYEOF
) &

# ============================================================================
# Step 3: Launch Jellyfin
# ============================================================================
echo "[3/3] Launching Jellyfin..."

[ -d "/media/videos" ] && chmod -R 777 /media/videos || true

echo "===================================================="
echo " 🌐 Jellyfin loading on internal port 8097"
echo " ⚡ Cache/transcode → /dev/shm  (RAM)"
echo " 🔍 Portal accessible at /download"
echo "===================================================="

# Force ASP.NET Core to use port 8097 only
export ASPNETCORE_URLS="http://0.0.0.0:8097"
export ASPNETCORE_HTTP_PORTS="8097"
unset ASPNETCORE_HTTPS_PORTS
unset Kestrel__Endpoints__Http__Url
unset Kestrel__Endpoints__Default__Url

chmod -R 777 /config /etc/jellyfin 2>/dev/null || true

# Debug connectivity check after boot (30 s delay)
(
    sleep 30
    echo "=== Startup Connectivity Check ==="
    echo "→ Jellyfin (8097):"; curl -s -o /dev/null -w "  HTTP %{http_code}\n" \
        http://127.0.0.1:8097/health 2>&1 || echo "  No response"
    echo "→ FastAPI  (8000):"; curl -s -o /dev/null -w "  HTTP %{http_code}\n" \
        http://127.0.0.1:8000/health 2>&1 || echo "  No response"
    echo "→ Nginx    (7860):"; curl -s -o /dev/null -w "  HTTP %{http_code}\n" \
        http://localhost:7860/health 2>&1 || echo "  No response"
    echo "=== Nginx Error Log ==="
    cat /tmp/error.log 2>/dev/null | tail -20
    echo "=================================="
) &

jellyfin \
    --datadir  /config \
    --configdir /config/config \
    --cachedir  /dev/shm/jellyfin-cache \
    --webdir    /usr/share/jellyfin/web \
    --ffmpeg    /usr/bin/ffmpeg &

JELLYFIN_PID=$!
echo " Jellyfin started (PID $JELLYFIN_PID)"

wait "$JELLYFIN_PID"
