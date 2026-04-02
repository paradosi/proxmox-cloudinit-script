# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.0.0] - 2026-03-08

### Added
- Initial release: interactive bash script (`create-vm.sh`) for creating cloud-init VMs on Proxmox VE 7.x/8.x
- Multi-distro support: Ubuntu 22.04 LTS, 24.04 LTS, 24.10; Debian 11, 12; Fedora 40, 41; and custom image URL
- Auto-detection of Proxmox storage pools (LVM, ZFS, directory, Ceph, network-backed)
- Interactive prompts for OS, VM ID, hostname, CPU, RAM, disk size, network bridge, IP mode (DHCP/static), VLAN tag, username, password, and SSH key
- Cloud-init vendor data provisioning on first boot: `qemu-guest-agent`, Docker Engine (official repos for apt/dnf), and Docker Compose v2 plugin
- Automatic download of official cloud images if not cached
- Full config summary table with confirmation before creating anything
- SSH password auth enabled in cloud-init when a password is provided
- CPU type set to `host` for full CPU flag passthrough
- `build-essential` included in cloud-init package installs
- SSH key validation and normalization before passing to `qm`
- MIT license
