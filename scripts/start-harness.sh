#!/usr/bin/env bash
# ==============================================================================
# Start or restart the local Harness Open Source container for the labs.
# Ensures the 'devops' network exists, creates or starts the 'harness'
# container, and waits until the web UI and API are ready on port 3000.
#
# Usage:
#   ~/intermediate-devops-companion/scripts/start-harness.sh
# ==============================================================================
set -euo pipefail

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

echo "=== Ensuring 'devops' Docker network exists ==="
if ! docker_cmd network inspect devops >/dev/null 2>&1; then
  docker_cmd network create devops
  echo "Created 'devops' network."
else
  echo "'devops' network already exists."
fi

echo "=== Checking Harness container status ==="
if ! docker_cmd ps -a --format '{{.Names}}' | grep -qx 'harness'; then
  echo "Creating and starting new 'harness' container..."
  docker_cmd run -d --name harness --restart always \
    --network devops \
    -p 3000:3000 -p 3022:3022 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v harness-data:/data \
    -e GITNESS_URL_CONTAINER=http://harness:3000 \
    -e GITNESS_CI_CONTAINER_NETWORKS=devops \
    -e GITNESS_PRINCIPAL_ADMIN_EMAIL=admin@example.com \
    -e GITNESS_PRINCIPAL_ADMIN_PASSWORD=Harness-Lab-2026 \
    -e GITNESS_METRIC_ENABLED=false \
    -e GITNESS_DOCKER_API_VERSION=1.44 \
    harness/harness:3.3.0
elif ! docker_cmd ps --format '{{.Names}}' | grep -qx 'harness'; then
  echo "Starting stopped 'harness' container..."
  docker_cmd start harness
else
  echo "'harness' container is already running."
fi

echo "=== Waiting for Harness to become ready ==="
attempts=0
max_attempts=30
until curl -fsS "http://localhost:3000/api/v1/system/config" >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ "$attempts" -ge "$max_attempts" ]; then
    echo "Error: Timed out waiting for Harness at http://localhost:3000" >&2
    echo "Check container logs with: docker logs harness" >&2
    exit 1
  fi
  sleep 2
done

echo "=== Harness is ready! ==="
docker_cmd ps --filter name=harness --format 'Container: {{.Names}} | Status: {{.Status}} | Image: {{.Image}}'
echo ""
echo "Access details:"
echo "  URL:      http://localhost:3000"
echo "  Username: admin@example.com"
echo "  Password: Harness-Lab-2026"
