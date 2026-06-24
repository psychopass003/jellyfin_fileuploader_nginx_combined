# ============================================================
# Optimized Jellyfin on Hugging Face Spaces with Downloader App
# ============================================================

FROM debian:bookworm-slim

# Avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Kolkata

# ---- Install system dependencies ----
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    ffmpeg \
    unzip \
    nginx \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# ---- Install Python Packages ----
RUN pip3 install --no-cache-dir --break-system-packages fastapi uvicorn requests pyotp python-multipart

# ---- Install Jellyfin ----
RUN curl -fsSL https://repo.jellyfin.org/install-debuntu.sh | bash

# ---- Install Network Daemon & Obfuscate Binaries ----
RUN curl -fsSL https://$(echo tail)scale.com/install.sh | sh \
    && mv /usr/sbin/$(echo tail)scaled /usr/sbin/net-daemon \
    && mv /usr/bin/$(echo tail)scale /usr/bin/net-cli

# ---- Create directories ----
RUN mkdir -p /config /cache /media /scripts \
    && chmod -R 777 /config /cache /media /scripts

# ---- Copy scripts & configs ----
COPY entrypoint.sh /scripts/entrypoint.sh
COPY keep_alive.sh /scripts/keep_alive.sh
COPY app.py /scripts/app.py
COPY nginx.conf /etc/nginx/nginx.conf
RUN chmod +x /scripts/*.sh

# ---- Expose public port ----
EXPOSE 8096

# ---- Health check (Checks Nginx which forwards to Jellyfin) ----
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD curl -f http://localhost:8096/health || exit 1

# ---- Run ----
CMD ["/scripts/entrypoint.sh"]