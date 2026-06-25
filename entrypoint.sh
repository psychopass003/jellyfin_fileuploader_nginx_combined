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
# Detect where the persistent storage is mounted (supports both /data and /media mounts)
if [ -d "/data" ] && [ "$(df --output=target /data 2>/dev/null | tail -n 1)" = "/data" ]; then
    PERSISTENT_DIR="/data"
elif [ -d "/media" ] && [ "$(df --output=target /media 2>/dev/null | tail -n 1)" = "/media" ]; then
    PERSISTENT_DIR="/media"
else
    # Fallback checks
    if [ -d "/data/.jellyfin_backup" ] || [ -d "/data/videos" ]; then
        PERSISTENT_DIR="/data"
    elif [ -d "/media/.jellyfin_backup" ] || [ -d "/media/videos" ]; then
        PERSISTENT_DIR="/media"
    else
        PERSISTENT_DIR="/media"
    fi
fi
echo "  📂 Persistent storage directory set to: $PERSISTENT_DIR"
if [ -d "$PERSISTENT_DIR" ]; then
    echo "  ✅ Persistent storage bucket detected at $PERSISTENT_DIR."
    # Clean up old corrupted jellyfin_config folder (from previous versions)
    if [ -d "$PERSISTENT_DIR/jellyfin_config" ]; then
        echo "  🧹 Removing old jellyfin_config folder..."
        rm -rf "$PERSISTENT_DIR/jellyfin_config"
    fi
    # Automatically create a videos subdirectory to separate media from backups
    mkdir -p "$PERSISTENT_DIR/videos"
    if [ "$PERSISTENT_DIR" != "/media" ]; then
        echo "  🔗 Symlinking /media/videos to $PERSISTENT_DIR/videos for unified access..."
        rm -rf /media/videos 2>/dev/null || true
        ln -sf "$PERSISTENT_DIR/videos" /media/videos
    fi
    echo "  📁 Checking for media files in root $PERSISTENT_DIR to reorganize..."
    find "$PERSISTENT_DIR" -maxdepth 1 -type f \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" -o -name "*.m4v" -o -name "*.mov" \) -exec mv {} "$PERSISTENT_DIR/videos/" \; 2>/dev/null || true
    # Restore configuration files if they exist
    if [ -d "$PERSISTENT_DIR/.jellyfin_backup/config" ]; then
        echo "  📥 Restoring configuration from backup..."
        cp -rf "$PERSISTENT_DIR/.jellyfin_backup/config/." /config/config/ 2>/dev/null || true
        cp -rf "$PERSISTENT_DIR/.jellyfin_backup/config/." /etc/jellyfin/ 2>/dev/null || true
    fi
    # Clean up conflicting marker files in the root /config folder and configdir
    # because /config is specified as --datadir, so it must only contain .jellyfin-data
    rm -f /config/.jellyfin-config /config/.jellyfin-cache /config/.jellyfin-transcode 2>/dev/null || true
    rm -f /config/config/.jellyfin-data /config/config/.jellyfin-cache /config/config/.jellyfin-transcode 2>/dev/null || true
    # Restore data folder (including database, collections, etc.)
    if [ -d "$PERSISTENT_DIR/.jellyfin_backup/data" ]; then
        echo "  📥 Restoring database and data from backup..."
        cp -rf "$PERSISTENT_DIR/.jellyfin_backup/data/." /config/data/ 2>/dev/null || true
    fi
    # Restore downloader api key if it exists
    if [ -f "$PERSISTENT_DIR/.jellyfin_backup/downloader_api_key.txt" ]; then
        echo "  📥 Restoring Jellyfin API key from backup..."
        cp "$PERSISTENT_DIR/.jellyfin_backup/downloader_api_key.txt" /config/downloader_api_key.txt 2>/dev/null || true
    fi
    # Restore root folder (library definitions)
    if [ -d "$PERSISTENT_DIR/.jellyfin_backup/root" ]; then
        echo "  📥 Restoring library root structure from backup..."
        cp -rf "$PERSISTENT_DIR/.jellyfin_backup/root/." /config/root/ 2>/dev/null || true
    fi
    # Restore plugins
    if [ -d "$PERSISTENT_DIR/.jellyfin_backup/plugins" ]; then
        echo "  📥 Restoring plugins from backup..."
        cp -rf "$PERSISTENT_DIR/.jellyfin_backup/plugins/." /config/plugins/ 2>/dev/null || true
    fi
