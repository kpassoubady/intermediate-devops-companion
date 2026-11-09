#!/usr/bin/env bash
# ==============================================================================
# Lab 04 Catch-Up Script: Terraform foundations on Kubernetes
# Explicitly runs all commands from Lab 04 to bring a machine to the end of Lab 04.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H_URL="${H_URL:-http://localhost:3000}"
H_ADMIN="${H_ADMIN:-admin}"
H_PASSWORD="${H_PASSWORD:-Harness-Lab-2026}"
H_STATE="${H_STATE:-$HOME/.lab-runner}"
mkdir -p "$H_STATE"

# Ensure Lab 03 is complete first
if [ ! -f "$HOME/flight-status/flightstatus/rules.py" ] || ! grep -q 'def departures_board' "$HOME/flight-status/flightstatus/rules.py"; then
  echo "Lab 03 state not detected; running lab03-catch-up.sh first..."
  "$SCRIPT_DIR/lab03-catch-up.sh"
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

h_create() {
  local code
  code=$(curl -sS -o "$H_STATE/last-response.json" -w '%{http_code}' -X "$1" "$H_URL$2" \
    -H "Authorization: Bearer $(h_token)" -H 'Content-Type: application/json' -d "$3")
  case "$code" in
    2*|409) return 0 ;;
    *) echo "HTTP $code from $1 $2: $(cat "$H_STATE/last-response.json")" >&2; return 1 ;;
  esac
}

echo "=== [Lab 04] Part 1.1: Installing k3d v5.9.0 ==="
if ! k3d version 2>/dev/null | grep -q 'v5.9.0'; then
  mkdir -p ~/downloads && cd ~/downloads
  curl -fsSLO --retry 3 https://github.com/k3d-io/k3d/releases/download/v5.9.0/k3d-linux-amd64
  curl -fsSLO --retry 3 https://github.com/k3d-io/k3d/releases/download/v5.9.0/checksums.txt
  echo "$(grep '_dist/k3d-linux-amd64$' checksums.txt | cut -d' ' -f1)  k3d-linux-amd64" | sha256sum --check
  sudo install -m 0755 k3d-linux-amd64 /usr/local/bin/k3d
fi
k3d version

echo "=== [Lab 04] Part 1.2: Installing kubectl 1.34 ==="
if ! kubectl version --client 2>/dev/null | grep -q 'v1.34'; then
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y kubectl
fi
kubectl version --client

echo "=== [Lab 04] Part 1.3: Installing Terraform 1.17.0 ==="
if ! terraform version 2>/dev/null | grep -q 'v1.17.0'; then
  sudo apt-get install -y unzip
  mkdir -p ~/downloads && cd ~/downloads
  curl -fsSLO https://releases.hashicorp.com/terraform/1.17.0/terraform_1.17.0_linux_amd64.zip
  curl -fsSLO https://releases.hashicorp.com/terraform/1.17.0/terraform_1.17.0_SHA256SUMS
  grep 'linux_amd64.zip$' terraform_1.17.0_SHA256SUMS | sha256sum --check
  unzip -o terraform_1.17.0_linux_amd64.zip terraform
  sudo install -m 0755 terraform /usr/local/bin/terraform
fi
terraform version

echo "=== [Lab 04] Part 2.1: Creating local image registry k3d-registry.localhost:5000 ==="
if ! docker_cmd ps -a --format '{{.Names}}' | grep -qx 'k3d-registry.localhost'; then
  k3d registry create registry.localhost --port 5000
elif ! docker_cmd ps --format '{{.Names}}' | grep -qx 'k3d-registry.localhost'; then
  docker_cmd start k3d-registry.localhost
fi
curl -s --retry 5 --retry-connrefused --retry-delay 1 http://k3d-registry.localhost:5000/v2/_catalog
echo

