#!/usr/bin/env bash
# ==============================================================================
# Lab 06 Catch-Up Script: Managing credentials
# Explicitly runs all commands from Lab 06 to bring a machine to the end of Lab 06.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H_URL="${H_URL:-http://localhost:3000}"
H_ADMIN="${H_ADMIN:-admin}"
H_PASSWORD="${H_PASSWORD:-Harness-Lab-2026}"
H_STATE="${H_STATE:-$HOME/.lab-runner}"
mkdir -p "$H_STATE"

# Ensure Lab 05 is complete first
if ! kubectl -n terraform get secret tfstate-default-platform >/dev/null 2>&1; then
  echo "Lab 05 state not detected; running lab05-catch-up.sh first..."
  "$SCRIPT_DIR/lab05-catch-up.sh"
fi

export KUBE_CONFIG_PATH=$HOME/.kube/config

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

h_upsert_secret() {
  local space=$1 name=$2 val=$3 body
  body=$(jq -n --arg s "$space" --arg n "$name" --arg d "$val" '{space_ref:$s,identifier:$n,data:$d}')
  if h_api GET "/api/v1/secrets/${space}%2F${name}" >/dev/null 2>&1; then
    h_api PATCH "/api/v1/secrets/${space}%2F${name}" "$(jq -n --arg d "$val" '{data:$d}')" >/dev/null
  else
    h_api POST "/api/v1/secrets" "$body" >/dev/null
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

echo "=== [Lab 06] Part 2.1: Creating 'demo_api_key' secret in Harness ==="
h_upsert_secret "flightops" "demo_api_key" "fs-demo-7Q2x9LmP4kV8"

echo "=== [Lab 06] Part 3: Adding least-privilege deployer ServiceAccounts via Terraform ==="
cd ~/platform
git switch main
git pull
git checkout -B deployers

cat > ~/platform/deployers.tf <<'EOF'
# A ServiceAccount per environment for the delivery pipeline (Lab 06).
# Its Role allows changes to the application's objects in one namespace only.

# Increase an environment's number to rotate its deployer token, for example dev = 2.
# A long-lived ServiceAccount token depends only on the ServiceAccount and on the
# name of its Secret. A new token therefore needs a Secret with a new name.
variable "deployer_token_versions" {
  description = "Version of each environment's deployer token. Increase it to rotate the token."
  type        = map(number)
  default = {
    dev  = 1
    prod = 1
  }
}

resource "kubernetes_service_account_v1" "deployer" {
  for_each = var.environments

  metadata {
    name      = "deployer"
    namespace = kubernetes_namespace_v1.env[each.key].metadata[0].name
  }
}

resource "kubernetes_role_v1" "deployer" {
  for_each = var.environments

  metadata {
    name      = "deployer"
    namespace = kubernetes_namespace_v1.env[each.key].metadata[0].name
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch", "create", "update", "patch"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["replicasets"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = [""]
    resources  = ["services", "configmaps"]
    verbs      = ["get", "list", "watch", "create", "update", "patch"]
  }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["get", "list", "watch", "create", "update", "patch"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "events"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "deployer" {
  for_each = var.environments

  metadata {
    name      = "deployer"
    namespace = kubernetes_namespace_v1.env[each.key].metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.deployer[each.key].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.deployer[each.key].metadata[0].name
    namespace = kubernetes_namespace_v1.env[each.key].metadata[0].name
  }
}

# A long-lived token for the ServiceAccount, stored in a Secret named
# deployer-token-v<version>. Kubernetes writes the token into the Secret.
resource "kubernetes_secret_v1" "deployer_token" {
  for_each = var.environments

  metadata {
    name      = "deployer-token-v${var.deployer_token_versions[each.key]}"
    namespace = kubernetes_namespace_v1.env[each.key].metadata[0].name
    labels = {
      "app.kubernetes.io/component" = "deployer-token"
    }
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.deployer[each.key].metadata[0].name
    }
  }
  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}
EOF

git add deployers.tf
if ! git diff --cached --quiet; then
  git commit -m "Add deployer service accounts"
  git push -u origin deployers
  h_open_and_merge_pr "flightops%2Fplatform" "deployers" "main" "Add deployer service accounts" "infra"
  MAIN_SHA=$(h_api GET "/api/v1/repos/flightops%2Fplatform/branches/main" | jq -r '.sha // .commit.sha')
  h_wait "flightops%2Fplatform" "infra" "success" "$MAIN_SHA"
fi

git switch main
git pull
git branch -D deployers 2>/dev/null || true

echo "=== [Lab 06] Part 3.5: Creating ~/make-deployer-kubeconfig.sh and deployer kubeconfigs ==="
cat > ~/make-deployer-kubeconfig.sh <<'EOF'
#!/usr/bin/env bash
# Write ~/deployer-<env>.kubeconfig for the deployer ServiceAccount of one environment.
# Usage: ~/make-deployer-kubeconfig.sh dev
set -euo pipefail
ENV="$1"
NS="flightops-$ENV"
SECRET=$(kubectl -n "$NS" get secret -l app.kubernetes.io/component=deployer-token -o jsonpath='{.items[0].metadata.name}')
TOKEN=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.token}' | base64 -d)
CA=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.ca\.crt}')
OUT="$HOME/deployer-$ENV.kubeconfig"
umask 077
cat > "$OUT" <<KUBE_EOF
apiVersion: v1
kind: Config
clusters:
- name: devops
  cluster:
    server: https://k3d-devops-serverlb:6443
    certificate-authority-data: $CA
