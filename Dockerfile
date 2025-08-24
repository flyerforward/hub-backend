FROM alpine:3.20

ARG PB_VERSION=0.22.9
WORKDIR /app

RUN apk add --no-cache curl unzip ca-certificates rsync

# Download PocketBase binary
RUN curl -L -o pb.zip \
  "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_amd64.zip" \
  && unzip pb.zip -d /app && rm pb.zip \
  && chmod +x /app/pocketbase

# Copy hooks and migrations from repo
COPY pb_hooks/      /app/pb_hooks/
COPY pb_migrations/ /app/pb_migrations/
COPY entrypoint.sh  /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 8090
CMD ["/app/entrypoint.sh"]