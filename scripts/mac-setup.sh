#!/usr/bin/env bash
# ==============================================================================
# macOS fallback setup: installs the CLI tools that Labs 01, 04 and 07 install
# with apt or linux-amd64 downloads. See labs/macos-notes.md.
# Needs Homebrew and a running Docker Desktop. Does not use sudo.
# ==============================================================================
set -euo pipefail

[ "$(uname -s)" = "Darwin" ] || { echo "This script is for macOS only."; exit 1; }
command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker Desktop is not running. Start it and run this again."; exit 1; }

echo "=== Installing tools ==="
for pkg in git jq kubectl k3d trivy; do
  brew list --formula "$pkg" >/dev/null 2>&1 || brew install "$pkg"
done
brew list --formula terraform >/dev/null 2>&1 || brew install hashicorp/tap/terraform

echo "=== Versions (labs pin k3d v5.9.0, Terraform 1.17.0, Trivy 0.75.0) ==="
k3d version | head -1
terraform version | head -1
trivy --version | head -1
kubectl version --client | head -1

echo "=== Docker Desktop resources ==="
docker info --format 'CPUs: {{.NCPU}}  Memory: {{.MemTotal}} bytes'
echo "Recommended: 6+ CPUs and 8+ GB (Docker Desktop > Settings > Resources)."

echo "=== Ports used by the labs ==="
for port in 3000 5000 8000 8080; do
  owner=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2{print $1" (pid "$2")"}' || true)
  if [ -n "$owner" ]; then echo "port $port: IN USE by $owner"; else echo "port $port: free"; fi
done
if lsof -nP -iTCP:5000 -sTCP:LISTEN 2>/dev/null | grep -q ControlCe; then  # grep -q is safe in if
  echo "Port 5000 is held by AirPlay Receiver. Turn it off, see labs/macos-notes.md."
fi

echo "=== Registry hostname ==="
if ! grep -q 'k3d-registry.localhost' /etc/hosts; then
  echo "Add it with: echo '127.0.0.1 k3d-registry.localhost' | sudo tee -a /etc/hosts"
fi