echo "=== [Lab 04] Part 2.2 & 2.3: Creating k3d cluster 'devops' ==="
mkdir -p ~/platform/cluster
cat > ~/platform/cluster/k3d-devops.yaml <<'EOF'
# k3d cluster for the course labs: one k3s server, the shared "devops" Docker
# network, the local registry, and the ingress on http://localhost:8080.
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  name: devops
servers: 1
agents: 0
image: rancher/k3s:v1.34.12-k3s1
network: devops
kubeAPI:
  hostIP: "0.0.0.0"
  hostPort: "6550"
ports:
  - port: 8080:80
    nodeFilters:
      - loadbalancer
registries:
  use:
    - k3d-registry.localhost:5000
EOF

if ! k3d cluster list 2>/dev/null | grep -q '^devops '; then
  k3d cluster create --config ~/platform/cluster/k3d-devops.yaml
else
  k3d kubeconfig merge devops --kubeconfig-merge-default --kubeconfig-switch-context >/dev/null
fi
kubectl config current-context
kubectl get nodes

echo "=== [Lab 04] Part 3, 4 & 5: Writing Terraform files and Postgres module ==="
grep -q 'KUBE_CONFIG_PATH' ~/.bashrc || echo 'export KUBE_CONFIG_PATH=$HOME/.kube/config' >> ~/.bashrc
export KUBE_CONFIG_PATH=$HOME/.kube/config

mkdir -p ~/platform/modules/postgres

cat > ~/platform/versions.tf <<'EOF'
terraform {
  required_version = ">= 1.17.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

# The provider reads the cluster address and credentials from the kubeconfig
# file named in the KUBE_CONFIG_PATH environment variable.
provider "kubernetes" {}
EOF

cat > ~/platform/variables.tf <<'EOF'
variable "environments" {
  description = "Environments to create, with the resource limits of each namespace."
  type = map(object({
    cpu_limit    = string
    memory_limit = string
    max_pods     = number
  }))
  default = {
    dev = {
      cpu_limit    = "4"
      memory_limit = "4Gi"
      max_pods     = 10
    }
    prod = {
      cpu_limit    = "6"
      memory_limit = "6Gi"
      max_pods     = 15
    }
  }
}
EOF

cat > ~/platform/namespaces.tf <<'EOF'
# One namespace per environment: flightops-dev, flightops-prod.
resource "kubernetes_namespace_v1" "env" {
  for_each = var.environments

  metadata {
    name = "flightops-${each.key}"
    labels = {
      "app.kubernetes.io/part-of"    = "flightops"
      "app.kubernetes.io/managed-by" = "terraform"
      environment                    = each.key
    }
  }
}

# Upper limits for everything that runs in the namespace.
resource "kubernetes_resource_quota_v1" "env" {
  for_each = var.environments

  metadata {
    name      = "quota"
    namespace = kubernetes_namespace_v1.env[each.key].metadata[0].name
  }
  spec {
    hard = {
      "limits.cpu"    = each.value.cpu_limit
      "limits.memory" = each.value.memory_limit
      pods            = each.value.max_pods
    }
  }
}

# Default requests and limits for containers that do not set their own.
resource "kubernetes_limit_range_v1" "env" {
  for_each = var.environments

  metadata {
    name      = "defaults"
    namespace = kubernetes_namespace_v1.env[each.key].metadata[0].name
  }
  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "500m"
        memory = "256Mi"
      }
      default_request = {
        cpu    = "100m"
        memory = "128Mi"
      }
    }
  }
}
EOF

cat > ~/platform/modules/postgres/versions.tf <<'EOF'
terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}
EOF

cat > ~/platform/modules/postgres/variables.tf <<'EOF'
variable "namespace" {
  description = "Namespace to create the database in."
  type        = string
}

variable "image" {
  description = "PostgreSQL container image."
  type        = string
  default     = "postgres:17-alpine"
}

variable "storage" {
  description = "Size of the data volume."
  type        = string
  default     = "1Gi"
}
EOF

cat > ~/platform/modules/postgres/main.tf <<'EOF'
# A single PostgreSQL instance for one environment.
# Terraform generates the password and stores it, with a ready-made
# DATABASE_URL for the application, in the Secret "flight-status-db".

resource "random_password" "db" {
  length  = 24
  special = false
}

