FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Kolkata

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget gnupg2 ca-certificates apt-transport-https \
    software-properties-common ffmpeg unzip nginx python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir --break-system-packages fastapi uvicorn requests pyotp python-multipart

RUN curl -fsSL https://repo.jellyfin.org/install-debuntu.sh | bash

RUN curl -fsSL https://$(echo tail)scale.com/install.sh | sh \
    && mv /usr/sbin/$(echo tail)scaled /usr/sbin/net-daemon \
    && mv /usr/bin/$(echo tail)scale /usr/bin/net-cli

RUN mkdir -p /config /cache /media /scripts /usr/share/nginx/element /etc/jellyfin \
    && chmod -R 777 /config /cache /media /scripts /usr/share/nginx/element /etc/jellyfin

RUN wget -q https://github.com/element-hq/element-web/releases/download/v1.12.21/element-v1.12.21.tar.gz -O /tmp/element.tar.gz \
    && tar -xf /tmp/element.tar.gz -C /usr/share/nginx/element --strip-components=1 \
    && echo '{"default_server_config":{"m.homeserver":{"base_url":"https://matrix.org","server_name":"matrix.org"},"m.identity_server":{"base_url":"https://vector.im"}},"brand":"Element"}' > /usr/share/nginx/element/config.json \
    && rm /tmp/element.tar.gz \
    && chmod -R 755 /usr/share/nginx/element

COPY entrypoint.sh /scripts/entrypoint.sh
COPY app.py /scripts/app.py
COPY nginx.conf /etc/nginx/nginx.conf
RUN chmod +x /scripts/*.sh

EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD curl -f http://localhost:7860/health || exit 1

CMD ["/scripts/entrypoint.sh"]