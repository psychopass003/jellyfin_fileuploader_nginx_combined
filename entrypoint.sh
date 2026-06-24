#!/bin/bash
set -e

echo "===================================================="
echo "  🎬 Jellyfin Media Server - Hugging Face Spaces"
echo "===================================================="

# ---- Step 1: Initialize Local & Persistent Directories ----
echo "[1/3] Setting up local and persistent storage..."

mkdir -p /config/data
mkdir -p /config/config
mkdir -p /config/root
mkdir -p /config/plugins

# Check if the persistent storage bucket is mounted at /media
if [ -d "/media" ]; then
    echo "  ✅ Persistent storage bucket detected at /media."

    if [ -d "/media/jellyfin_config" ]; then
        echo "  🧹 Removing old jellyfin_config folder..."
        rm -rf /media/jellyfin_config
    fi

    mkdir -p /media/videos
    echo "  📁 Checking for media files in root /media to reorganize..."
    find /media -maxdepth 1 -type f \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" -o -name "*.m4v" -o -name "*.mov" \) -exec mv {} /media/videos/ \; 2>/dev/null || true

    if [ -d "/media/.jellyfin_backup/config" ]; then
        cp -rf /media/.jellyfin_backup/config/. /config/config/ 2>/dev/null || true
    fi
    if [ -d "/media/.jellyfin_backup/data" ]; then
        cp -rf /media/.jellyfin_backup/data/. /config/data/ 2>/dev/null || true
    fi
    if [ -f "/media/.jellyfin_backup/downloader_api_key.txt" ]; then
        cp /media/.jellyfin_backup/downloader_api_key.txt /config/downloader_api_key.txt 2>/dev/null || true
    fi
    if [ -d "/media/.jellyfin_backup/root" ]; then
        cp -rf /media/.jellyfin_backup/root/. /config/root/ 2>/dev/null || true
    fi
    if [ -d "/media/.jellyfin_backup/plugins" ]; then
        cp -rf /media/.jellyfin_backup/plugins/. /config/plugins/ 2>/dev/null || true
    fi
else
    echo "  ⚠️  No persistent storage bucket detected at /media!"
fi

chmod -R 777 /config /etc/jellyfin 2>/dev/null || true

# ---- PORT ROUTING CONFIGURATION ----
mkdir -p /etc/jellyfin 2>/dev/null || true

if [ ! -f "/config/config/network.xml" ]; then
    echo "  🔧 Creating default network.xml for internal port 8097..."
    cat <<EOF > /config/config/network.xml
<?xml version="1.0" encoding="utf-8"?>
<NetworkConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
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
EOF
else
    echo "  🔧 Replacing all 8096 ports with 8097 in configuration XML files..."
    find /config/config/ -name "*.xml" -exec sed -i 's/8096/8097/g' {} +
fi

cp -f /config/config/network.xml /etc/jellyfin/network.xml 2>/dev/null || true

if [ -f "/config/config/network.xml" ]; then
    echo "  🔧 Sanitizing network.xml bindings to prevent startup crash..."
    python3 -c "
import xml.etree.ElementTree as ET
import os
for xml_path in ['/config/config/network.xml', '/etc/jellyfin/network.xml']:
    if not os.path.exists(xml_path):
        continue
    try:
        tree = ET.parse(xml_path)
        root = tree.getroot()
        for tag in ['LocalAddress', 'BindToLocalAddress', 'LocalNetworkAddresses']:
            elem = root.find(tag)
            if elem is not None:
                root.remove(elem)
        for tag, val in [('HttpServerPortNumber', '8097'), ('PublicPort', '8097'), ('EnableIPv6', 'false'), ('EnableIPv4', 'true'), ('RequireHttps', 'false'), ('EnableHttps', 'false')]:
            elem = root.find(tag)
            if elem is None:
                elem = ET.SubElement(root, tag)
            elem.text = val
        tree.write(xml_path, encoding='utf-8', xml_declaration=True)
    except Exception as e:
        print(f'  ⚠️ Error sanitizing {xml_path}:', e)
"
fi

mkdir -p /dev/shm/jellyfin-cache
mkdir -p /dev/shm/jellyfin-transcode
chmod 777 /dev/shm/jellyfin-cache
chmod 777 /dev/shm/jellyfin-transcode

if [ ! -f "/config/config/encoding.xml" ]; then
    echo "  🔧 Creating default encoding.xml for RAM transcoding..."
    cat <<EOF > /config/config/encoding.xml
<?xml version="1.0" encoding="utf-8"?>
<EncodingOptions xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <TranscodingTempPath>/dev/shm/jellyfin-transcode</TranscodingTempPath>
</EncodingOptions>
EOF
else
    python3 -c "
