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
    echo "✅ Final backup completed."
}
trap cleanup EXIT SIGTERM SIGINT

# Periodically backup database files to persistent storage every 5 minutes
(while true; do
    sleep 300
    sync_to_persistent
done) &

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
/scripts/keep_alive.sh &

# ---- Step 2.7: Background task to auto-inject JELLYFIN_API_KEY into Jellyfin's database ----
(
    if [ -n "$JELLYFIN_API_KEY" ]; then
        echo "  🔑 JELLYFIN_API_KEY detected. Waiting for database to initialize..."
        for i in {1..120}; do
            if [ -f "/config/data/jellyfin.db" ]; then
                echo "  🔑 Database file detected. Injecting API key..."
                sleep 5
                
                cat << 'EOF' > /tmp/inject_key.py
import sqlite3, os, time
db_path = '/config/data/jellyfin.db'
api_key = os.environ.get('JELLYFIN_API_KEY')
if not api_key:
    print('[inject] JELLYFIN_API_KEY environment variable not set. Skipping.')
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
            cursor.execute(
                "INSERT INTO ApiKeys (AccessToken, Name, DateCreated, DateLastActivity) VALUES (?, ?, datetime('now'), datetime('now'))",
                (api_key, 'DownloaderApp')
            )
            print('[inject] API key (AccessToken) successfully injected into Jellyfin db.')
    elif 'Id' in columns:
        cursor.execute('SELECT 1 FROM ApiKeys WHERE Id = ?', (api_key,))
        if not cursor.fetchone():
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
    fi
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
jellyfin \
    --datadir /config \
    --configdir /config/config \
    --cachedir /dev/shm/jellyfin-cache \
    --webdir /usr/share/jellyfin/web \
    --ffmpeg /usr/bin/ffmpeg &

JELLYFIN_PID=$!

# Wait for Jellyfin process to exit
wait $JELLYFIN_PID