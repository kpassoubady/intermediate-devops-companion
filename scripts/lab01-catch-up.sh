#!/usr/bin/env bash
# ==============================================================================
# Lab 01 Catch-Up Script: Lab environment and Harness Open Source
# Explicitly runs all commands from Lab 01 to bring a machine to the end of Lab 01.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

H_URL="${H_URL:-http://localhost:3000}"
H_ADMIN="${H_ADMIN:-admin}"
H_PASSWORD="${H_PASSWORD:-Harness-Lab-2026}"
H_STATE="${H_STATE:-$HOME/.lab-runner}"
mkdir -p "$H_STATE"

echo "=== [Lab 01] Part 1: Checking lab machine resources ==="
cat /etc/os-release
nproc
free -h
df -h /

echo "=== [Lab 01] Part 2.1: Installing git, curl, jq, ca-certificates, gnupg ==="
if [ -d /etc/needrestart/conf.d ]; then
  echo "\$nrconf{restart} = 'a';" | sudo tee /etc/needrestart/conf.d/90-course.conf > /dev/null
fi
sudo apt-get update
sudo apt-get install -y git curl jq ca-certificates gnupg wget
git --version
curl --version | head -1
jq --version

echo "=== [Lab 01] Part 2.2: Configuring Git identity and default branch ==="
if ! git config --global user.name >/dev/null 2>&1; then
  git config --global user.name "Lab Student"
fi
if ! git config --global user.email >/dev/null 2>&1; then
  git config --global user.email "student@example.com"
fi
git config --global init.defaultBranch main
git config --global --list

echo "=== [Lab 01] Part 2.3 & 2.4: Installing and configuring VS Code ==="
if ! command -v code >/dev/null 2>&1; then
  echo "code code/add-microsoft-repo boolean false" | sudo debconf-set-selections
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /tmp/microsoft.gpg
  sudo install -D -o root -g root -m 644 /tmp/microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
  echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y code
fi
mkdir -p ~/.config/Code/User
if [ ! -s ~/.config/Code/User/settings.json ]; then
  echo '{ "files.insertFinalNewline": true }' > ~/.config/Code/User/settings.json
else
  jq '. + {"files.insertFinalNewline": true}' ~/.config/Code/User/settings.json > /tmp/settings.json \
    && mv /tmp/settings.json ~/.config/Code/User/settings.json
fi
cat ~/.config/Code/User/settings.json

echo "=== [Lab 01] Part 3.1: Installing Docker Engine 29.x ==="
if ! sudo docker version --format '{{.Server.Version}}' 2>/dev/null | grep -q '^29\.'; then
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y 'docker-ce=5:29.*' 'docker-ce-cli=5:29.*' containerd.io docker-buildx-plugin docker-compose-plugin
fi
sudo docker version --format 'Docker Engine {{.Server.Version}}'

echo "=== [Lab 01] Part 3.2: Configuring local insecure image registry ==="
echo '{ "insecure-registries": ["k3d-registry.localhost:5000"] }' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker
sudo docker info 2>/dev/null | grep -A3 'Insecure Registries'

echo "=== [Lab 01] Part 3.3 & 3.4: Adding $USER to docker group ==="
sudo usermod -aG docker "$USER"

# Use sudo docker in this session if the current shell does not have the docker group active yet
docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

docker_cmd run --rm hello-world >/dev/null
docker_cmd version --format 'Client {{.Client.Version}}, server {{.Server.Version}}'

echo "=== [Lab 01] Part 4.1: Creating 'devops' Docker network ==="
if ! docker_cmd network inspect devops >/dev/null 2>&1; then
  docker_cmd network create devops
fi
docker_cmd network ls --filter name=devops

echo "=== [Lab 01] Part 4.3 & 4.4: Starting Harness Open Source container ==="
if ! docker_cmd ps -a --format '{{.Names}}' | grep -qx 'harness'; then
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
    harness/harness:3.3.0
elif ! docker_cmd ps --format '{{.Names}}' | grep -qx 'harness'; then
  docker_cmd start harness
