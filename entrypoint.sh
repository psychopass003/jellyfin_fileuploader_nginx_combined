#!/bin/bash
# entrypoint.sh — Jellyfin + FastAPI + Nginx startup for HuggingFace Spaces

set -euo pipefail

echo "===================================================="
echo " 🎬 Jellyfin Media Server — Hugging Face Spaces"
echo "===================================================="

# ---- Step 1: Persistent storage setup ──────────────────────────────────────
echo "[1/3] Setting up local and persistent storage..."
mkdir -p /config/data /config/config /config/root /config/plugins

if   [ -d "/data"  ] && [ "$(df --output=target /data  2>/dev/null | tail -n1)" = "/data"  ]; then
    PERSISTENT_DIR="/data"
elif [ -d "/media" ] && [ "$(df --output=target /media 2>/dev/null | tail -n1)" = "/media" ]; then
    PERSISTENT_DIR="/media"
else
    if   [ -d "/data/.jellyfin_backup"  ] || [ -d "/data/videos"  ]; then PERSISTENT_DIR="/data"
    elif [ -d "/media/.jellyfin_backup" ] || [ -d "/media/videos" ]; then PERSISTENT_DIR="/media"
    else PERSISTENT_DIR="/media"
    fi
fi
echo " 📂 Persistent storage: $PERSISTENT_DIR"

if [ -d "$PERSISTENT_DIR" ]; then
    echo " ✅ Persistent bucket detected."

    [ -d "$PERSISTENT_DIR/jellyfin_config" ] && rm -rf "$PERSISTENT_DIR/jellyfin_config"
    mkdir -p "$PERSISTENT_DIR/videos"

    if [ "$PERSISTENT_DIR" != "/media" ]; then
        echo " 🔗 Symlinking /media/videos → $PERSISTENT_DIR/videos..."
        rm -rf /media/videos 2>/dev/null || true
        ln -sf "$PERSISTENT_DIR/videos" /media/videos
    fi

    find "$PERSISTENT_DIR" -maxdepth 1 -type f \
        \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" -o -name "*.m4v" -o -name "*.mov" \) \
        -exec mv {} "$PERSISTENT_DIR/videos/" \; 2>/dev/null || true

    for src_dir in config data root plugins; do
        src="$PERSISTENT_DIR/.jellyfin_backup/$src_dir"
        dst="/config/$src_dir"
        [ -d "$src" ] && cp -rf "$src/." "$dst/" 2>/dev/null || true
    done
    
    [ -d "$PERSISTENT_DIR/.jellyfin_backup/config" ] && \
        cp -rf "$PERSISTENT_DIR/.jellyfin_backup/config/." /etc/jellyfin/ 2>/dev/null || true

    [ -f "$PERSISTENT_DIR/.jellyfin_backup/downloader_api_key.txt" ] && \
        cp "$PERSISTENT_DIR/.jellyfin_backup/downloader_api_key.txt" \
           /config/downloader_api_key.txt 2>/dev/null || true

    rm -f /config/.jellyfin-config /config/.jellyfin-cache /config/.jellyfin-transcode 2>/dev/null || true
else
    echo " ⚠️  No persistent bucket found. Config is ephemeral this session."
fi

chmod -R 777 /config /etc/jellyfin 2>/dev/null || true

# ---- RAM cache / transcode dirs ─────────────────────────────────────────────
mkdir -p /dev/shm/jellyfin-cache /dev/shm/jellyfin-transcode
chmod 777 /dev/shm/jellyfin-cache /dev/shm/jellyfin-transcode
echo " ⚡ Cache & transcode mapped to RAM (/dev/shm)"

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

# ============================================================================
# Step 2: Background helper functions
# ============================================================================

sync_to_persistent() {
    [ -d "$PERSISTENT_DIR" ] || return 0
    echo "[sync] $(date '+%H:%M:%S') — Backing up to $PERSISTENT_DIR/.jellyfin_backup..."
    mkdir -p "$PERSISTENT_DIR/.jellyfin_backup/"{config,data,root,plugins}
    for d in config data root plugins; do
        [ -d "/config/$d" ] && cp -rf "/config/$d/." "$PERSISTENT_DIR/.jellyfin_backup/$d/" 2>/dev/null || true
    done
    [ -f /config/downloader_api_key.txt ] && \
        cp /config/downloader_api_key.txt "$PERSISTENT_DIR/.jellyfin_backup/downloader_api_key.txt" 2>/dev/null || true
    echo "[sync] $(date '+%H:%M:%S') — Backup done."
}

