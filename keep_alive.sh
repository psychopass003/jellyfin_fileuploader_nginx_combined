#!/bin/bash
# ============================================================
# Keep-alive: pings Jellyfin locally (for logs) and optionally
# externally (if SPACE_HOST is set) to prevent inactivity sleep.
# ============================================================

echo "  🏓 Keep-alive service active."

while true; do
    sleep 300  # 5 minutes
    
    # 1. Local Health Check (helpful for Space logs)
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8097/health 2>/dev/null)
    if [ "$HTTP_CODE" = "200" ]; then
        echo "[keep-alive] $(date '+%H:%M:%S') - Jellyfin healthy (HTTP $HTTP_CODE)"
    else
        echo "[keep-alive] $(date '+%H:%M:%S') - ⚠️ Jellyfin returned HTTP $HTTP_CODE"
    fi

    # 2. External Space Ping (only runs if SPACE_HOST is set in environment)
    if [ -n "$SPACE_HOST" ]; then
        # Ensure it has http:// or https:// prefix
        if [[ ! "$SPACE_HOST" =~ ^https?:// ]]; then
            PING_URL="https://$SPACE_HOST"
        else
            PING_URL="$SPACE_HOST"
        fi
        
        # Ping the external URL
        EXT_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$PING_URL" 2>/dev/null)
        echo "[keep-alive] $(date '+%H:%M:%S') - Pinged external $PING_URL (HTTP $EXT_CODE)"
    fi
done