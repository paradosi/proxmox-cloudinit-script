# Proxmox Ubuntu 22.04 Cloud-Init VM Creator

Interactive bash script that creates Ubuntu 22.04 (Jammy) cloud-init VMs on Proxmox VE with automatic installation of Docker Compose v2 and qemu-guest-agent.

## Features

- **Auto-detects storage** — identifies LVM, ZFS, directory, Ceph, and network-backed pools
- **Interactive prompts** — VM ID, hostname, CPU, RAM, disk, network (DHCP/static), VLAN, SSH keys, user/password
- **Cloud-init provisioning** — installs packages on first boot via vendor data snippets:
  - `qemu-guest-agent`
  - Docker Engine (official apt repo)
  - Docker Compose v2 (plugin)
- **Downloads cloud image** — fetches the official Ubuntu 22.04 cloud image if not already cached
- **Summary + confirmation** — shows a full config table before creating anything

## Requirements

- Proxmox VE 7.x or 8.x
- Root access on the Proxmox node
- Internet access (for cloud image download and first-boot package installs)

## Usage

```bash
# Download and run
wget -O create-vm.sh https://raw.githubusercontent.com/YOUR_USER/proxmox-cloudinit-script/main/create-vm.sh
chmod +x create-vm.sh
sudo ./create-vm.sh
```

Or clone the repo:

```bash
git clone https://github.com/YOUR_USER/proxmox-cloudinit-script.git
cd proxmox-cloudinit-script
chmod +x create-vm.sh
sudo ./create-vm.sh
```

## What It Asks

| Prompt | Default | Description |
|--------|---------|-------------|
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
| Username | ubuntu | Cloud-init default user |
| Password | none | Optional password auth |
| SSH key | ~/.ssh/id_rsa.pub | Public key file or inline key |
| Docker | yes | Docker Engine + Compose v2 plugin |
| Guest Agent | yes | qemu-guest-agent service |
| Auto-start | prompt | Start the VM immediately after creation |

## After Creation

The VM will boot, run cloud-init, install all packages, then **reboot once** automatically. After the reboot (~2-3 minutes), Docker and the guest agent will be ready:

```bash
ssh ubuntu@<VM_IP>
docker compose version    # Docker Compose v2
sudo systemctl status qemu-guest-agent
```

## License

MIT
