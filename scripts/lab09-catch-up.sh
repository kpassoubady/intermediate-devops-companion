#!/usr/bin/env bash
# ==============================================================================
# Lab 09 Catch-Up Script: End-to-end delivery pipeline
# Explicitly runs all commands from Lab 09 to bring a machine to the end of Lab 09.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H_URL="${H_URL:-http://localhost:3000}"
H_ADMIN="${H_ADMIN:-admin}"
H_PASSWORD="${H_PASSWORD:-Harness-Lab-2026}"
H_STATE="${H_STATE:-$HOME/.lab-runner}"
mkdir -p "$H_STATE"

# Ensure Lab 08 is complete first
if [ ! -f "$HOME/flight-status/k8s/dev/kustomization.yaml" ] || ! kubectl -n flightops-dev get deployment flight-status >/dev/null 2>&1; then
  echo "Lab 08 state not detected; running lab08-catch-up.sh first..."
  "$SCRIPT_DIR/lab08-catch-up.sh"
fi

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

echo "=== [Lab 09] Part 1 & 2: Writing end-to-end .harness/ci.yaml, k8s/prod/kustomization.yaml, and .harness/promote.yaml ==="
cd ~/flight-status
git switch main
git pull
git checkout -B feature/delivery

cat > ~/flight-status/.harness/ci.yaml <<'EOF'
# Continuous integration and delivery for flight-status (Lab 09).
# Every run: lint, test, build the image and scan it.
# Pushes to main (merged pull requests) also deploy to dev and run a smoke test.
# If the deployment or the smoke test fails, the rollback step restores the
# previous version in dev.
kind: pipeline
spec:
  stages:
  - name: build
    type: ci
    spec:
      steps:
      - name: db
        type: background
        spec:
          container: postgres:17-alpine
          envs:
            POSTGRES_USER: flights
            POSTGRES_PASSWORD: flights
            POSTGRES_DB: flights
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
          envs:
            DATABASE_URL: postgresql://flights:flights@db:5432/flights
          script: |
            . .venv/bin/activate
            pytest --cov=flightstatus --cov-report=term-missing --cov-fail-under=90
      - name: image
        type: plugin
        spec:
          name: docker
          inputs:
            registry: k3d-registry.localhost:5000
            repo: k3d-registry.localhost:5000/flight-status
            insecure: true
            # Plugin inputs are strings. Separate several values with commas.
            tags: ${{ build.commit }}
            build_args: APP_VERSION=1.0.${{ build.number }},GIT_COMMIT=${{ build.commit }}
            custom_dns: 172.31.0.2
      - name: scan
        type: run
        spec:
          container: aquasec/trivy:0.75.0
          script: |
            trivy image --insecure --no-progress --skip-version-check --severity CRITICAL --ignore-unfixed --exit-code 1 \
              k3d-registry.localhost:5000/flight-status:${{ build.commit }}
      - name: deploy
        type: run
        when: build.event == "push" and build.target == "main"
        spec:
          container: alpine/k8s:1.35.9
          envs:
            KUBECONFIG_CONTENT: ${{ secrets.get("dev_kubeconfig") }}
          script: |
            printf '%s\n' "$KUBECONFIG_CONTENT" > /tmp/kubeconfig
            export KUBECONFIG=/tmp/kubeconfig
            touch .deploy-started
            cd k8s/dev
            kustomize edit set image flight-status=k3d-registry.localhost:5000/flight-status:${{ build.commit }}
            kubectl apply -k .
            kubectl rollout status deployment/flight-status --timeout=120s
      - name: smoke
        type: run
        when: build.event == "push" and build.target == "main"
        spec:
          container: alpine/k8s:1.35.9
          script: |
            for attempt in $(seq 1 15); do
              if curl -fsS -H "Host: flights-dev.localhost" http://k3d-devops-serverlb/version > version.json \
                && jq -e '.version == "1.0.${{ build.number }}"' version.json; then
                exit 0
              fi
              sleep 2
            done
            cat version.json
            exit 1
      - name: rollback
        type: run
        when: failure()
        spec:
          container: alpine/k8s:1.35.9
          envs:
            KUBECONFIG_CONTENT: ${{ secrets.get("dev_kubeconfig") }}
          script: |
            if [ ! -f .deploy-started ]; then
              echo "This run did not deploy anything. Nothing to roll back."
              exit 0
            fi
            printf '%s\n' "$KUBECONFIG_CONTENT" > /tmp/kubeconfig
            export KUBECONFIG=/tmp/kubeconfig
            kubectl rollout undo deployment/flight-status
            kubectl rollout status deployment/flight-status --timeout=120s
EOF

mkdir -p ~/flight-status/k8s/prod
cat > ~/flight-status/k8s/prod/kustomization.yaml <<'EOF'
# The prod environment: namespace flightops-prod, http://flights.localhost:8080
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: flightops-prod
resources:
  - ../base
replicas:
  - name: flight-status
    count: 3