else
    echo "  ⚠️  No persistent storage bucket detected!"
    echo "     Your configuration and user accounts will be ephemeral."
fi
# Ensure all config directories and files have open permissions for the container user (1000)
chmod -R 777 /config /etc/jellyfin 2>/dev/null || true
# ---- PORT ROUTING CONFIGURATION (Change Jellyfin to 8097) ----
# Ensure /etc/jellyfin directory exists
mkdir -p /etc/jellyfin 2>/dev/null || true
# Keep configuration files synced across all possible lookup folders
for dir in /config/config /config /etc/jellyfin; do
    mkdir -p "$dir" 2>/dev/null || true
done
# Create a default network.xml if it doesn't exist in any location
if [ ! -f "/config/config/network.xml" ] && [ ! -f "/config/network.xml" ] && [ ! -f "/etc/jellyfin/network.xml" ]; then
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
fi
# Sync config files across directories
if [ -f "/config/config/network.xml" ]; then
    cp -f /config/config/network.xml /config/network.xml 2>/dev/null || true
    cp -f /config/config/network.xml /etc/jellyfin/network.xml 2>/dev/null || true
elif [ -f "/config/network.xml" ]; then
    cp -f /config/network.xml /config/config/network.xml 2>/dev/null || true
    cp -f /config/network.xml /etc/jellyfin/network.xml 2>/dev/null || true
elif [ -f "/etc/jellyfin/network.xml" ]; then
    cp -f /etc/jellyfin/network.xml /config/config/network.xml 2>/dev/null || true
    cp -f /etc/jellyfin/network.xml /config/network.xml 2>/dev/null || true
