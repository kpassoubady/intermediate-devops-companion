# macOS Notes (fallback path)

The labs are written for the provided Ubuntu lab machine. Use this page only if you have no VM and are working on a Mac with Docker Desktop. Follow the numbered lab guides as written, and apply the changes below where a lab uses Linux-only commands. On a Windows PC, use [Windows notes](windows-notes.md) instead.

Tested on Apple Silicon (arm64), Docker Desktop 4.55. Run `scripts/mac-setup.sh` first. It installs the tools and checks ports.

## Before you start

- Docker Desktop: Settings > Resources, give it 6 or more CPUs and 8 to 12 GB of memory. Harness, PostgreSQL, k3d and image builds run at the same time.
- Port 5000 is used by AirPlay Receiver on macOS, and the k3d registry needs it. Turn it off in System Settings > General > AirDrop & Handoff > AirPlay Receiver. The registry address `k3d-registry.localhost:5000` is used in every lab and catch-up script, so free the port rather than using another one. From a terminal (the key is spelled this way by Apple, and the command is untested on macOS 26):

  ```bash
  defaults -currentHost write com.apple.controlcenter AirplayRecieverEnabled -bool false && killall ControlCenter
  lsof -nP -iTCP:5000 -sTCP:LISTEN   # prints nothing when the port is free
  ```

  Killing the process alone does not help, because macOS restarts it.
- Ports 3000 (Harness), 8000 (app) and 8080 (cluster ingress) must be free.

## Replacements by lab

| Lab step | On the VM | On macOS |
|---|---|---|
| Lab 01 Part 1: machine check | `cat /etc/os-release`, `nproc`, `free -h` | `sw_vers`, `sysctl -n hw.ncpu`, `docker info --format '{{.MemTotal}}'` |
| Lab 01 Part 2: git, curl, jq, VS Code | `apt-get install` | `brew install git jq` and `brew install --cask visual-studio-code` |
| Lab 01 Part 3: Docker Engine, `usermod`, `newgrp` | apt repository | Skip. Docker Desktop replaces them. |
| Lab 01 3.2: insecure registry | `/etc/docker/daemon.json`, `systemctl restart docker` | Docker Desktop > Settings > Docker Engine. Add `"insecure-registries": ["k3d-registry.localhost:5000"]` to the JSON, then Apply & restart. |
| Lab 04: k3d | `k3d-linux-amd64` download | `brew install k3d` |
| Lab 04: kubectl | `apt-get install kubectl` | `brew install kubectl` |
| Lab 04: Terraform | `linux_amd64.zip` download | `brew install hashicorp/tap/terraform` |
| Lab 07: Trivy | `.deb` download | `brew install trivy` |
| Any `sudo apt-get install` | apt | `brew install` |
| `sha256sum --check` | GNU coreutils | `shasum -a 256 --check` |

Skip any `sudo chown`, `sudo systemctl` and `newgrp` step. Docker Desktop runs as your user.

## Hostname

If `curl http://k3d-registry.localhost:5000/v2/_catalog` cannot resolve the name, add it:

```bash
echo '127.0.0.1 k3d-registry.localhost' | sudo tee -a /etc/hosts
```

## Version differences

Homebrew installs the newest release, not the pinned one. The labs pin k3d v5.9.0, Terraform 1.17.0 and Trivy 0.75.0. Output can differ slightly, and a lab's `<!-- test -->` check on an exact version, such as `k3d version | grep -q 'v5.9.0'`, fails. Ignore it, or install the pinned version from the release page, choosing the `darwin_arm64` file.

## Apple Silicon

Most images are multi-arch and run natively. If an image fails with `exec format error` or `no matching manifest for linux/arm64`, add `--platform linux/amd64` to the `docker run` or `docker build`. It works through emulation and is slower.

## Findings from the walkthrough

Issues found while running Labs 01 to 09 on a Mac are recorded here.

| Lab | Issue | Fix |
|---|---|---|
| 01, 04 | Homebrew has k3d v5.8.3, not the pinned v5.9.0 (Terraform 1.17.1 and Trivy 0.76.2 are also newer than the pins) | Use brew versions; skip exact-version checks |
| 01 | Docker Desktop defaults to about 8 GB, the minimum for the course | Raise memory in Settings > Resources |