cleanup() {
    echo "🛑 Shutting down gracefully..."
    if [ -n "${JELLYFIN_PID:-}" ]; then
        kill -15 "$JELLYFIN_PID" 2>/dev/null || true
        for i in $(seq 1 30); do
            kill -0 "$JELLYFIN_PID" 2>/dev/null || break
            sleep 1
        done
    fi
    sync_to_persistent
    jobs -p | xargs kill 2>/dev/null || true
}
trap cleanup EXIT SIGTERM SIGINT

run_keep_alive() {
    while true; do
        sleep 300
        code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8096/health 2>/dev/null)
        echo "[keep-alive] Jellyfin native status HTTP $code"
    done
}

run_watchdog() {
    echo " 🐕 Native PID-based watchdog service started."
    sleep 15
    while true; do
        sleep 15
        if [ -f /tmp/uvicorn.pid ] && ! kill -0 "$(cat /tmp/uvicorn.pid)" 2>/dev/null; then
            cd /scripts && python3 -m uvicorn app:app --host 127.0.0.1 --port 8000 & echo $! > /tmp/uvicorn.pid
        fi
        if [ -f /tmp/nginx.pid ] && ! kill -0 "$(cat /tmp/nginx.pid)" 2>/dev/null; then
            nginx &
        fi
    done
}

(while true; do sleep 300; sync_to_persistent; done) &

# ============================================================================
# Step 2.5: Launch Background Elements
# ============================================================================
echo "[2/3] Starting FastAPI downloader & Nginx proxy..."
cd /scripts
python3 -m uvicorn app:app --host 127.0.0.1 --port 8000 &
echo $! > /tmp/uvicorn.pid
nginx &

run_keep_alive &
run_watchdog &

# ── Background task: API key injector ──────────────────────────────────────
(
    for i in $(seq 1 120); do [ -f "/config/data/jellyfin.db" ] && break; sleep 2; done
    sleep 5
    python3 - <<'PYEOF'
import sqlite3, os, time
db, key = '/config/data/jellyfin.db', ''
try:
    with open('/config/downloader_api_key.txt') as f: key = f.read().strip()
except: exit(0)
try:
    conn = sqlite3.connect(db, timeout=30.0); cur = conn.cursor()
    cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='ApiKeys'")
    if cur.fetchone():
        cur.execute('PRAGMA table_info(ApiKeys)')
        cols = [r[1] for r in cur.fetchall()]
        col = 'AccessToken' if 'AccessToken' in cols else 'Id' if 'Id' in cols else None
        if col:
            cur.execute(f'SELECT 1 FROM ApiKeys WHERE {col} = ?', (key,))
            if not cur.fetchone():
                cur.execute("DELETE FROM ApiKeys WHERE Name = 'DownloaderApp'")
                cur.execute(f"INSERT INTO ApiKeys ({col}, Name, DateCreated, DateLastActivity) VALUES (?, ?, datetime('now'), datetime('now'))", (key, 'DownloaderApp'))
                conn.commit()
    conn.close()
except Exception as e: print(f'[inject] Error: {e}')
PYEOF
) &

# ============================================================================
# Step 3: Launch Native Jellyfin
# ============================================================================
echo "[3/3] Launching Jellyfin..."
cd /
mkdir -p /wwwroot
[ -d "/media/videos" ] && chmod -R 777 /media/videos || true

export ASPNETCORE_URLS="http://0.0.0.0:8096"
export ASPNETCORE_HTTP_PORTS="8096"
unset ASPNETCORE_HTTPS_PORTS

jellyfin \
    --datadir  /config \
    --configdir /config/config \
    --cachedir  /dev/shm/jellyfin-cache \
    --webdir    /usr/share/jellyfin/web \
    --ffmpeg    /usr/bin/ffmpeg &

JELLYFIN_PID=$!
wait "$JELLYFIN_PID"
