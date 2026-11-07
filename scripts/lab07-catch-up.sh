#!/usr/bin/env bash
# ==============================================================================
# Lab 07 Catch-Up Script: Build, scan and describe a container
# Explicitly runs all commands from Lab 07 to bring a machine to the end of Lab 07.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H_URL="${H_URL:-http://localhost:3000}"
H_ADMIN="${H_ADMIN:-admin}"
H_PASSWORD="${H_PASSWORD:-Harness-Lab-2026}"
H_STATE="${H_STATE:-$HOME/.lab-runner}"
mkdir -p "$H_STATE"

# Ensure Lab 06 is complete first
if [ ! -f "$HOME/deployer-dev.kubeconfig" ] || [ ! -f "$HOME/deployer-prod.kubeconfig" ]; then
  echo "Lab 06 state not detected; running lab06-catch-up.sh first..."
  "$SCRIPT_DIR/lab06-catch-up.sh"
fi

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

h_token() {
  if [ ! -s "$H_STATE/api-token" ]; then
    local session
    session=$(curl -fsS -X POST "$H_URL/api/v1/login" -H 'Content-Type: application/json' \
      -d "{\"login_identifier\":\"$H_ADMIN\",\"password\":\"$H_PASSWORD\"}" | jq -r .access_token)
    curl -fsS -X POST "$H_URL/api/v1/user/tokens" -H "Authorization: Bearer $session" \
      -H 'Content-Type: application/json' \
      -d "{\"identifier\":\"lab-runner-$(date +%s)\",\"lifetime\":2592000000000000}" \
      | jq -r .access_token > "$H_STATE/api-token"
    chmod 600 "$H_STATE/api-token"
  fi
  cat "$H_STATE/api-token"
}

h_api() {
  local method=$1 path=$2 data=${3:-}
  if [ -n "$data" ]; then
    curl -fsS -X "$method" "$H_URL$path" -H "Authorization: Bearer $(h_token)" \
      -H 'Content-Type: application/json' -d "$data"
  else
    curl -fsS -X "$method" "$H_URL$path" -H "Authorization: Bearer $(h_token)"
  fi
}

h_wait() {
  local repo_enc=$1 pipe=$2 want=$3 sha=$4 ex num="" st="" deadline=$((SECONDS + 900))
  while :; do
    ex=$(h_api GET "/api/v1/repos/$repo_enc/pipelines/$pipe/executions?limit=25" \
      | jq -c --arg s "$sha" '[.[] | select(.after == $s)] | max_by(.number) // empty')
    if [ -n "$ex" ]; then
      num=$(jq -r .number <<<"$ex")
      st=$(jq -r .status <<<"$ex")
      case "$st" in success|failure|error|killed) break ;; esac
    fi
    if [ $SECONDS -gt $deadline ]; then
      echo "Timed out waiting for $pipe on ${sha:0:8} (last: #$num $st)" >&2
      return 1
    fi
    sleep 5
  done
  echo "Pipeline $pipe #$num finished with status: $st (commit ${sha:0:8})"
  [ "$st" = "$want" ]
}

h_open_and_merge_pr() {
  local repo_enc=$1 source_branch=$2 target_branch=$3 title=$4 check=$5
  local pr_num sha out deadline=$((SECONDS + 600))
  pr_num=$(h_api GET "/api/v1/repos/$repo_enc/pullreq?state=open&source_branch=$source_branch&target_branch=$target_branch" \
    | jq -r '.[0].number // empty')
  if [ -z "$pr_num" ]; then
    pr_num=$(h_api POST "/api/v1/repos/$repo_enc/pullreq" \
      "$(jq -n --arg s "$source_branch" --arg t "$target_branch" --arg title "$title" \
        '{source_branch:$s,target_branch:$t,title:$title}')" | jq -r .number)
  fi
  echo "Opened pull request #$pr_num ($source_branch -> $target_branch)"
  sha=$(h_api GET "/api/v1/repos/$repo_enc/pullreq/$pr_num" | jq -r .source_sha)
  h_wait "$repo_enc" "$check" "success" "$sha"

  while :; do
    sha=$(h_api GET "/api/v1/repos/$repo_enc/pullreq/$pr_num" | jq -r .source_sha)
    if out=$(h_api POST "/api/v1/repos/$repo_enc/pullreq/$pr_num/merge" \
        "{\"method\":\"squash\",\"source_sha\":\"$sha\",\"delete_source_branch\":true}" 2>&1); then
      echo "Merged pull request #$pr_num"
      break
    fi
    if [ $SECONDS -gt $deadline ]; then
      echo "Merge of PR #$pr_num failed: $out" >&2
      return 1
    fi
    sleep 5
  done
}

echo "=== [Lab 07] Part 1: Installing Trivy 0.75.0 ==="
if ! trivy --version 2>/dev/null | grep -q "0.75.0"; then
  mkdir -p ~/downloads && cd ~/downloads
  curl -fsSLO https://github.com/aquasecurity/trivy/releases/download/v0.75.0/trivy_0.75.0_Linux-64bit.deb
  curl -fsSLO https://github.com/aquasecurity/trivy/releases/download/v0.75.0/trivy_0.75.0_checksums.txt
  sha256sum --check --ignore-missing trivy_0.75.0_checksums.txt
  sudo apt-get -o DPkg::Lock::Timeout=300 install -y ./trivy_0.75.0_Linux-64bit.deb
fi
trivy --version