fi

until curl -fs "$H_URL/api/v1/system/config" >/dev/null; do
  echo "Waiting for Harness..."
  sleep 3
done
echo "Harness is ready"
docker_cmd ps --filter name=harness --format '{{.Names}}  {{.Image}}  {{.Status}}'

echo "=== [Lab 01] Part 4.5 & 5: Signing in and creating project 'flightops' and repo 'flight-status' ==="
SESSION_TOKEN=$(curl -fsS -X POST "$H_URL/api/v1/login" \
  -H 'Content-Type: application/json' \
  -d "{\"login_identifier\":\"$H_ADMIN\",\"password\":\"$H_PASSWORD\"}" | jq -r .access_token)

if [ ! -s "$H_STATE/api-token" ]; then
  curl -fsS -X POST "$H_URL/api/v1/user/tokens" \
    -H "Authorization: Bearer $SESSION_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "{\"identifier\":\"lab-runner-$(date +%s)\",\"lifetime\":2592000000000000}" \
    | jq -r .access_token > "$H_STATE/api-token"
  chmod 600 "$H_STATE/api-token"
fi
API_TOKEN=$(cat "$H_STATE/api-token")

# Create project 'flightops' (HTTP 409 means it already exists)
HTTP_CODE=$(curl -sS -o "$H_STATE/last-response.json" -w '%{http_code}' \
  -X POST "$H_URL/api/v1/spaces" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"flightops"}')
case "$HTTP_CODE" in 2*|409) ;; *) cat "$H_STATE/last-response.json" >&2; exit 1 ;; esac

# Create repository 'flight-status' inside 'flightops'
HTTP_CODE=$(curl -sS -o "$H_STATE/last-response.json" -w '%{http_code}' \
  -X POST "$H_URL/api/v1/repos" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"parent_ref":"flightops","identifier":"flight-status","default_branch":"main"}')
case "$HTTP_CODE" in 2*|409) ;; *) cat "$H_STATE/last-response.json" >&2; exit 1 ;; esac

echo "=== [Lab 01] Part 6: Creating Git PAT, copying starter app, and pushing to Harness ==="
# Ensure ~/intermediate-devops-companion points to REPO_DIR so any lab commands using ~/intermediate-devops-companion work
if [ ! -e "$HOME/intermediate-devops-companion" ]; then
  ln -s "$REPO_DIR" "$HOME/intermediate-devops-companion"
fi

# Create personal access token for Git over HTTP and store in ~/.git-credentials
GIT_TOKEN=$(curl -fsS -X POST "$H_URL/api/v1/user/tokens" \
  -H "Authorization: Bearer $SESSION_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"identifier\":\"git-$(date +%s)\",\"lifetime\":2592000000000000}" | jq -r .access_token)

touch ~/.git-credentials && chmod 600 ~/.git-credentials
grep -Ev '@localhost(:|%3a|%3A)3000' ~/.git-credentials > "$H_STATE/creds" || true
printf 'http://%s:%s@localhost:3000\n' "$H_ADMIN" "$GIT_TOKEN" >> "$H_STATE/creds"
cat "$H_STATE/creds" > ~/.git-credentials && rm -f "$H_STATE/creds"

git config --global credential.helper store

mkdir -p ~/flight-status
cp -r "$REPO_DIR/app/." ~/flight-status/
cd ~/flight-status
if [ ! -d .git ]; then
  git init -b main
fi
git checkout -B main
git add .
if ! git diff --cached --quiet; then
  git commit -m "Add the flight status service"
fi
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin http://localhost:3000/git/flightops/flight-status.git
else
  git remote add origin http://localhost:3000/git/flightops/flight-status.git
fi
git push -u origin main

echo "=== [Lab 01] Verifying Lab 01 state ==="
test "$(git ls-remote origin refs/heads/main | cut -f1)" = "$(git rev-parse HEAD)"
echo "=== [Lab 01] Completed successfully! (Run 'newgrp docker' in your terminal if needed) ==="