users:
- name: deployer
  user:
    token: $TOKEN
contexts:
- name: deployer
  context:
    cluster: devops
    user: deployer
    namespace: $NS
current-context: deployer
KUBE_EOF
echo "Wrote $OUT from the Secret $SECRET"
EOF

chmod +x ~/make-deployer-kubeconfig.sh
~/make-deployer-kubeconfig.sh dev
~/make-deployer-kubeconfig.sh prod

echo "=== [Lab 06] Part 3.7: Storing dev_kubeconfig and prod_kubeconfig in Harness ==="
h_upsert_secret "flightops" "dev_kubeconfig" "$(cat ~/deployer-dev.kubeconfig)"
h_upsert_secret "flightops" "prod_kubeconfig" "$(cat ~/deployer-prod.kubeconfig)"

echo "=== [Lab 06] Part 4.1: Enabling secret scanning on flightops/flight-status ==="
h_api PATCH "/api/v1/repos/flightops%2Fflight-status/settings/security" '{"secret_scanning_enabled":true}' >/dev/null

echo "=== [Lab 06] Part 5: Rotating dev deployer token to v2 and updating dev_kubeconfig ==="
cd ~/platform
git switch main
git pull
git checkout -B rotate-dev-token
sed -i 's/^    dev  = 1$/    dev  = 2/' deployers.tf

git add deployers.tf
if ! git diff --cached --quiet; then
  git commit -m "Rotate the dev deployer token"
  git push -u origin rotate-dev-token
  h_open_and_merge_pr "flightops%2Fplatform" "rotate-dev-token" "main" "Rotate the dev deployer token" "infra"
  MAIN_SHA=$(h_api GET "/api/v1/repos/flightops%2Fplatform/branches/main" | jq -r '.sha // .commit.sha')
  h_wait "flightops%2Fplatform" "infra" "success" "$MAIN_SHA"
fi

git switch main
git pull
git branch -D rotate-dev-token 2>/dev/null || true

~/make-deployer-kubeconfig.sh dev
kubectl --kubeconfig ~/deployer-dev.kubeconfig --server https://0.0.0.0:6550 get deployments
h_upsert_secret "flightops" "dev_kubeconfig" "$(cat ~/deployer-dev.kubeconfig)"

echo "=== [Lab 06] Verifying Lab 06 state ==="
SA=system:serviceaccount:flightops-dev:deployer
test "$(kubectl auth can-i create deployments -n flightops-dev --as=$SA)" = "yes"
test "$(kubectl auth can-i create deployments -n flightops-prod --as=$SA)" = "no"
test "$(kubectl auth can-i get secrets -n flightops-dev --as=$SA)" = "no"
echo "=== [Lab 06] Completed successfully! ==="
