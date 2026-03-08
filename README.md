# Proxmox Cloud-Init VM Creator

Interactive bash script that creates cloud-init VMs on Proxmox VE with automatic installation of Docker Compose v2 and qemu-guest-agent.

## Supported Operating Systems

| OS | Versions | Default User |
|----|----------|-------------|
| **Ubuntu** | 22.04 LTS (Jammy), 24.04 LTS (Noble), 24.10 (Oracular) | `ubuntu` |
| **Debian** | 11 (Bullseye), 12 (Bookworm) | `debian` |
| **Fedora** | 40, 41 | `fedora` |
| **Custom** | Any cloud image (.img/.qcow2) | configurable |

## Features

- **Multi-distro support** — Ubuntu, Debian, and Fedora with official cloud images
- **Auto-detects storage** — identifies LVM, ZFS, directory, Ceph, and network-backed pools
- **Interactive prompts** — OS, VM ID, hostname, CPU, RAM, disk, network (DHCP/static), VLAN, SSH keys, user/password
- **Cloud-init provisioning** — installs packages on first boot via vendor data snippets:
  - `qemu-guest-agent`
  - Docker Engine (official repo — apt for Ubuntu/Debian, dnf for Fedora)
  - Docker Compose v2 (plugin)
- **Downloads cloud image** — fetches the official cloud image if not already cached
- **Summary + confirmation** — shows a full config table before creating anything

## Requirements

- Proxmox VE 7.x or 8.x
- Root access on the Proxmox node
- Internet access (for cloud image download and first-boot package installs)

## Usage

```bash
# Download and run
wget -O create-vm.sh https://raw.githubusercontent.com/paradosi/proxmox-cloudinit-script/main/create-vm.sh
chmod +x create-vm.sh
sudo ./create-vm.sh
```

Or clone the repo:

```bash
git clone https://github.com/paradosi/proxmox-cloudinit-script.git
cd proxmox-cloudinit-script
chmod +x create-vm.sh
sudo ./create-vm.sh
```

## What It Asks

| Prompt | Default | Description |
|--------|---------|-------------|
| Operating system | Ubuntu 22.04 | Choose from Ubuntu, Debian, Fedora, or custom image |
| Storage pool | auto-detected | Only pools supporting disk images are shown |
| VM ID | 9000 | Validates uniqueness and range (>=100) |
| Hostname | ubuntu-cloud | Sets the VM name and cloud-init hostname |
| CPU cores | 2 | vCPU count |
| RAM | 2048 MB | Memory allocation |
| Disk size | 20G | Cloud image disk is resized to this |
| Bridge | vmbr0 | Network bridge (auto-detected) |
| IP mode | Static | DHCP or static with CIDR + gateway |
| DNS | 1.1.1.1, 8.8.8.8 | Nameservers for static IP |
| VLAN tag | none | Optional 802.1Q tag |
| Username | per-distro | Cloud-init default user (ubuntu/debian/fedora) |
| Password | none | Optional — enables SSH password auth via cloud-init |
| SSH key | ~/.ssh/id_rsa.pub | Public key file or paste key directly |
| Docker | yes | Docker Engine + Compose v2 plugin |
| Guest Agent | yes | qemu-guest-agent service |
| Auto-start | prompt | Start the VM immediately after creation |

## After Creation

The VM will boot, run cloud-init, install all packages, then **reboot once** automatically. After the reboot (~2-3 minutes), Docker and the guest agent will be ready:

```bash
ssh <user>@<VM_IP>
docker compose version    # Docker Compose v2
sudo systemctl status qemu-guest-agent
```

## License

MIT
