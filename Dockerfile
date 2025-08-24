# Dockerfile
FROM alpine:3.20

ARG PB_VERSION=0.22.9
WORKDIR /app

# Tools
RUN apk add --no-cache curl unzip ca-certificates

# Download PocketBase prebuilt binary
RUN curl -L -o pb.zip \
  "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_amd64.zip" \
  && unzip pb.zip -d /app && rm pb.zip \
  && chmod +x /app/pocketbase

# App files
COPY pb_hooks/            /app/pb_hooks/
COPY pb_migrations_seed/  /app/pb_migrations_seed/
COPY entrypoint.sh        /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 8090
CMD ["/app/entrypoint.sh"]