#!/bin/bash
set -e

echo "===================================================="
echo "  🎬 Jellyfin Media Server - Hugging Face Spaces"
echo "===================================================="

# ---- Step 1: Initialize Local & Persistent Directories ----
mkdir -p /config/data /config/config /config/root /config/plugins

if [ -d "/media" ]; then
    echo "  ✅ Persistent storage bucket detected at /media."
    rm -rf /media/jellyfin_config 2>/dev/null || true
    mkdir -p /media/videos
    find /media -maxdepth 1 -type f \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" -o -name "*.m4v" -o -name "*.mov" \) -exec mv {} /media/videos/ \; 2>/dev/null || true

    [ -d "/media/.jellyfin_backup/config" ] && cp -rf /media/.jellyfin_backup/config/. /config/config/ 2>/dev/null || true
    [ -d "/media/.jellyfin_backup/data" ] && cp -rf /media/.jellyfin_backup/data/. /config/data/ 2>/dev/null || true
    [ -f "/media/.jellyfin_backup/downloader_api_key.txt" ] && cp /media/.jellyfin_backup/downloader_api_key.txt /config/downloader_api_key.txt 2>/dev/null || true
    [ -d "/media/.jellyfin_backup/root" ] && cp -rf /media/.jellyfin_backup/root/. /config/root/ 2>/dev/null || true
    [ -d "/media/.jellyfin_backup/plugins" ] && cp -rf /media/.jellyfin_backup/plugins/. /config/plugins/ 2>/dev/null || true
fi

# ---- CRITICAL CLEANUP: REVERT PERSISTENT 8097 BACK TO 8096 ----
echo "  🧹 Cleaning up experimental port changes from persistent storage..."
find /config /etc /usr /opt -name "appsettings*.json" -type f -exec sed -i 's/8097/8096/g; s/8921/8920/g' {} + 2>/dev/null || true

if [ -f "/config/config/network.xml" ]; then
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
        for tag, val in [('HttpServerPortNumber', '8096'), ('PublicPort', '8096'), ('EnableIPv6', 'false'), ('EnableIPv4', 'true'), ('RequireHttps', 'false'), ('EnableHttps', 'false')]:
            elem = root.find(tag)
            if elem is None:
                elem = ET.SubElement(root, tag)
            elem.text = val
        tree.write(xml_path, encoding='utf-8', xml_declaration=True)
    except Exception as e:
        pass
"
fi

chmod -R 777 /config /etc/jellyfin 2>/dev/null || true

mkdir -p /dev/shm/jellyfin-cache /dev/shm/jellyfin-transcode
chmod 777 /dev/shm/jellyfin-cache /dev/shm/jellyfin-transcode

sync_to_persistent() {
    if [ -d "/media" ]; then
        mkdir -p /media/.jellyfin_backup/config /media/.jellyfin_backup/data /media/.jellyfin_backup/root /media/.jellyfin_backup/plugins
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
    kill $(jobs -p) 2>/dev/null || true
}
trap cleanup EXIT SIGTERM SIGINT

run_keep_alive() {
    while true; do
        sleep 300
        curl -s -o /dev/null http://localhost:8096/health || true
        [ -n "$SPACE_HOST" ] && curl -s -o /dev/null "https://$SPACE_HOST" || true
    done
}

run_element_updater() {
    while true; do
        sleep 3600
    done
}

(while true; do sleep 300; sync_to_persistent; done) &

if [ -n "$JELLYFIN_API_KEY" ]; then
    echo -n "$JELLYFIN_API_KEY" > /config/downloader_api_key.txt
elif [ ! -f "/config/downloader_api_key.txt" ]; then
    python3 -c "import secrets; print(secrets.token_hex(16))" > /config/downloader_api_key.txt
    chmod 600 /config/downloader_api_key.txt
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
import sqlite3, os
try:
    with open('/config/downloader_api_key.txt', 'r') as f: api_key = f.read().strip()
    if not api_key: exit(0)
    conn = sqlite3.connect('/config/data/jellyfin.db', timeout=30.0)
    c = conn.cursor()
    c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='ApiKeys'")
    if not c.fetchone(): exit(0)
    c.execute('PRAGMA table_info(ApiKeys)')
    cols = [row[1] for row in c.fetchall()]
    if 'AccessToken' in cols:
        c.execute("DELETE FROM ApiKeys WHERE Name = 'DownloaderApp'")
        c.execute("INSERT INTO ApiKeys (AccessToken, Name, DateCreated, DateLastActivity) VALUES (?, ?, datetime('now'), datetime('now'))", (api_key, 'DownloaderApp'))
    elif 'Id' in cols:
        c.execute("DELETE FROM ApiKeys WHERE Name = 'DownloaderApp'")
        c.execute("INSERT INTO ApiKeys (Id, Name, DateCreated, DateLastActivity) VALUES (?, ?, datetime('now'), datetime('now'))", (api_key, 'DownloaderApp'))
    conn.commit()
    conn.close()
except Exception: pass
EOF
            python3 /tmp/inject_key.py && rm -f /tmp/inject_key.py
            break
        fi
        sleep 2
    done
) &

echo "[3/3] Launching Jellyfin..."
[ -d "/media/videos" ] && chmod -R 777 /media/videos || true

echo "===================================================="
echo "  🌐 Jellyfin is loading natively (Port 8096)."
echo "===================================================="

jellyfin \
    --datadir /config \
    --configdir /config/config \
    --cachedir /dev/shm/jellyfin-cache \
    --webdir /usr/share/jellyfin/web \
    --ffmpeg /usr/bin/ffmpeg &

wait $!