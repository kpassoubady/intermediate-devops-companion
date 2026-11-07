#!/usr/bin/env bash
# ==============================================================================
# Lab 08 Catch-Up Script: Kubernetes deployments, rollouts and rollbacks
# Explicitly runs all commands from Lab 08 to bring a machine to the end of Lab 08.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H_URL="${H_URL:-http://localhost:3000}"
H_ADMIN="${H_ADMIN:-admin}"
H_PASSWORD="${H_PASSWORD:-Harness-Lab-2026}"
H_STATE="${H_STATE:-$HOME/.lab-runner}"
mkdir -p "$H_STATE"

# Ensure Lab 07 is complete first
if [ ! -f "$HOME/flight-status/Dockerfile" ] || ! curl -s http://k3d-registry.localhost:5000/v2/flight-status/tags/list 2>/dev/null | jq -e '.tags | index("1.0.0")' >/dev/null 2>&1; then
  echo "Lab 07 state not detected; running lab07-catch-up.sh first..."
  "$SCRIPT_DIR/lab07-catch-up.sh"
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

echo "=== [Lab 08] Part 1: Writing Kubernetes manifests and Kustomize dev overlay ==="
cd ~/flight-status
git switch main
git pull
git checkout -B feature/kubernetes
mkdir -p k8s/base k8s/dev

cat > ~/flight-status/k8s/base/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flight-status
  labels:
    app: flight-status
spec:
  replicas: 2
  revisionHistoryLimit: 5
  # Mark the rollout as failed if it makes no progress for 90 seconds.
  progressDeadlineSeconds: 90
  selector:
    matchLabels:
      app: flight-status
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1        # at most one extra pod during an update
      maxUnavailable: 0  # never go below the desired number of ready pods
  template:
    metadata:
      labels:
        app: flight-status
    spec:
      containers:
        - name: app
          image: flight-status   # replaced by the overlay's "images" setting
          ports:
            - name: http
              containerPort: 8000
          envFrom:
            - configMapRef:
                name: flight-status-config
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: flight-status-db
                  key: DATABASE_URL
          readinessProbe:
            httpGet:
              path: /ready
              port: http
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 10
            failureThreshold: 3
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
EOF

cat > ~/flight-status/k8s/base/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: flight-status
spec:
  selector:
    app: flight-status
  ports:
    - name: http
      port: 80
      targetPort: http
EOF

cat > ~/flight-status/k8s/base/ingress.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: flight-status
spec:
  rules:
    - host: flights.localhost   # replaced by each overlay
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: flight-status
                port:
                  name: http
EOF

cat > ~/flight-status/k8s/base/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
EOF

cat > ~/flight-status/k8s/dev/kustomization.yaml <<'EOF'
# The dev environment: namespace flightops-dev, http://flights-dev.localhost:8080
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: flightops-dev
resources:
  - ../base
configMapGenerator:
  - name: flight-status-config
    literals:
      - APP_ENV=dev
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
        value: flights-dev.localhost
EOF

echo "=== [Lab 08] Part 2: Deploying version 1.0.0 to flightops-dev ==="
kubectl apply -k k8s/dev
kubectl -n flightops-dev rollout status deployment/flight-status --timeout=120s

echo "=== [Lab 08] Part 4: Building, pushing, and rolling out version 1.1.0 ==="
docker_cmd build -t k3d-registry.localhost:5000/flight-status:1.1.0 \
  --build-arg APP_VERSION=1.1.0 \
  --build-arg GIT_COMMIT="$(git rev-parse HEAD)" \
  .
docker_cmd push k3d-registry.localhost:5000/flight-status:1.1.0

sed -i 's/newTag: "1.0.0"/newTag: "1.1.0"/' k8s/dev/kustomization.yaml
kubectl apply -k k8s/dev
kubectl -n flightops-dev rollout status deployment/flight-status --timeout=120s

echo "=== [Lab 08] Part 9: Committing manifests, opening PR, and merging to main ==="
git add k8s
if ! git diff --cached --quiet; then
  git commit -m "Add Kubernetes manifests and the dev overlay"
  git push -u origin feature/kubernetes
  h_open_and_merge_pr "flightops%2Fflight-status" "feature/kubernetes" "main" "Add Kubernetes manifests" "ci"
  MAIN_SHA=$(h_api GET "/api/v1/repos/flightops%2Fflight-status/branches/main" | jq -r '.sha // .commit.sha')
  h_wait "flightops%2Fflight-status" "ci" "success" "$MAIN_SHA"
fi

git switch main
git pull
git branch -D feature/kubernetes 2>/dev/null || true

echo "=== [Lab 08] Verifying Lab 08 state ==="
git show HEAD:k8s/dev/kustomization.yaml | grep -q 'newTag: "1.1.0"'
test "$(kubectl -n flightops-dev get deployment flight-status -o jsonpath='{.status.readyReplicas}')" = "2"
for i in $(seq 1 10); do
  if curl -sf http://flights-dev.localhost:8080/version | jq -e '.version == "1.1.0"' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
echo "=== [Lab 08] Completed successfully! ==="
