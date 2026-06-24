#!/bin/bash
# ============================================================
# Element Web Auto-Updater Script
# Checks GitHub for updates daily at 2:00 AM IST (Asia/Kolkata)
# ============================================================

ELEMENT_DIR="/usr/share/nginx/element"
VERSION_FILE="/config/config/element_version.txt"

check_and_update() {
    echo "[element-updater] $(date) - Checking for latest Element Web version on GitHub..."
    
    # Fetch the latest release tag name using the GitHub API
    LATEST_TAG=$(curl -s https://api.github.com/repos/element-hq/element-web/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [ -z "$LATEST_TAG" ]; then
        echo "[element-updater] ⚠️ Failed to fetch latest release version from GitHub API. Retrying later."
        return 1
    fi
    
    CURRENT_VERSION=""
    if [ -f "$VERSION_FILE" ]; then
        CURRENT_VERSION=$(cat "$VERSION_FILE")
    fi
    
    if [ "$LATEST_TAG" != "$CURRENT_VERSION" ]; then
        echo "[element-updater] 🚀 New version detected: $LATEST_TAG (Current: $CURRENT_VERSION). Updating..."
        
        TAR_URL="https://github.com/element-hq/element-web/releases/download/${LATEST_TAG}/element-${LATEST_TAG}.tar.gz"
        wget -q "$TAR_URL" -O /tmp/element_update.tar.gz
        
        if [ $? -eq 0 ] && [ -f "/tmp/element_update.tar.gz" ]; then
            # Extract to temporary folder
            mkdir -p /tmp/element_new
            tar -xf /tmp/element_update.tar.gz -C /tmp/element_new --strip-components=1
            
            # Transfer existing config if available, otherwise generate a clean, comment-free config.json
            if [ -f "${ELEMENT_DIR}/config.json" ]; then
                cp "${ELEMENT_DIR}/config.json" /tmp/element_new/config.json
            else
                echo '{"default_server_config":{"m.homeserver":{"base_url":"https://matrix.org","server_name":"matrix.org"},"m.identity_server":{"base_url":"https://vector.im"}},"brand":"Element"}' > /tmp/element_new/config.json
            fi
            
            # Safely clear and swap files
            rm -rf "${ELEMENT_DIR:?}"/*
            cp -rf /tmp/element_new/. "${ELEMENT_DIR}/"
            chmod -R 755 "${ELEMENT_DIR}"
            
            # Clean up temporary files
            rm -rf /tmp/element_new /tmp/element_update.tar.gz
            
            # Update the stored version file
            echo -n "$LATEST_TAG" > "$VERSION_FILE"
            echo "[element-updater] ✅ Successfully updated Element Web to $LATEST_TAG"
        else
            echo "[element-updater] ⚠️ Download failed for URL: $TAR_URL"
            rm -f /tmp/element_update.tar.gz
        fi
    else
        echo "[element-updater] Element Web is already up-to-date ($LATEST_TAG)."
    fi
}

# Perform an initial check on container boot
check_and_update || true

# Infinite loop checking the time every 30 seconds
while true; do
    CURRENT_TIME=$(TZ="Asia/Kolkata" date '+%H:%M')
    if [ "$CURRENT_TIME" = "02:00" ]; then
        check_and_update || true
        sleep 70  # Prevent multiple runs within the same 02:00 minute
    fi
    sleep 30
done