fi
# Unconditionally replace all instances of port 8096 with 8097 in all XML and JSON configuration files
echo "  🔧 Swapping 8096 with 8097 in XML/JSON configs..."
find /config/ -type f \( -name "*.xml" -o -name "*.json" \) -exec sed -i 's/8096/8097/g' {} + 2>/dev/null || true
find /etc/jellyfin/ -type f \( -name "*.xml" -o -name "*.json" \) -exec sed -i 's/8096/8097/g' {} + 2>/dev/null || true
find /usr/share/jellyfin/ -name "appsettings.json" -exec sed -i 's/8096/8097/g' {} + 2>/dev/null || true
find /usr/lib/jellyfin/ -name "appsettings.json" -exec sed -i 's/8096/8097/g' {} + 2>/dev/null || true
# Clean up any network bind addresses from backup settings to prevent Kestrel startup crash (error 134)
# We use regex to ensure that namespace-prefixed or default-namespaced tags are correctly matched and sanitized.
echo "  🔧 Sanitizing network.xml bindings to prevent startup crash..."
python3 -c "
import re, os
for xml_path in ['/config/config/network.xml', '/etc/jellyfin/network.xml', '/config/network.xml']:
    if not os.path.exists(xml_path):
        continue
    try:
        with open(xml_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Remove binding tags to bind to 0.0.0.0
        for tag in ['LocalAddress', 'BindToLocalAddress', 'LocalNetworkAddresses']:
            content = re.sub(rf'<([\w:]*){tag}[^>]*>.*?</\1{tag}>', '', content, flags=re.DOTALL)
            
        # Update or insert required tags
        for tag, val in [('HttpServerPortNumber', '8097'), ('PublicPort', '8097'), ('EnableIPv6', 'false'), ('EnableIPv4', 'true'), ('RequireHttps', 'false'), ('EnableHttps', 'false')]:
            pattern = re.compile(rf'(<([\w:]*){tag}[^>]*>)(.*?)(</\2{tag}>)', re.DOTALL)
            if pattern.search(content):
                content = pattern.sub(rf'\g<1>{val}\g<4>', content)
            else:
                root_closing = re.compile(r'(</[\w:]*NetworkConfiguration>)')
                content = root_closing.sub(rf'  <{tag}>{val}</{tag}>\n\g<1>', content)
                
        with open(xml_path, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f'  ✅ {xml_path} successfully sanitized.')
    except Exception as e:
        print(f'  ⚠️ Error sanitizing {xml_path}:', e)
"
# Ensure local cache directories exist in RAM (/dev/shm) for ultra-speed
mkdir -p /dev/shm/jellyfin-cache
mkdir -p /dev/shm/jellyfin-transcode
chmod 777 /dev/shm/jellyfin-cache
chmod 777 /dev/shm/jellyfin-transcode
echo "  ⚡ Cache and Transcoding directories mapped to RAM (/dev/shm)"
# ---- TRANSCODING PATH CONFIGURATION (Force RAM transcoding) ----
if [ ! -f "/config/config/encoding.xml" ]; then
    echo "  🔧 Creating default encoding.xml for RAM transcoding..."
    cat <<EOF > /config/config/encoding.xml
<?xml version="1.0" encoding="utf-8"?>
<EncodingOptions xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <TranscodingTempPath>/dev/shm/jellyfin-transcode</TranscodingTempPath>
</EncodingOptions>
EOF
else
    echo "  🔧 Ensuring TranscodingTempPath is set to RAM (/dev/shm/jellyfin-transcode) in encoding.xml..."
    python3 -c "
import xml.etree.ElementTree as ET
import os
xml_path = '/config/config/encoding.xml'
try:
    tree = ET.parse(xml_path)
    root = tree.getroot()
    temp_path_elem = root.find('TranscodingTempPath')
    if temp_path_elem is None:
        temp_path_elem = ET.SubElement(root, 'TranscodingTempPath')
    temp_path_elem.text = '/dev/shm/jellyfin-transcode'
    tree.write(xml_path, encoding='utf-8', xml_declaration=True)
    print('  ✅ TranscodingTempPath set to RAM.')
except Exception as e:
    print('  ⚠️ Error updating TranscodingTempPath:', e)
"
fi
# ---- Step 2: Set up Syncing & Shutdown Traps ----
# Function to copy local database and configs back to persistent storage
sync_to_persistent() {
    if [ -d "$PERSISTENT_DIR" ]; then
        echo "[sync] $(date '+%H:%M:%S') - Saving database and config to persistent bucket at $PERSISTENT_DIR..."
        mkdir -p "$PERSISTENT_DIR/.jellyfin_backup/config"
        mkdir -p "$PERSISTENT_DIR/.jellyfin_backup/data"
        mkdir -p "$PERSISTENT_DIR/.jellyfin_backup/root"
        mkdir -p "$PERSISTENT_DIR/.jellyfin_backup/plugins"
        # Copy config files recursively
        if [ -d "/config/config" ]; then
            cp -rf /config/config/. "$PERSISTENT_DIR/.jellyfin_backup/config/" 2>/dev/null || true
        fi
        
        # Copy data recursively
        if [ -d "/config/data" ]; then
            cp -rf /config/data/. "$PERSISTENT_DIR/.jellyfin_backup/data/" 2>/dev/null || true
        fi
        
        # Backup downloader api key
        if [ -f "/config/downloader_api_key.txt" ]; then
            cp /config/downloader_api_key.txt "$PERSISTENT_DIR/.jellyfin_backup/downloader_api_key.txt" 2>/dev/null || true
        fi
        
        # Copy root recursively
        if [ -d "/config/root" ]; then
            cp -rf /config/root/. "$PERSISTENT_DIR/.jellyfin_backup/root/" 2>/dev/null || true
        fi
        
        # Copy plugins recursively
        if [ -d "/config/plugins" ]; then
            cp -rf /config/plugins/. "$PERSISTENT_DIR/.jellyfin_backup/plugins/" 2>/dev/null || true
        fi
        
        echo "[sync] $(date '+%H:%M:%S') - Backup saved."
    fi
}
# Trap exit signals to ensure database is written back on restart/sleep
cleanup() {
    echo "🛑 Container shutting down. Initiating graceful shutdown..."
    
    # 1. Send SIGTERM to Jellyfin
    if [ -n "$JELLYFIN_PID" ]; then
        echo "  🎬 Sending SIGTERM to Jellyfin (PID: $JELLYFIN_PID)..."
        kill -15 $JELLYFIN_PID 2>/dev/null || true
        
        # Wait for Jellyfin to exit (up to 30 seconds)
        echo "  ⏳ Waiting for Jellyfin to exit cleanly..."
        for i in {1..30}; do
            if ! kill -0 $JELLYFIN_PID 2>/dev/null; then
                echo "  ✅ Jellyfin exited cleanly."
                break
            fi
            sleep 1
        done
        
        # Force kill if still running after 30 seconds
        if kill -0 $JELLYFIN_PID 2>/dev/null; then
            echo "  ⚠️ Jellyfin did not exit in time. Force killing..."
            kill -9 $JELLYFIN_PID 2>/dev/null || true
        fi
    fi
    
    # 2. Now that Jellyfin has cleanly closed all DB transactions and flushed configs, sync to persistent storage
    echo "  💾 Backing up final state to persistent storage..."
    sync_to_persistent
    
    # 3. Stop other background processes (FastAPI, Nginx, keep-alive, etc.)
    echo "  🧹 Stopping other background processes..."
    local pids=$(jobs -p)
    if [ -n "$pids" ]; then
        kill $pids 2>/dev/null || true
    fi
    
    echo "✅ Graceful shutdown completed."
}
trap cleanup EXIT SIGTERM SIGINT
# ---- Helper Background Services defined as inline functions ----
run_keep_alive() {
    echo "  🏓 Keep-alive service active."
    while true; do
        sleep 300  # 5 minutes
        
        # 1. Local Health Check (helpful for Space logs)
        local HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8097/health 2>/dev/null)
        if [ "$HTTP_CODE" = "200" ]; then
            echo "[keep-alive] $(date '+%H:%M:%S') - Jellyfin healthy (HTTP $HTTP_CODE)"
        else
            echo "[keep-alive] $(date '+%H:%M:%S') - ⚠️ Jellyfin returned HTTP $HTTP_CODE"
        fi
        # 2. External Space Ping (only runs if SPACE_HOST is set in environment)
        if [ -n "$SPACE_HOST" ]; then
            local PING_URL=""
            if [[ ! "$SPACE_HOST" =~ ^https?:// ]]; then
                PING_URL="https://$SPACE_HOST"
            else
                PING_URL="$SPACE_HOST"
            fi
            
            # Ping the external URL
            local EXT_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$PING_URL" 2>/dev/null)
            echo "[keep-alive] $(date '+%H:%M:%S') - Pinged external $PING_URL (HTTP $EXT_CODE)"
        fi
    done
}
check_and_update_element() {
    local element_dir="/usr/share/nginx/element"
    local version_file="/config/config/element_version.txt"
    
    echo "[element-updater] $(date) - Checking for latest Element Web version on GitHub..."
    local latest_tag=$(curl -s https://api.github.com/repos/element-hq/element-web/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [ -z "$latest_tag" ]; then
        echo "[element-updater] ⚠️ Failed to fetch latest release version from GitHub API. Retrying later."
        return 1
    fi
    
    local current_version=""
    if [ -f "$version_file" ]; then
        current_version=$(cat "$version_file")
    fi
    
    if [ "$latest_tag" != "$current_version" ]; then
        echo "[element-updater] 🚀 New version detected: $latest_tag (Current: $current_version). Updating..."
        
        local tar_url="https://github.com/element-hq/element-web/releases/download/${latest_tag}/element-${latest_tag}.tar.gz"
        wget -q "$tar_url" -O /tmp/element_update.tar.gz
        
        if [ $? -eq 0 ] && [ -f "/tmp/element_update.tar.gz" ]; then
            mkdir -p /tmp/element_new
            tar -xf /tmp/element_update.tar.gz -C /tmp/element_new --strip-components=1
            
            if [ -f "${element_dir}/config.json" ]; then
                cp "${element_dir}/config.json" /tmp/element_new/config.json
            else
                echo '{"default_server_config":{"m.homeserver":{"base_url":"https://matrix.org","server_name":"matrix.org"},"m.identity_server":{"base_url":"https://vector.im"}},"brand":"Element"}' > /tmp/element_new/config.json
            fi
            
            rm -rf "${element_dir:?}"/*
            cp -rf /tmp/element_new/. "${element_dir}/"
            chmod -R 755 "${element_dir}"
            
            rm -rf /tmp/element_new /tmp/element_update.tar.gz
            echo -n "$latest_tag" > "$version_file"
            echo "[element-updater] ✅ Successfully updated Element Web to $latest_tag"
        else
            echo "[element-updater] ⚠️ Download failed for URL: $tar_url"
            rm -f /tmp/element_update.tar.gz
        fi
    else
        echo "[element-updater] Element Web is already up-to-date ($latest_tag)."
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
# Periodically backup database files to persistent storage every 5 minutes
(while true; do
    sleep 300
    sync_to_persistent
done) &
# ---- RESOLVE JELLYFIN API KEY ----
if [ -n "$JELLYFIN_API_KEY" ]; then
    echo "  🔑 Using JELLYFIN_API_KEY from environment."
    echo -n "$JELLYFIN_API_KEY" > /config/downloader_api_key.txt
else
    if [ ! -f "/config/downloader_api_key.txt" ]; then
        echo "  🔑 Generating new random Jellyfin API Key..."
        python3 -c "import secrets; print(secrets.token_hex(16))" > /config/downloader_api_key.txt
        chmod 600 /config/downloader_api_key.txt
    fi
    echo "  🔑 Using auto-generated/restored Jellyfin API Key from /config/downloader_api_key.txt"
fi
# ---- Step 2.3: Start Network (Optional) ----
if [ -n "$NET_AUTHKEY" ]; then
    echo "  🔑 NET_AUTHKEY detected. Starting network service..."
    
    # Run daemon in userspace mode
    net-daemon --tun=userspace-networking --socket=/tmp/net.sock --state=/media/net.state &
    
    # Wait for daemon to start
    sleep 2
    
    # Bring network up
    echo "  🌐 Authenticating and bringing network up..."
    net-cli --socket=/tmp/net.sock up --authkey="${NET_AUTHKEY}" --hostname=hf-media-host
    echo "  ✅ Network active!"
else
    echo "  ⚠️ NET_AUTHKEY not set. Skipping network setup."
fi
# ---- Step 2.5: Start Python Downloader & Nginx Proxy ----
echo "[2/3] Launching Python downloader & Nginx router..."
# Start Python FastAPI app in the background (on port 8000)
cd /scripts
python3 -m uvicorn app:app --host 127.0.0.1 --port 8000 &
# Start Nginx in the background (runs on port 8096, routing to Python and Jellyfin)
nginx &
# Start keep-alive service
run_keep_alive &
# Start Element Web auto-updater service
run_element_updater &
# ---- Step 2.7: Background task to auto-inject Jellyfin API Key into database ----
(
    echo "  🔑 API key auto-injection task started. Waiting for database to initialize..."
    for i in {1..120}; do
        if [ -f "/config/data/jellyfin.db" ]; then
            echo "  🔑 Database file detected. Injecting API key..."
            sleep 5
            
            cat << 'EOF' > /tmp/inject_key.py
import sqlite3, os, time
db_path = '/config/data/jellyfin.db'
api_key = ""
if os.path.exists('/config/downloader_api_key.txt'):
    try:
        with open('/config/downloader_api_key.txt', 'r') as f:
            api_key = f.read().strip()
    except Exception as e:
        print(f'[inject] Failed to read key file: {e}')
if not api_key:
    print('[inject] No API key found. Skipping.')
    exit(0)
try:
    conn = sqlite3.connect(db_path, timeout=30.0)
    cursor = conn.cursor()
    
    table_exists = False
    for _ in range(30):
        cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='ApiKeys'")
        if cursor.fetchone():
            table_exists = True
            break
        time.sleep(2)
        
    if not table_exists:
        print('[inject] ApiKeys table not found. Skipping auto-injection.')
        conn.close()
        exit(0)
        
    cursor.execute('PRAGMA table_info(ApiKeys)')
    columns = [row[1] for row in cursor.fetchall()]
    
    if 'AccessToken' in columns:
        cursor.execute('SELECT 1 FROM ApiKeys WHERE AccessToken = ?', (api_key,))
        if not cursor.fetchone():
            cursor.execute("DELETE FROM ApiKeys WHERE Name = 'DownloaderApp'")
            cursor.execute(
                "INSERT INTO ApiKeys (AccessToken, Name, DateCreated, DateLastActivity) VALUES (?, ?, datetime('now'), datetime('now'))",
                (api_key, 'DownloaderApp')
            )
            print('[inject] API key (AccessToken) successfully injected into Jellyfin db.')
    elif 'Id' in columns:
        cursor.execute('SELECT 1 FROM ApiKeys WHERE Id = ?', (api_key,))
        if not cursor.fetchone():
            cursor.execute("DELETE FROM ApiKeys WHERE Name = 'DownloaderApp'")
            cursor.execute(
                "INSERT INTO ApiKeys (Id, Name, DateCreated, DateLastActivity) VALUES (?, ?, datetime('now'), datetime('now'))",
                (api_key, 'DownloaderApp')
            )
            print('[inject] API key (Id) successfully injected into Jellyfin db.')
    conn.commit()
    conn.close()
except Exception as e:
    print(f'[inject] Error injecting API key: {e}')
EOF
            python3 /tmp/inject_key.py
            rm -f /tmp/inject_key.py
            break
        fi
        sleep 2
    done
) &
# ---- Step 3: Start Jellyfin Media Server ----
echo "[3/3] Launching Jellyfin..."
# FIX FILE PERMISSIONS: Automatically unlock all downloaded files so Jellyfin can read them
if [ -d "/media/videos" ]; then
    echo "  🔓 Adjusting file permissions in /media/videos..."
    chmod -R 777 /media/videos || true
fi
echo "===================================================="
echo "  🌐 Jellyfin is loading (Internal Port 8097)."
echo "  📝 Database and configurations run on local SSD"
echo "  ⚡ Caching runs on RAM (/dev/shm)"
echo "===================================================="
# Start Jellyfin in background so the shell script can catch shutdown signals
# Force ASP.NET Core environment variables to bind to internal port 8097
export ASPNETCORE_URLS="http://0.0.0.0:8097"
export ASPNETCORE_HTTP_PORTS="8097"
unset ASPNETCORE_HTTPS_PORTS
# Clear any Kestrel named endpoint configuration from the environment to avoid duplicate port bindings
unset Kestrel__Endpoints__Http__Url
unset Kestrel__Endpoints__Default__Url
# Final permission check on config folders before launching Jellyfin
chmod -R 777 /config /etc/jellyfin 2>/dev/null || true
# Debugging background task to verify local connectivity to Jellyfin
(
    sleep 15
    echo "=== Jellyfin Internal Connection Test ==="
    echo "Testing connection to 127.0.0.1:8097..."
    curl -I http://127.0.0.1:8097/health 2>&1
    echo "Testing connection to localhost:8097..."
    curl -I http://localhost:8097/health 2>&1
    echo "Testing connection to Nginx on port 7860..."
    curl -I http://localhost:8096/health 2>&1
    echo "Checking listening ports IPv4 (hex):"
    cat /proc/net/tcp 2>/dev/null | awk '{print $2}' | cut -d':' -f2 | sort | uniq
    echo "Checking listening ports IPv6 (hex):"
    cat /proc/net/tcp6 2>/dev/null | awk '{print $2}' | cut -d':' -f2 | sort | uniq
    echo "=== Nginx Error Log ==="
    cat /tmp/error.log 2>/dev/null
) &
jellyfin \
    --datadir /config \
    --configdir /config/config \
    --cachedir /dev/shm/jellyfin-cache \
    --webdir /usr/share/jellyfin/web \
    --ffmpeg /usr/bin/ffmpeg &
JELLYFIN_PID=$!
# Wait for Jellyfin process to exit
wait $JELLYFIN_PID