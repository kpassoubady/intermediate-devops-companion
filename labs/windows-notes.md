# Windows Notes (fallback path)

The labs are written for the provided Ubuntu lab machine. Use this page only if you have no VM and are working on a Windows 11 PC (or Windows 10 22H2). The labs are Bash labs, so the way to follow them is to run Ubuntu inside WSL 2 (Windows Subsystem for Linux). Inside that Ubuntu, almost every lab command works as written. Do not run the labs in PowerShell or Git Bash.

This page has not been tested on a Windows PC yet. Report anything that differs.

## Before you start

- Hardware: 8 or more CPU cores, 16 GB of memory and 60 GB of free disk. Virtualization must be on in the BIOS (Task Manager > Performance > CPU shows "Virtualization: Enabled").
- Use an x64 PC. On Windows on Arm, follow the Apple Silicon section in [macOS notes](macos-notes.md) for image problems, and expect to download `arm64` files where the labs download `amd64` ones.
- Ports 3000 (Harness), 5000 (registry), 8000 (app) and 8080 (cluster ingress) must be free on Windows too, because WSL forwards them to `localhost`. In PowerShell:

  ```powershell
  Get-NetTCPConnection -State Listen -LocalPort 3000,5000,8000,8080 -ErrorAction SilentlyContinue
  ```

  It prints nothing when the ports are free. Stop the program that owns a port, or close it, before Lab 01.

## Set up WSL 2 and Ubuntu 24.04

1. Open PowerShell as administrator and run:

   ```powershell
   wsl --install -d Ubuntu-24.04
   ```

   Restart Windows when asked, then finish the Ubuntu first-run prompt (user name and password). From here on, every command in this course runs in this Ubuntu terminal. Open it from the Start menu or with Windows Terminal.

2. Give WSL enough memory. Create the file `C:\Users\<your name>\.wslconfig` with:

   ```ini
   [wsl2]
   memory=12GB
   processors=6
   ```

   Use `memory=8GB` on a 16 GB PC with little else running. Then run `wsl --shutdown` in PowerShell and open Ubuntu again. Harness, PostgreSQL, k3d and image builds run at the same time, so 8 GB is the minimum.

3. Turn on systemd, which Docker Engine needs. In Ubuntu:

   ```bash
   printf '[boot]\nsystemd=true\n' | sudo tee /etc/wsl.conf
   ```

   Run `wsl --shutdown` in PowerShell and open Ubuntu again. Check it with `systemctl is-system-running`. It prints `running` (or `degraded`, which is fine).

4. Check the machine as Lab 01 Part 1 does: `cat /etc/os-release`, `nproc`, `free -h`. You should see Ubuntu 24.04 and the CPUs and memory you set above.

## Where to work

- Work in the Linux file system, in your Ubuntu home folder (`~`), exactly as the labs say. Do not work under `/mnt/c`. It is slow, it breaks file permissions, and Git sees every file as changed.
- Clone the companion repository from inside Ubuntu, as Lab 01 shows. If you clone it with Windows Git, the shell scripts get CRLF line endings and fail with `bad interpreter` or `\r: command not found`. If that happens, run `sed -i 's/\r$//' ~/intermediate-devops-companion/scripts/*.sh` once, and set `git config --global core.autocrlf input` in Ubuntu.
- Edit files with VS Code on Windows. Install it from [code.visualstudio.com](https://code.visualstudio.com/) and add the WSL extension. Then `code ~/flight-status` in the Ubuntu terminal opens the folder in Windows VS Code, connected to Ubuntu. Skip the `apt-get install code` step in Lab 01 Part 2.
- Open Harness, the app and the registry in a normal Windows browser. `localhost:3000`, `localhost:8000` and `localhost:8080` reach WSL automatically, so ignore "use the browser inside the lab machine".

## Replacements by lab

Docker Engine goes inside Ubuntu, so Lab 01 Part 3 works as written. This is the recommended path, and it needs no Docker Desktop licence.

| Lab step | On the VM | On Windows with WSL |
|---|---|---|
| Lab 01 Part 1: machine check | `cat /etc/os-release`, `nproc`, `free -h` | Same, in Ubuntu |
| Lab 01 Part 2: git, curl, jq | `apt-get install` | Same |
| Lab 01 Part 2: VS Code | `apt-get install code` | Skip. Use VS Code on Windows with the WSL extension. |
| Lab 01 Part 3: Docker Engine, insecure registry, `usermod` | apt repository, `/etc/docker/daemon.json` | Same. Run `sudo systemctl restart docker` as the lab says. After `usermod`, close the Ubuntu window and run `wsl --terminate Ubuntu-24.04` if `newgrp docker` does not pick up the group. |
| Lab 04: k3d, kubectl, Terraform | linux-amd64 downloads | Same |
| Lab 07: Trivy | `.deb` download | Same |
| Any `sudo apt-get install` | apt | Same |

Because Ubuntu is the same version as the lab machine, the pinned versions (k3d v5.9.0, Terraform 1.17.0, Trivy 0.75.0) install as written and the exact-version `<!-- test -->` checks pass.

## Hostname

`k3d-registry.localhost` normally resolves to the local machine by itself. If `curl http://k3d-registry.localhost:5000/v2/_catalog` cannot resolve the name, add it in Ubuntu:

```bash
echo '127.0.0.1 k3d-registry.localhost' | sudo tee -a /etc/hosts
```

WSL rewrites `/etc/hosts` each time it starts. To keep the line, add this to `/etc/wsl.conf` and restart WSL:

```ini
[network]
generateHosts=false
```

## Alternative: Docker Desktop

Use this only if your PC already runs Docker Desktop. Check the licence terms first, because Docker Desktop needs a paid plan in many companies.

- Install Docker Desktop with the WSL 2 backend. In Settings > Resources > WSL Integration, turn on Ubuntu-24.04.
- Skip Lab 01 Part 3 (Docker Engine, `usermod`, `newgrp`). Do not install `docker-ce` in Ubuntu.
- Lab 01 3.2: add `"insecure-registries": ["k3d-registry.localhost:5000"]` in Docker Desktop > Settings > Docker Engine, then Apply & restart.
- The memory limit comes from `.wslconfig` above, not from Docker Desktop settings.

## Common problems

| Symptom | Fix |
|---|---|
| `Cannot connect to the Docker daemon` | systemd is off or Docker is stopped. Check `systemctl is-system-running`, then `sudo systemctl start docker`. With Docker Desktop, start it and check the WSL integration. |
| `bad interpreter` or `\r: command not found` in a script | CRLF line endings. See "Where to work". |
| The Windows browser cannot open `localhost:3000` | Check `docker ps` in Ubuntu. Then check that no Windows program holds the port (see "Before you start"). Run `wsl --shutdown` and start again if it still fails. |
| Builds or the cluster are very slow, or processes are killed | Not enough memory for WSL. Raise it in `.wslconfig`. Work under `~`, not `/mnt/c`. |
| `exec format error` on an image | You are on an Arm PC. See [macOS notes](macos-notes.md), "Apple Silicon". |
| Time is wrong in Ubuntu and `apt` or TLS fails after sleep or hibernate | Run `sudo hwclock -s`, or `wsl --shutdown` and start again. |

## Findings from the walkthrough

Issues found while running Labs 01 to 09 on a Windows PC are recorded here. None yet.

| Lab | Issue | Fix |
|---|---|---|