echo "=== [Lab 07] Part 2, 6 & 7: Writing Dockerfile, .dockerignore, compose.yaml, and ecs/taskdef.json ==="
cd ~/flight-status
git switch main
git pull
git checkout -B feature/container

cat > ~/flight-status/Dockerfile <<'EOF'
# Container image for the flight status API (Lab 07).
FROM python:3.12-slim

# Do not write .pyc files, and send log output straight to the terminal.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Install the dependencies first. Docker reuses this layer from its cache
# until requirements.txt changes, so code changes rebuild quickly.
COPY requirements.txt .
RUN pip install --no-cache-dir --root-user-action=ignore -r requirements.txt

# Copy the application code.
COPY flightstatus/ flightstatus/

# Version information, passed in at build time with --build-arg.
ARG APP_VERSION=dev
ARG GIT_COMMIT=unknown
ENV APP_VERSION=${APP_VERSION} \
    GIT_COMMIT=${GIT_COMMIT}

# Run as an unprivileged user, not as root.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
USER 10001

EXPOSE 8000
CMD ["uvicorn", "flightstatus.main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

cat > ~/flight-status/.dockerignore <<'EOF'
# Files the image does not need. Keeping them out makes builds faster
# and stops local files (and secrets) from ending up in the image.
.git
.harness
.venv
__pycache__/
*.pyc
tests/
k8s/
ecs/
compose.yaml
Dockerfile
.dockerignore
*.md
EOF

cat > ~/flight-status/compose.yaml <<'EOF'
# Run the API and a PostgreSQL database on your machine (Lab 07).
services:
  app:
    build: .
    image: k3d-registry.localhost:5000/flight-status:1.0.0
    ports:
      - "8000:8000"
    environment:
      APP_ENV: local
      DATABASE_URL: postgresql://flights:flights@db:5432/flights
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"]
      interval: 10s
      timeout: 3s
      retries: 3

  db:
    image: postgres:17-alpine
    environment:
      POSTGRES_USER: flights
      POSTGRES_PASSWORD: flights
      POSTGRES_DB: flights
    volumes:
      - db-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U flights"]
      interval: 2s
      timeout: 3s
      retries: 15

volumes:
  db-data:
EOF

mkdir -p ~/flight-status/ecs
cat > ~/flight-status/ecs/taskdef.json <<'EOF'
{
  "family": "flight-status",
  "requiresCompatibilities": ["FARGATE"],
  "networkMode": "awsvpc",
  "cpu": "512",
  "memory": "1024",
  "runtimePlatform": {
    "operatingSystemFamily": "LINUX",
    "cpuArchitecture": "X86_64"
  },
  "executionRoleArn": "arn:aws:iam::111122223333:role/ecsTaskExecutionRole",
  "taskRoleArn": "arn:aws:iam::111122223333:role/flight-status-task",
  "containerDefinitions": [
    {
      "name": "app",
      "image": "111122223333.dkr.ecr.us-east-1.amazonaws.com/flight-status:1.0.0",
      "essential": true,
      "portMappings": [
        { "containerPort": 8000, "protocol": "tcp" }
      ],
      "environment": [
        { "name": "APP_ENV", "value": "production" }
      ],
      "secrets": [
        {
          "name": "DATABASE_URL",
          "valueFrom": "arn:aws:secretsmanager:us-east-1:111122223333:secret:flight-status/database-url"
        }
      ],
      "healthCheck": {
        "command": ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"],
        "interval": 10,
        "timeout": 3,
        "retries": 3,
        "startPeriod": 10
      },
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/flight-status",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "app"
        }
      }
    }
  ]
}
EOF

echo "=== [Lab 07] Part 3, 4 & 5: Building image 1.0.0, pushing to local registry, and generating SBOM ==="
cd ~/flight-status
docker_cmd build -t flight-status:1.0.0 \
  --build-arg APP_VERSION=1.0.0 \
  --build-arg GIT_COMMIT="$(git rev-parse HEAD)" \
  .
docker_cmd tag flight-status:1.0.0 k3d-registry.localhost:5000/flight-status:1.0.0
docker_cmd push k3d-registry.localhost:5000/flight-status:1.0.0
curl -s http://k3d-registry.localhost:5000/v2/flight-status/tags/list
echo

trivy image --format cyclonedx --output ~/flight-status-1.0.0.cdx.json flight-status:1.0.0

echo "=== [Lab 07] Part 8: Committing, opening PR, and merging to main ==="
cd ~/flight-status
git add Dockerfile .dockerignore compose.yaml ecs/taskdef.json
if ! git diff --cached --quiet; then
  git commit -m "Add container image, Compose file and ECS task definition"
  git push -u origin feature/container
  h_open_and_merge_pr "flightops%2Fflight-status" "feature/container" "main" "Add container build files" "ci"
  MAIN_SHA=$(h_api GET "/api/v1/repos/flightops%2Fflight-status/branches/main" | jq -r '.sha // .commit.sha')
  h_wait "flightops%2Fflight-status" "ci" "success" "$MAIN_SHA"
fi

git switch main
git pull
git branch -D feature/container 2>/dev/null || true

echo "=== [Lab 07] Verifying Lab 07 state ==="
git show HEAD:Dockerfile | grep -q "USER 10001"
git show HEAD:ecs/taskdef.json | jq -e '.family == "flight-status"' >/dev/null
echo "=== [Lab 07] Completed successfully! ==="
