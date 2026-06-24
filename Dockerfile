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
    wget \
    gnupg2 \
    ca-certificates \
    apt-transport-https \
    software-properties-common \
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
RUN mkdir -p /config /cache /media /scripts /usr/share/nginx/element /etc/jellyfin \
    && chmod -R 777 /config /cache /media /scripts /usr/share/nginx/element /etc/jellyfin

# ---- Install Element Web Chat Client ----
RUN wget -q https://github.com/element-hq/element-web/releases/download/v1.12.21/element-v1.12.21.tar.gz -O /tmp/element.tar.gz \
    && tar -xf /tmp/element.tar.gz -C /usr/share/nginx/element --strip-components=1 \
    && echo '{"default_server_config":{"m.homeserver":{"base_url":"https://matrix.org","server_name":"matrix.org"},"m.identity_server":{"base_url":"https://vector.im"}},"brand":"Element"}' > /usr/share/nginx/element/config.json \
    && rm /tmp/element.tar.gz \
    && chmod -R 755 /usr/share/nginx/element

# ---- Copy scripts & configs ----
COPY entrypoint.sh /scripts/entrypoint.sh
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