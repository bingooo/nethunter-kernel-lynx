#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

RAW_PROXY="${https_proxy:-${http_proxy:-http://127.0.0.1:2090}}"
# When running inside Docker on macOS, 127.0.0.1 must be host.docker.internal
DOCKER_PROXY=$(echo "${RAW_PROXY}" | sed -E 's/(127\.0\.0\.1|localhost)/host.docker.internal/g')

echo "==> Host Proxy   : ${RAW_PROXY}"
echo "==> Docker Proxy : ${DOCKER_PROXY}"
echo "==> [1/3] Building Docker image (nethunter-lynx-builder)..."

docker build \
  --build-arg HTTP_PROXY="${DOCKER_PROXY}" \
  --build-arg HTTPS_PROXY="${DOCKER_PROXY}" \
  --build-arg http_proxy="${DOCKER_PROXY}" \
  --build-arg https_proxy="${DOCKER_PROXY}" \
  -t nethunter-lynx-builder .

echo "==> [2/3] Preparing case-sensitive Linux volumes (for M1/macOS APFS compatibility)..."
docker volume create nethunter-lynx-kernel >/dev/null
docker volume create nethunter-lynx-out >/dev/null
docker volume create nethunter-lynx-drivers >/dev/null

mkdir -p "${ROOT_DIR}/output"

echo "==> [3/3] Running build inside container..."
docker run --rm \
  -e HTTP_PROXY="${DOCKER_PROXY}" \
  -e HTTPS_PROXY="${DOCKER_PROXY}" \
  -e http_proxy="${DOCKER_PROXY}" \
  -e https_proxy="${DOCKER_PROXY}" \
  -v "${ROOT_DIR}":/workspace \
  -v nethunter-lynx-kernel:/workspace/kernel \
  -v nethunter-lynx-out:/workspace/out \
  -v nethunter-lynx-drivers:/workspace/drivers \
  nethunter-lynx-builder