resource "kubernetes_secret_v1" "db" {
  metadata {
    name      = "flight-status-db"
    namespace = var.namespace
  }
  data = {
    POSTGRES_USER     = "flights"
    POSTGRES_PASSWORD = random_password.db.result
    POSTGRES_DB       = "flights"
    DATABASE_URL      = "postgresql://flights:${random_password.db.result}@postgres:5432/flights"
  }
}

resource "kubernetes_persistent_volume_claim_v1" "db" {
  metadata {
    name      = "postgres-data"
    namespace = var.namespace
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = var.storage
      }
    }
  }
  # k3d's local-path storage creates the volume only when a pod uses it.
  wait_until_bound = false
}

resource "kubernetes_deployment_v1" "db" {
  metadata {
    name      = "postgres"
    namespace = var.namespace
    labels = {
      app = "postgres"
    }
  }
  spec {
    replicas = 1
    # Stop the old pod before starting a new one: the volume allows one writer.
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "postgres"
      }
    }
    template {
      metadata {
        labels = {
          app = "postgres"
        }
      }
      spec {
        container {
          name  = "postgres"
          image = var.image
          # POSTGRES_USER, POSTGRES_PASSWORD and POSTGRES_DB come from the Secret.
          env_from {
            secret_ref {
              name = kubernetes_secret_v1.db.metadata[0].name
            }
          }
          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }
          port {
            container_port = 5432
          }
          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "flights"]
            }
            period_seconds = 5
          }
          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "1"
              memory = "512Mi"
            }
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/postgresql/data"
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.db.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "db" {
  metadata {
    name      = "postgres"
    namespace = var.namespace
  }
  spec {
    selector = {
      app = "postgres"
    }
    port {
      port        = 5432
      target_port = 5432
    }
  }
}
EOF

cat > ~/platform/modules/postgres/outputs.tf <<'EOF'
output "secret_name" {
  description = "Name of the Secret with the connection settings."
  value       = kubernetes_secret_v1.db.metadata[0].name
}
EOF

cat > ~/platform/databases.tf <<'EOF'
# One PostgreSQL database per environment, built from the local module.
module "postgres" {
  source   = "./modules/postgres"
  for_each = var.environments

  namespace = kubernetes_namespace_v1.env[each.key].metadata[0].name
}
EOF

cat > ~/platform/outputs.tf <<'EOF'
output "namespaces" {
  description = "Namespaces created for the environments."
  value       = [for ns in kubernetes_namespace_v1.env : ns.metadata[0].name]
}

output "database_secrets" {
  description = "Secret in each namespace that holds the database connection settings."
  value       = { for env, db in module.postgres : env => db.secret_name }
}
EOF

echo "=== [Lab 04] Initializing and applying Terraform ==="
cd ~/platform
terraform init
terraform fmt -recursive
terraform validate
terraform apply -auto-approve

kubectl -n flightops-dev rollout status deployment/postgres --timeout=300s
kubectl -n flightops-prod rollout status deployment/postgres --timeout=300s

echo "=== [Lab 04] Part 6: Creating 'platform' repository in Harness and pushing code ==="
h_create POST "/api/v1/repos" \
  '{"parent_ref":"flightops","identifier":"platform","default_branch":"main"}'

cat > ~/platform/.gitignore <<'EOF'
# Terraform working files and state. The state holds the generated database
# passwords, so it never goes into Git.
.terraform/
*.tfstate
*.tfstate.*
EOF

cd ~/platform
if [ ! -d .git ]; then
  git init -q
fi
git checkout -B main
git add .
if ! git diff --cached --quiet; then
  git commit -m "Platform: k3d cluster, namespaces, quotas and databases"
fi
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin http://localhost:3000/git/flightops/platform.git
else
  git remote add origin http://localhost:3000/git/flightops/platform.git
fi
git push -u origin main

echo "=== [Lab 04] Verifying Lab 04 state ==="
test "$(git ls-remote origin refs/heads/main | cut -f1)" = "$(git rev-parse HEAD)"
echo "=== [Lab 04] Completed successfully! ==="