configMapGenerator:
  - name: flight-status-config
    literals:
      - APP_ENV=production
images:
  - name: flight-status
    newName: k3d-registry.localhost:5000/flight-status
    newTag: "1.0.0"
patches:
  - target:
      kind: Ingress
      name: flight-status
    patch: |-
      - op: replace
        path: /spec/rules/0/host
        value: flights.localhost
EOF

cat > ~/flight-status/.harness/promote.yaml <<'EOF'
# Promote a release to production (Lab 09).
# Runs when a tag is created. It deploys the image that the ci pipeline
# built and scanned for the tagged commit. Nothing is rebuilt.
kind: pipeline
spec:
  stages:
  - name: promote
    type: ci
    spec:
      steps:
      - name: check
        type: run
        when: build.event == "tag"
        spec:
          container: alpine/k8s:1.35.9
          script: |
            echo "Promoting commit ${{ build.commit }} (${{ build.ref }})"
            # wget, because curl sends every *.localhost name to 127.0.0.1.
            wget -q -O /dev/null \
              --header "Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
              http://k3d-registry.localhost:5000/v2/flight-status/manifests/${{ build.commit }}
            echo "Image found: k3d-registry.localhost:5000/flight-status:${{ build.commit }}"
      - name: deploy
        type: run
        when: build.event == "tag"
        spec:
          container: alpine/k8s:1.35.9
          envs:
            KUBECONFIG_CONTENT: ${{ secrets.get("prod_kubeconfig") }}
          script: |
            printf '%s\n' "$KUBECONFIG_CONTENT" > /tmp/kubeconfig
            export KUBECONFIG=/tmp/kubeconfig
            touch .deploy-started
            cd k8s/prod
            kustomize edit set image flight-status=k3d-registry.localhost:5000/flight-status:${{ build.commit }}
            kubectl apply -k .
            kubectl rollout status deployment/flight-status --timeout=120s
      - name: smoke
        type: run
        when: build.event == "tag"
        spec:
          container: alpine/k8s:1.35.9
          script: |
            for attempt in $(seq 1 15); do
              if curl -fsS -H "Host: flights.localhost" http://k3d-devops-serverlb/version > version.json \
                && jq -e '.commit == "${{ build.commit }}"' version.json; then
                exit 0
              fi
              sleep 2
            done
            cat version.json
            exit 1
      - name: rollback
        type: run
        when: failure()
        spec:
          container: alpine/k8s:1.35.9
          envs:
            KUBECONFIG_CONTENT: ${{ secrets.get("prod_kubeconfig") }}
          script: |
            if [ ! -f .deploy-started ]; then
              echo "This run did not deploy anything. Nothing to roll back."
              exit 0
            fi
            printf '%s\n' "$KUBECONFIG_CONTENT" > /tmp/kubeconfig
            export KUBECONFIG=/tmp/kubeconfig
            kubectl rollout undo deployment/flight-status
            kubectl rollout status deployment/flight-status --timeout=120s
EOF

echo "=== [Lab 09] Part 3: Committing, opening PR, merging, and deploying to dev ==="
git add .harness k8s/prod
if ! git diff --cached --quiet; then
  git commit -m "Deliver to dev on merge and promote to prod with a tag"
  git push -u origin feature/delivery
  h_open_and_merge_pr "flightops%2Fflight-status" "feature/delivery" "main" "Add delivery and promotion" "ci"
  MAIN_SHA=$(h_api GET "/api/v1/repos/flightops%2Fflight-status/branches/main" | jq -r '.sha // .commit.sha')
  h_wait "flightops%2Fflight-status" "ci" "success" "$MAIN_SHA"
fi

git switch main
git pull
git branch -D feature/delivery 2>/dev/null || true

echo "=== [Lab 09] Part 4 & 5: Creating 'promote' pipeline and releasing v1.0.0 to prod ==="
h_create POST "/api/v1/repos/flightops%2Fflight-status/pipelines" \
  '{"identifier":"promote","config_path":".harness/promote.yaml","default_branch":"main"}'

h_api PATCH "/api/v1/repos/flightops%2Fflight-status/pipelines/promote/triggers/default" \
  '{"disabled":true}' >/dev/null || true

h_create POST "/api/v1/repos/flightops%2Fflight-status/pipelines/promote/triggers" \
  '{"identifier":"release","actions":["tag_created"],"disabled":false}'

if ! git rev-parse v1.0.0 >/dev/null 2>&1; then
  git tag v1.0.0
  git push origin v1.0.0
  h_wait "flightops%2Fflight-status" "promote" "success" "$(git rev-list -n 1 v1.0.0)"
fi

echo "=== [Lab 09] Verifying Lab 09 state ==="
test "$(kubectl -n flightops-dev get deployment flight-status -o jsonpath='{.status.readyReplicas}')" = "2"
test "$(kubectl -n flightops-prod get deployment flight-status -o jsonpath='{.status.readyReplicas}')" = "3"
echo "=== [Lab 09] Completed successfully! ==="
