#!/usr/bin/env bash
set -euo pipefail

# Choose your PB version once here
PB_VERSION="${PB_VERSION:-0.22.9}"
OS="linux"
ARCH="amd64"

mkdir -p .dev-tools
cd .dev-tools

if [[ -x "pocketbase" ]]; then
  echo "PocketBase already present at .dev-tools/pocketbase"
  exit 0
fi

echo "Downloading PocketBase v$PB_VERSION..."
curl -L -o pb.zip \
  "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_${OS}_${ARCH}.zip"

unzip -o pb.zip
rm -f pb.zip
chmod +x pocketbase

echo "PocketBase ready at .dev-tools/pocketbase"