import xml.etree.ElementTree as ET
xml_path = '/config/config/encoding.xml'
try:
    tree = ET.parse(xml_path)
    root = tree.getroot()
    temp_path_elem = root.find('TranscodingTempPath')
    if temp_path_elem is None:
        temp_path_elem = ET.SubElement(root, 'TranscodingTempPath')
    temp_path_elem.text = '/dev/shm/jellyfin-transcode'
    tree.write(xml_path, encoding='utf-8', xml_declaration=True)
except Exception: pass
"
fi

# ---- Step 2: Set up Syncing & Shutdown Traps ----
sync_to_persistent() {
    if [ -d "/media" ]; then
        mkdir -p /media/.jellyfin_backup/config
        mkdir -p /media/.jellyfin_backup/data
        mkdir -p /media/.jellyfin_backup/root
        mkdir -p /media/.jellyfin_backup/plugins
        [ -d "/config/config" ] && cp -rf /config/config/. /media/.jellyfin_backup/config/ 2>/dev/null || true
        [ -d "/config/data" ] && cp -rf /config/data/. /media/.jellyfin_backup/data/ 2>/dev/null || true
        [ -f "/config/downloader_api_key.txt" ] && cp /config/downloader_api_key.txt /media/.jellyfin_backup/downloader_api_key.txt 2>/dev/null || true
        [ -d "/config/root" ] && cp -rf /config/root/. /media/.jellyfin_backup/root/ 2>/dev/null || true
        [ -d "/config/plugins" ] && cp -rf /config/plugins/. /media/.jellyfin_backup/plugins/ 2>/dev/null || true
    fi
}

cleanup() {
    echo "🛑 Container shutting down. Performing final backup..."
    sync_to_persistent
    echo "🧹 Stopping all background processes..."
    local pids=$(jobs -p)
    [ -n "$pids" ] && kill $pids 2>/dev/null || true
    echo "✅ Final backup completed."
}
trap cleanup EXIT SIGTERM SIGINT

