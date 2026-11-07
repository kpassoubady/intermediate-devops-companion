#!/usr/bin/env bash
# ==============================================================================
# Lab 05 Catch-Up Script: Terraform in the pipeline
# Explicitly runs all commands from Lab 05 to bring a machine to the end of Lab 05.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H_URL="${H_URL:-http://localhost:3000}"
H_ADMIN="${H_ADMIN:-admin}"
H_PASSWORD="${H_PASSWORD:-Harness-Lab-2026}"
H_STATE="${H_STATE:-$HOME/.lab-runner}"
mkdir -p "$H_STATE"

# Ensure Lab 04 is complete first
if [ ! -d "$HOME/platform/.git" ] || ! kubectl get namespace flightops-dev >/dev/null 2>&1; then
  echo "Lab 04 state not detected; running lab04-catch-up.sh first..."
  "$SCRIPT_DIR/lab04-catch-up.sh"
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

h_create() {
  local code
  code=$(curl -sS -o "$H_STATE/last-response.json" -w '%{http_code}' -X "$1" "$H_URL$2" \
    -H "Authorization: Bearer $(h_token)" -H 'Content-Type: application/json' -d "$3")
  case "$code" in
    2*|409) return 0 ;;
    *) echo "HTTP $code from $1 $2: $(cat "$H_STATE/last-response.json")" >&2; return 1 ;;
  esac
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

echo "=== [Lab 05] Part 1.2: Applying bootstrap Terraform admin objects ==="
mkdir -p ~/platform/bootstrap
cat > ~/platform/bootstrap/terraform-admin.yaml <<'EOF'
# Bootstrap objects for Terraform automation (Lab 05).
# An administrator applies this file once with kubectl. Terraform does not
# manage these objects, because it needs them before it can run.
apiVersion: v1
kind: Namespace
metadata:
  name: terraform
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: terraform
  namespace: terraform
---
# cluster-admin allows every action in the whole cluster. Terraform needs wide
# rights here because it creates namespaces. Protect this credential (Lab 06).
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: terraform-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: terraform
    namespace: terraform
---
# A long-lived token for the ServiceAccount. Kubernetes writes the token into
# this Secret after it is created.
apiVersion: v1
kind: Secret
metadata:
  name: terraform-token
  namespace: terraform
  annotations:
    kubernetes.io/service-account.name: terraform
type: kubernetes.io/service-account-token
EOF

kubectl apply -f ~/platform/bootstrap/terraform-admin.yaml
kubectl -n terraform get serviceaccount,secret
kubectl auth can-i create namespaces --as=system:serviceaccount:terraform:terraform

echo "=== [Lab 05] Part 2: Migrating Terraform state to Kubernetes backend ==="
cat > ~/platform/backend.tf <<'EOF'
# Store the state in a Kubernetes Secret (tfstate-default-platform) in the
# "terraform" namespace. The backend uses a Lease object as the state lock.
# It reads the kubeconfig file named in KUBE_CONFIG_PATH.
terraform {
  backend "kubernetes" {
    secret_suffix = "platform"
    namespace     = "terraform"
  }
}
EOF

cd ~/platform
git switch main
if [ -f terraform.tfstate ]; then
  terraform init -migrate-state -force-copy
else
  terraform init
fi
rm -f terraform.tfstate terraform.tfstate.backup
terraform plan

git add backend.tf bootstrap/
if ! git diff --cached --quiet; then
  git commit -m "Store Terraform state in the cluster"
  git push
fi

echo "=== [Lab 05] Part 3: Creating ~/platform.kubeconfig and storing as Harness secret ==="
TOKEN=$(kubectl -n terraform get secret terraform-token -o jsonpath='{.data.token}' | base64 -d)
CA=$(kubectl -n terraform get secret terraform-token -o jsonpath='{.data.ca\.crt}')
touch ~/platform.kubeconfig && chmod 600 ~/platform.kubeconfig
cat > ~/platform.kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- name: devops
  cluster:
    server: https://k3d-devops-serverlb:6443
    certificate-authority-data: ${CA}
users:
- name: terraform
  user:
    token: ${TOKEN}
contexts:
- name: terraform
  context:
    cluster: devops
    user: terraform
current-context: terraform
EOF
unset TOKEN CA

kubectl --kubeconfig ~/platform.kubeconfig --server https://0.0.0.0:6550 auth whoami
h_upsert_secret "flightops" "platform_kubeconfig" "$(cat ~/platform.kubeconfig)"

echo "=== [Lab 05] Part 4: Writing .harness/infra.yaml and creating 'infra' pipeline ==="
mkdir -p ~/platform/.harness
cat > ~/platform/.harness/infra.yaml <<'EOF'
# Terraform pipeline for the platform repository (Lab 05).
# Pull requests: check formatting, validate and show the plan.
# Pushes to main (merged pull requests): apply the changes.
kind: pipeline
spec:
  stages:
  - name: terraform
    type: ci
    spec:
      envs:
        KUBE_CONFIG_PATH: /tmp/kubeconfig
        TF_IN_AUTOMATION: "true"
        TF_INPUT: "false"
      steps:
      - name: plan
        type: run
        spec:
          container: hashicorp/terraform:1.17.0
          envs:
            KUBECONFIG_CONTENT: ${{ secrets.get("platform_kubeconfig") }}
          script: |
            printf '%s\n' "$KUBECONFIG_CONTENT" > "$KUBE_CONFIG_PATH"
            terraform fmt -check -recursive
            terraform init
            terraform validate
            terraform plan -lock-timeout=60s
      - name: apply
        type: run
        when: build.event == "push" and build.target == "main"
        spec:
          container: hashicorp/terraform:1.17.0
          envs:
            KUBECONFIG_CONTENT: ${{ secrets.get("platform_kubeconfig") }}
          script: |
            printf '%s\n' "$KUBECONFIG_CONTENT" > "$KUBE_CONFIG_PATH"
            terraform init
            terraform apply -auto-approve -lock-timeout=60s
EOF

cd ~/platform
git add .harness/infra.yaml
if ! git diff --cached --quiet; then
  git commit -m "Add the infra pipeline"
  git push
fi

h_create POST "/api/v1/repos/flightops%2Fplatform/pipelines" \
  '{"identifier":"infra","config_path":".harness/infra.yaml","default_branch":"main"}'

h_create POST "/api/v1/repos/flightops%2Fplatform/pipelines/infra/triggers" \
  '{"identifier":"push","actions":["branch_updated"],"disabled":false}'

echo "=== [Lab 05] Part 5: Raising dev pod quota to 12 via Pull Request ==="
cd ~/platform
git checkout -B raise-dev-pods
sed -i 's/max_pods     = 10/max_pods     = 12/' variables.tf
terraform fmt -check -recursive
terraform validate

git add variables.tf
if ! git diff --cached --quiet; then
  git commit -m "Allow 12 pods in dev"
  git push -u origin raise-dev-pods
  h_open_and_merge_pr "flightops%2Fplatform" "raise-dev-pods" "main" "Allow 12 pods in dev" "infra"
  MAIN_SHA=$(h_api GET "/api/v1/repos/flightops%2Fplatform/branches/main" | jq -r '.sha // .commit.sha')
  h_wait "flightops%2Fplatform" "infra" "success" "$MAIN_SHA"
fi

git switch main
git pull
git branch -D raise-dev-pods 2>/dev/null || true

echo "=== [Lab 05] Verifying Lab 05 state ==="
test "$(kubectl -n flightops-dev get resourcequota quota -o jsonpath='{.spec.hard.pods}')" = "12"
echo "=== [Lab 05] Completed successfully! ==="
