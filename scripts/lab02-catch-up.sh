#!/usr/bin/env bash
# ==============================================================================
# Lab 02 Catch-Up Script: Your first CI pipeline
# Explicitly runs all commands from Lab 02 to bring a machine to the end of Lab 02.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H_URL="${H_URL:-http://localhost:3000}"
H_ADMIN="${H_ADMIN:-admin}"
H_PASSWORD="${H_PASSWORD:-Harness-Lab-2026}"
H_STATE="${H_STATE:-$HOME/.lab-runner}"
mkdir -p "$H_STATE"

# Ensure Lab 01 is complete first
if [ ! -d "$HOME/flight-status/.git" ] || ! curl -fs "$H_URL/api/v1/spaces/flightops" >/dev/null 2>&1; then
  echo "Lab 01 state not detected; running lab01-catch-up.sh first..."
  "$SCRIPT_DIR/lab01-catch-up.sh"
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

h_create() {
  local code
  code=$(curl -sS -o "$H_STATE/last-response.json" -w '%{http_code}' -X "$1" "$H_URL$2" \
    -H "Authorization: Bearer $(h_token)" -H 'Content-Type: application/json' -d "$3")
  case "$code" in
    2*|409) return 0 ;;
    *) echo "HTTP $code from $1 $2: $(cat "$H_STATE/last-response.json")" >&2; return 1 ;;
  esac
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

echo "=== [Lab 02] Part 1: Running unit tests and ruff linter in container ==="
cd ~/flight-status
git switch main
docker_cmd run --rm -v "$PWD":/src -w /src -e PYTHONDONTWRITEBYTECODE=1 python:3.12-slim \
  sh -c "pip install --quiet --root-user-action=ignore -r requirements-dev.txt && pytest"
docker_cmd run --rm -v "$PWD":/src -w /src python:3.12-slim \
  sh -c "pip install --quiet --root-user-action=ignore ruff==0.17.2 && ruff check . && ruff format --check ."

echo "=== [Lab 02] Part 2 & 6: Writing ~/flight-status/.harness/ci.yaml ==="
mkdir -p ~/flight-status/.harness
cat > ~/flight-status/.harness/ci.yaml <<'EOF'
# Continuous integration for flight-status (Lab 02).
# Each step runs in its own container. All steps share the cloned workspace,
# so the virtual environment created by "install" is reused by later steps.
kind: pipeline
spec:
  stages:
  - name: build
    type: ci
    spec:
      steps:
      - name: install
        type: run
        spec:
          container: python:3.12-slim
          script: |
            python -m venv .venv
            . .venv/bin/activate
            pip install --quiet -r requirements-dev.txt
      - name: lint
        type: run
        spec:
          container: python:3.12-slim
          script: |
            . .venv/bin/activate
            ruff check .
            ruff format --check .
      - name: test
        type: run
        spec:
          container: python:3.12-slim
          script: |
            . .venv/bin/activate
            pytest
      - name: report
        type: run
        when: always()
        spec:
          container: alpine:3.20
          script: |
            echo "Build number: ${{ build.number }}"
            echo "Commit:       ${{ build.commit }}"
            echo "Event:        ${{ build.event }}"
            echo "Branch:       ${{ build.target }}"
EOF

echo "=== [Lab 02] Part 5.2: Describing CI pipeline in README.md ==="
if ! grep -q "## Continuous integration" ~/flight-status/README.md; then
  cat >> ~/flight-status/README.md <<'EOF'

## Continuous integration

The `ci` pipeline in `.harness/ci.yaml` lints and tests every push.
EOF
fi

echo "=== [Lab 02] Part 3 & 5: Creating 'ci' pipeline and 'push' trigger in Harness ==="
h_create POST "/api/v1/repos/flightops%2Fflight-status/pipelines" \
  '{"identifier":"ci","config_path":".harness/ci.yaml","default_branch":"main"}'

h_create POST "/api/v1/repos/flightops%2Fflight-status/pipelines/ci/triggers" \
  '{"identifier":"push","actions":["branch_updated"],"disabled":false}'

echo "=== [Lab 02] Committing, pushing, and waiting for pipeline run ==="
cd ~/flight-status
git add .harness/ci.yaml README.md
if ! git diff --cached --quiet; then
  git commit -m "Add CI pipeline and describe it in README"
  git push
else
  # Trigger manual execution if nothing new needed to be pushed
  h_api POST "/api/v1/repos/flightops%2Fflight-status/pipelines/ci/executions?branch=main" >/dev/null
fi

h_wait "flightops%2Fflight-status" "ci" "success" "$(git rev-parse HEAD)"
echo "=== [Lab 02] Completed successfully! ==="
