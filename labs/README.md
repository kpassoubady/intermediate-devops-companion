# Intermediate DevOps Labs

Hands-on lab guides for the three-day Intermediate DevOps course. Throughout these nine labs, you build and run every part of an automated delivery pipeline on your own Linux lab machine using Harness Open Source, Docker, a local Kubernetes cluster (k3d), and Terraform.

The labs follow a single application across all three days: [**flight-status**](../app/README.md), a Python FastAPI web service that tracks flights and statuses.

No lab VM? See [macOS notes](macos-notes.md) for a Mac fallback.

---

## Lab Schedule and Overview

| Day | Lab | Topic | Focus Areas & Tools |
|---|---|---|---|
| **Day 1** | [Lab 01](01-lab-environment.md) | Lab environment and Harness Open Source | Package installation, Docker Engine, Harness Open Source container, initial Git repo setup |
| | [Lab 02](02-first-ci-pipeline.md) | Your first CI pipeline | Containerized linting & testing, Harness YAML pipeline, execution logs, push triggers |
| | [Lab 03](03-quality-gates.md) | Quality gates, pull requests and integration tests | PostgreSQL service containers, coverage thresholds, branch protection rules, PR workflow |
| **Day 2** | [Lab 04](04-terraform-foundations.md) | Terraform foundations on Kubernetes | Local k3d cluster, declarative IaC for dev/prod namespaces and PostgreSQL, state & drift |
| | [Lab 05](05-terraform-pipeline.md) | Terraform in the pipeline | Remote Kubernetes state backend, CI/CD pipeline for PR plans and post-merge apply, drift detection |
| | [Lab 06](06-credentials.md) | Managing credentials | Credential audits, pipeline secret masking, least-privilege ServiceAccounts, secret scanning, token rotation |
| **Day 3** | [Lab 07](07-containers.md) | Build, scan and describe a container | Multi-stage Dockerfile, image layers, Trivy vulnerability scan & SBOM, Docker Compose, AWS ECS task definitions |
| | [Lab 08](08-kubernetes-rollouts.md) | Kubernetes deployments, rollouts and rollbacks | Deployments, Services, Ingress, Kustomize overlays, quotas, zero-downtime rolling updates, failure recovery |
| | [Lab 09](09-end-to-end-delivery.md) | End-to-end delivery pipeline | Automated CI/CD pipeline: lint/test/build/scan, automated dev deploy + smoke test + auto-rollback, prod release promotion, DORA metrics |

---

## Detailed Lab Summaries

### Day 1: Continuous Integration

- **[Lab 01: Lab environment and Harness Open Source](01-lab-environment.md)**  
  Prepare your lab machine by installing core CLI utilities (`git`, `curl`, `jq`, VS Code), Docker Engine, and Harness Open Source running in a container. Create a project and repository in Harness, then push the starter `flight-status` codebase.

- **[Lab 02: Your first CI pipeline](02-first-ci-pipeline.md)**  
  Run lint and unit test checks inside Docker containers without installing Python packages locally. Model these stages as a Harness pipeline in YAML, trigger builds automatically on push, and inspect logs for failed builds.

- **[Lab 03: Quality gates, pull requests and integration tests](03-quality-gates.md)**  
  Run integration tests against a PostgreSQL container running as a pipeline background service. Enforce code coverage thresholds, protect the `main` branch with status checks, and ship a feature via branch, PR, review, and merge.

### Day 2: Infrastructure as Code and Credentials

- **[Lab 04: Terraform foundations on Kubernetes](04-terraform-foundations.md)**  
  Provision a local Kubernetes cluster using `k3d`. Write Terraform configurations defining `dev` and `prod` environments (namespaces, resource quotas, and PostgreSQL instances). Observe state tracking, idempotency, and automated drift correction before committing to a new `platform` repository.

- **[Lab 05: Terraform in the pipeline](05-terraform-pipeline.md)**  
  Migrate local Terraform state to a shared Kubernetes backend with locking. Build a pipeline that runs `terraform plan` on pull requests and `terraform apply` after merge, using the pipeline to identify infrastructure drift.

- **[Lab 06: Managing credentials](06-credentials.md)**  
  Locate where tokens, cluster credentials, and database passwords reside. Configure masked secrets in Harness, set up a least-privilege Kubernetes `ServiceAccount` for deployment automation, block leaked credentials via secret scanning, and rotate access tokens.

### Day 3: Containers, Kubernetes and Continuous Delivery

- **[Lab 07: Build, scan and describe a container](07-containers.md)**  
  Write a secure, unprivileged Dockerfile for the `flight-status` service. Inspect image layers, push to a local registry, scan with Trivy for vulnerabilities and SBOM generation, run multi-container setups with Docker Compose, and map configurations to an Amazon ECS task definition for Fargate.

- **[Lab 08: Kubernetes deployments, rollouts and rollbacks](08-kubernetes-rollouts.md)**  
  Deploy the container image to Kubernetes using Deployments, Services, Ingress, and Kustomize overlays. Observe pod self-healing, ResourceQuota ceilings, and zero-downtime rolling updates. Intentionally trigger crash, pull, and readiness failures and practice troubleshooting and recovery.

- **[Lab 09: End-to-end delivery pipeline](09-end-to-end-delivery.md)**  
  Unify all components into a complete delivery pipeline. Every PR run lints, tests, builds, and scans. Merges to `main` automatically deploy to `dev`, execute automated smoke tests, and roll back if checks fail. Create a release tag to promote tested images to `prod`, mapping each step to DORA metrics.

---

## Lab Environment

Each participant works on a personal Linux virtual machine (Ubuntu 24.04 LTS, 8 vCPUs, 16 GB RAM, 80 GB disk). All tools are installed progressively during the labs:

| Tool | Version | Installed in | Purpose |
|---|---|---|---|
| `git`, `curl`, `jq`, VS Code | Ubuntu / Microsoft packages | Lab 01 | Core development and inspection tools |
| Docker Engine | 29.x | Lab 01 | Container runtime and image builds |
| Harness Open Source | 3.3.0 | Lab 01 | Self-hosted Git repositories and CI/CD pipelines |
| k3d (k3s v1.34) | 5.9.0 | Lab 04 | Lightweight local Kubernetes cluster (stands in for Amazon EKS) |
| `kubectl` | 1.34 | Lab 04 | Kubernetes command-line client |
| Terraform | 1.17.0 | Lab 04 | Infrastructure as Code provisioning engine |
| Trivy | 0.75.0 | Lab 07 | Security scanner for container vulnerabilities and SBOMs |

---

## Catching Up & Reference Solutions

### Catch-Up Scripts
Labs are cumulative. If you join late, switch machines, or need to reset your environment, you can either run the explicit per-lab catch-up scripts (`lab01-catch-up.sh` through `lab09-catch-up.sh`) or use `catch-up.sh`:

```bash
# Run a specific lab's explicit catch-up script (completes that lab and any missing prerequisites):
~/intermediate-devops-companion/scripts/lab01-catch-up.sh
~/intermediate-devops-companion/scripts/lab02-catch-up.sh

# Or fast-forward to the start of Lab NN (runs lab01 .. lab(NN-1)):
~/intermediate-devops-companion/scripts/catch-up.sh 04
```

### Solutions
If you get stuck on a configuration or pipeline definition, reference solutions for each lab are available in [`../solutions/`](../solutions/). Each folder (`solutions/labNN/`) contains the completed files for that lab.
