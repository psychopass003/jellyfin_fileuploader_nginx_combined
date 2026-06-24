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

    # Clean up old corrupted jellyfin_config folder (from previous versions)
    if [ -d "/media/jellyfin_config" ]; then
        echo "  🧹 Removing old jellyfin_config folder..."
        rm -rf /media/jellyfin_config
    fi

    # Automatically create a videos subdirectory to separate media from backups
    mkdir -p /media/videos
    echo "  📁 Checking for media files in root /media to reorganize..."
    find /media -maxdepth 1 -type f \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" -o -name "*.m4v" -o -name "*.mov" \) -exec mv {} /media/videos/ \; 2>/dev/null || true

    # Restore configuration files if they exist
    if [ -d "/media/.jellyfin_backup/config" ]; then
        echo "  📥 Restoring configuration from backup..."
        cp -rf /media/.jellyfin_backup/config/. /config/config/ 2>/dev/null || true
    fi

    # Restore data folder (including database, collections, etc.)
    if [ -d "/media/.jellyfin_backup/data" ]; then
        echo "  📥 Restoring database and data from backup..."
        cp -rf /media/.jellyfin_backup/data/. /config/data/ 2>/dev/null || true
    fi

    # Restore downloader api key if it exists
    if [ -f "/media/.jellyfin_backup/downloader_api_key.txt" ]; then
        echo "  📥 Restoring Jellyfin API key from backup..."
        cp /media/.jellyfin_backup/downloader_api_key.txt /config/downloader_api_key.txt 2>/dev/null || true
    fi

    # Restore root folder (library definitions)
    if [ -d "/media/.jellyfin_backup/root" ]; then
        echo "  📥 Restoring library root structure from backup..."
        cp -rf /media/.jellyfin_backup/root/. /config/root/ 2>/dev/null || true
    fi

    # Restore plugins
    if [ -d "/media/.jellyfin_backup/plugins" ]; then
        echo "  📥 Restoring plugins from backup..."
        cp -rf /media/.jellyfin_backup/plugins/. /config/plugins/ 2>/dev/null || true
    fi
else
    echo "  ⚠️  No persistent storage bucket detected at /media!"
    echo "     Your configuration and user accounts will be ephemeral."
fi

# ---- PORT ROUTING CONFIGURATION (Change Jellyfin to 8097) ----
# Create a network.xml if it doesn't exist, or replace all 8096 ports in all XML files to 8097
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

# Clean up any network bind addresses from backup settings to prevent Kestrel startup crash (error 134)
if [ -f "/config/config/network.xml" ]; then
    echo "  🔧 Sanitizing network.xml bindings to prevent startup crash..."
    python3 -c "
import xml.etree.ElementTree as ET
import os
xml_path = '/config/config/network.xml'
try:
    tree = ET.parse(xml_path)
    root = tree.getroot()
    
    # Remove binding limits so it binds to 0.0.0.0
    for tag in ['LocalAddress', 'BindToLocalAddress', 'LocalNetworkAddresses']:
        elem = root.find(tag)
        if elem is not None:
            root.remove(elem)
            
    # Force default safe values
    for tag, val in [('HttpServerPortNumber', '8097'), ('PublicPort', '8097'), ('EnableIPv6', 'false'), ('EnableIPv4', 'true'), ('RequireHttps', 'false'), ('EnableHttps', 'false')]:
        elem = root.find(tag)
        if elem is None:
            elem = ET.SubElement(root, tag)
        elem.text = val
        
    tree.write(xml_path, encoding='utf-8', xml_declaration=True)
    print('  ✅ network.xml successfully sanitized.')
except Exception as e:
    print('  ⚠️ Error sanitizing network.xml:', e)
"
fi

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
    if [ -d "/media" ]; then
        echo "[sync] $(date '+%H:%M:%S') - Saving database and config to persistent bucket..."
        mkdir -p /media/.jellyfin_backup/config
        mkdir -p /media/.jellyfin_backup/data
        mkdir -p /media/.jellyfin_backup/root
        mkdir -p /media/.jellyfin_backup/plugins

        # Copy config files recursively
        if [ -d "/config/config" ]; then
            cp -rf /config/config/. /media/.jellyfin_backup/config/ 2>/dev/null || true
        fi
        
        # Copy data recursively
        if [ -d "/config/data" ]; then
            cp -rf /config/data/. /media/.jellyfin_backup/data/ 2>/dev/null || true
        fi
        
        # Backup downloader api key
        if [ -f "/config/downloader_api_key.txt" ]; then
            cp /config/downloader_api_key.txt /media/.jellyfin_backup/downloader_api_key.txt 2>/dev/null || true
        fi
        
        # Copy root recursively
        if [ -d "/config/root" ]; then
            cp -rf /config/root/. /media/.jellyfin_backup/root/ 2>/dev/null || true
        fi
        
        # Copy plugins recursively
        if [ -d "/config/plugins" ]; then
            cp -rf /config/plugins/. /media/.jellyfin_backup/plugins/ 2>/dev/null || true
        fi
        
        echo "[sync] $(date '+%H:%M:%S') - Backup saved."
    fi
}

# Trap exit signals to ensure database is written back on restart/sleep
cleanup() {
    echo "🛑 Container shutting down. Performing final backup..."
    sync_to_persistent
    echo "🧹 Stopping all background processes..."
    local pids=$(jobs -p)
    if [ -n "$pids" ]; then
        kill $pids 2>/dev/null || true
    fi
    echo "✅ Final backup completed."
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

jellyfin \
    --datadir /config \
    --configdir /config/config \
    --cachedir /dev/shm/jellyfin-cache \
    --webdir /usr/share/jellyfin/web \
    --ffmpeg /usr/bin/ffmpeg &

JELLYFIN_PID=$!

# Wait for Jellyfin process to exit
wait $JELLYFIN_PID