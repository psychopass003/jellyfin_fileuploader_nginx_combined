FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Kolkata

# ── System packages ───────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl wget gnupg2 ca-certificates apt-transport-https \
        software-properties-common ffmpeg unzip nginx python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

# ── Python dependencies ───────────────────────────────────────────────────────
RUN pip3 install --no-cache-dir --break-system-packages \
        fastapi uvicorn requests pyotp python-multipart

# ── Jellyfin ──────────────────────────────────────────────────────────────────
RUN curl -fsSL https://repo.jellyfin.org/install-debuntu.sh | bash

# ── Directory structure ────────────────────────────────────────────────────────
RUN mkdir -p /config /cache /media /scripts \
             /usr/share/nginx/element /etc/jellyfin \
    && chmod -R 777 /config /cache /media /scripts \
                    /usr/share/nginx/element /etc/jellyfin

# ── Element Web (bootstrapped; auto-updated at runtime by entrypoint.sh) ──────
RUN wget -q https://github.com/element-hq/element-web/releases/download/v1.12.21/element-v1.12.21.tar.gz \
         -O /tmp/element.tar.gz \
    && tar -xf /tmp/element.tar.gz -C /usr/share/nginx/element --strip-components=1 \
    && printf '%s' '{"default_server_config":{"m.homeserver":{"base_url":"https://matrix.org",\
"server_name":"matrix.org"},"m.identity_server":{"base_url":"https://vector.im"}},"brand":"Element"}' \
       > /usr/share/nginx/element/config.json \
    && rm /tmp/element.tar.gz \
    && chmod -R 755 /usr/share/nginx/element

# ── App files ─────────────────────────────────────────────────────────────────
COPY entrypoint.sh /scripts/entrypoint.sh
COPY app.py        /scripts/app.py
COPY nginx.conf    /etc/nginx/nginx.conf
RUN chmod +x /scripts/*.sh

# ── Expose HF Spaces port ─────────────────────────────────────────────────────
EXPOSE 7860

# ── Docker health check (Nginx answers /health instantly) ─────────────────────
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD curl -f http://localhost:7860/health || exit 1

# ── Use ENTRYPOINT so the startup script cannot be accidentally overridden ─────
ENTRYPOINT ["/scripts/entrypoint.sh"]
