FROM alpine:3.20

COPY config.env /config.env

# Set PB_VERSION from config.env
SHELL ["/bin/sh", "-c"]
RUN set -a && . ./config.env && set +a && \
    : "${PB_VERSION:=${PB_VERSION}}" && echo "PB_VERSION=$PB_VERSION"

WORKDIR /app

# Tools needed by entrypoint/bootstrap
RUN apk add --no-cache curl unzip ca-certificates rsync aws-cli jq

# Download PocketBase binary
RUN set -eux; \
    set -a; . /config.env; set +a; \
    : "${PB_VERSION:?PB_VERSION must be set in config.env}"; \
    echo "Downloading PocketBase v${PB_VERSION}"; \
    curl -fL -o /tmp/pb.zip \
      "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_amd64.zip"; \
    unzip -o /tmp/pb.zip -d /app; \
    rm -f /tmp/pb.zip; \
    chmod +x /app/pocketbase

# App files
COPY pb_hooks/      /app/pb_hooks/
COPY pb_migrations/ /app/pb_migrations/
COPY entrypoint.sh  /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Create volume mount points (populated at runtime by entrypoint)
RUN mkdir -p /pb_data /pb_migrations

EXPOSE 8090
CMD ["/app/entrypoint.sh"]