run_keep_alive() {
    while true; do
        sleep 300
        curl -s -o /dev/null http://localhost:8097/health || true
        if [ -n "$SPACE_HOST" ]; then
            local PING_URL="$SPACE_HOST"
            [[ ! "$SPACE_HOST" =~ ^https?:// ]] && PING_URL="https://$SPACE_HOST"
            curl -s -o /dev/null "$PING_URL" || true
        fi
    done
}

check_and_update_element() {
    local element_dir="/usr/share/nginx/element"
    local version_file="/config/config/element_version.txt"
    local latest_tag=$(curl -s https://api.github.com/repos/element-hq/element-web/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [ -z "$latest_tag" ] && return 1
    
    local current_version=""
    [ -f "$version_file" ] && current_version=$(cat "$version_file")
    
    if [ "$latest_tag" != "$current_version" ]; then
        local tar_url="https://github.com/element-hq/element-web/releases/download/${latest_tag}/element-${latest_tag}.tar.gz"
        wget -q "$tar_url" -O /tmp/element_update.tar.gz
        if [ $? -eq 0 ] && [ -f "/tmp/element_update.tar.gz" ]; then
            mkdir -p /tmp/element_new
            tar -xf /tmp/element_update.tar.gz -C /tmp/element_new --strip-components=1
            [ -f "${element_dir}/config.json" ] && cp "${element_dir}/config.json" /tmp/element_new/config.json || echo '{"default_server_config":{"m.homeserver":{"base_url":"https://matrix.org","server_name":"matrix.org"},"m.identity_server":{"base_url":"https://vector.im"}},"brand":"Element"}' > /tmp/element_new/config.json
            rm -rf "${element_dir:?}"/*
            cp -rf /tmp/element_new/. "${element_dir}/"
            chmod -R 755 "${element_dir}"
            rm -rf /tmp/element_new /tmp/element_update.tar.gz
            echo -n "$latest_tag" > "$version_file"
        fi
    fi
}

run_element_updater() {
    check_and_update_element || true
    while true; do
        local current_time=$(TZ="Asia/Kolkata" date '+%H:%M')
        if [ "$current_time" = "02:00" ]; then
            check_and_update_element || true
            sleep 70
        fi
        sleep 30
    done
}

(while true; do sleep 300; sync_to_persistent; done) &

if [ -n "$JELLYFIN_API_KEY" ]; then
    echo -n "$JELLYFIN_API_KEY" > /config/downloader_api_key.txt
else
    if [ ! -f "/config/downloader_api_key.txt" ]; then
        python3 -c "import secrets; print(secrets.token_hex(16))" > /config/downloader_api_key.txt
        chmod 600 /config/downloader_api_key.txt
    fi
fi

if [ -n "$NET_AUTHKEY" ]; then
    net-daemon --tun=userspace-networking --socket=/tmp/net.sock --state=/media/net.state &
    sleep 2
    net-cli --socket=/tmp/net.sock up --authkey="${NET_AUTHKEY}" --hostname=hf-media-host
fi

echo "[2/3] Launching Python downloader & Nginx router..."
cd /scripts
python3 -m uvicorn app:app --host 127.0.0.1 --port 8000 &
nginx &

run_keep_alive &
run_element_updater &

(
    for i in {1..120}; do
        if [ -f "/config/data/jellyfin.db" ]; then
            sleep 5
            cat << 'EOF' > /tmp/inject_key.py
import sqlite3, os, time
db_path = '/config/data/jellyfin.db'
api_key = ""
if os.path.exists('/config/downloader_api_key.txt'):
    try:
        with open('/config/downloader_api_key.txt', 'r') as f:
            api_key = f.read().strip()
    except Exception: pass
if not api_key: exit(0)
try:
    conn = sqlite3.connect(db_path, timeout=30.0)
    cursor = conn.cursor()
    cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='ApiKeys'")
    if not cursor.fetchone():
        conn.close()
        exit(0)
    cursor.execute('PRAGMA table_info(ApiKeys)')
    columns = [row[1] for row in cursor.fetchall()]
    if 'AccessToken' in columns:
        cursor.execute('SELECT 1 FROM ApiKeys WHERE AccessToken = ?', (api_key,))
        if not cursor.fetchone():
            cursor.execute("DELETE FROM ApiKeys WHERE Name = 'DownloaderApp'")
            cursor.execute("INSERT INTO ApiKeys (AccessToken, Name, DateCreated, DateLastActivity) VALUES (?, ?, datetime('now'), datetime('now'))", (api_key, 'DownloaderApp'))
    elif 'Id' in columns:
        cursor.execute('SELECT 1 FROM ApiKeys WHERE Id = ?', (api_key,))
        if not cursor.fetchone():
            cursor.execute("DELETE FROM ApiKeys WHERE Name = 'DownloaderApp'")
            cursor.execute("INSERT INTO ApiKeys (Id, Name, DateCreated, DateLastActivity) VALUES (?, ?, datetime('now'), datetime('now'))", (api_key, 'DownloaderApp'))
    conn.commit()
    conn.close()
except Exception: pass
EOF
            python3 /tmp/inject_key.py
            rm -f /tmp/inject_key.py
            break
        fi
        sleep 2
    done
) &

echo "[3/3] Launching Jellyfin..."

if [ -d "/media/videos" ]; then
    chmod -R 777 /media/videos || true
fi

# ---- PATCH JELLYFIN APPSETTINGS.JSON (Runtime belt-and-suspenders) ----
echo "  🔧 Runtime-patching Jellyfin appsettings.json: 8096 → 8097..."
_PATCHED=0
while IFS= read -r _f; do
    if grep -q "8096" "$_f" 2>/dev/null; then
        sed -i \
          's|"http://0\.0\.0\.0:8096"|"http://0.0.0.0:8097"|g;
           s|"https://0\.0\.0\.0:8096"|"https://0.0.0.0:8097"|g' \
          "$_f" && echo "  ✅ Patched: $_f" && _PATCHED=$((_PATCHED+1))
    fi
done < <(find /usr /opt -name "appsettings*.json" 2>/dev/null)
[ "$_PATCHED" -eq 0 ] && echo "  ℹ️  No appsettings.json with port 8096 found (already clean)."

echo "===================================================="
echo "  🌐 Jellyfin is loading (Internal Port 8097)."
echo "  📝 Database and configurations run on local SSD"
echo "  ⚡ Caching runs on RAM (/dev/shm)"
echo "===================================================="

# Force ASP.NET Core environment variables to bind to internal port 8097
export ASPNETCORE_URLS="http://0.0.0.0:8097"
export ASPNETCORE_HTTP_PORTS="8097"
unset ASPNETCORE_HTTPS_PORTS

# Force Kestrel endpoints via IConfiguration (definitive override path)
export Kestrel__Endpoints__http__Url="http://0.0.0.0:8097"

# CRITICAL FIX: Override the internal 'https' endpoint block to use standard HTTP 
# on a local port. This prevents Kestrel from looking for SSL certificates.
export Kestrel__Endpoints__https__Url="http://127.0.0.1:8920"

unset Kestrel__Endpoints__Http__Url
unset Kestrel__Endpoints__Default__Url

chmod -R 777 /config /etc/jellyfin 2>/dev/null || true

jellyfin \
    --datadir /config \
    --configdir /config/config \
    --cachedir /dev/shm/jellyfin-cache \
    --webdir /usr/share/jellyfin/web \
    --ffmpeg /usr/bin/ffmpeg &

JELLYFIN_PID=$!
wait $JELLYFIN_PID