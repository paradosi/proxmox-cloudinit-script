#!/usr/bin/env bash
#
# Interactive Proxmox Cloud-Init VM Creator
# Supports: Ubuntu, Debian, Fedora cloud images
# Installs: qemu-guest-agent, Docker Engine, Docker Compose v2
#
set -euo pipefail

# ──────────────────────────────────────────────
# Colors & helpers
# ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

prompt() {
    local var_name="$1" prompt_text="$2"
    local has_default=false default=""
    if [[ $# -ge 3 ]]; then
        has_default=true
        default="$3"
    fi

    if $has_default && [[ -n "$default" ]]; then
        read -rp "$(echo -e "${BOLD}${prompt_text}${NC} [${default}]: ")" value
        eval "$var_name=\"${value:-$default}\""
    elif $has_default; then
        # Optional field — empty is allowed
        read -rp "$(echo -e "${BOLD}${prompt_text}${NC}: ")" value
        eval "$var_name=\"$value\""
    else
        # Required field — empty is not allowed
        read -rp "$(echo -e "${BOLD}${prompt_text}${NC}: ")" value
        [[ -z "$value" ]] && error "A value is required."
        eval "$var_name=\"$value\""
    fi
}

prompt_password() {
    local var_name="$1" prompt_text="$2"
    read -srp "$(echo -e "${BOLD}${prompt_text}${NC}: ")" value
    echo
    eval "$var_name=\"$value\""
}

confirm() {
    local msg="$1"
    read -rp "$(echo -e "${BOLD}${msg}${NC} [y/N]: ")" ans
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# ──────────────────────────────────────────────
# Pre-flight checks
# ──────────────────────────────────────────────
echo -e "\n${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║    Proxmox Cloud-Init VM Creator                 ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}\n"

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (or with sudo)."
fi

if ! command -v qm &>/dev/null; then
    error "This does not appear to be a Proxmox node ('qm' not found)."
fi

if ! command -v pvesm &>/dev/null; then
    error "'pvesm' not found. Is Proxmox VE installed?"
fi

PVE_VERSION=$(pveversion 2>/dev/null || echo "unknown")
info "Proxmox VE version: ${PVE_VERSION}"

# ──────────────────────────────────────────────
# Storage detection
# ──────────────────────────────────────────────
echo -e "\n${BOLD}── Storage Detection ──${NC}\n"

declare -A STORAGE_MAP
STORAGE_LIST=()

# Parse /etc/pve/storage.cfg to get storage name, type, and content
CURRENT_NAME=""
CURRENT_TYPE=""
while IFS= read -r line; do
    # Storage definition lines look like: "dir: local" or "lvmthin: local-lvm"
    if [[ "$line" =~ ^([a-zA-Z]+):\ +(.+)$ ]]; then
        CURRENT_TYPE="${BASH_REMATCH[1]}"
        CURRENT_NAME="${BASH_REMATCH[2]}"
        continue
    fi

    # Content line inside a storage block
    if [[ -n "$CURRENT_NAME" && "$line" =~ ^[[:space:]]+content[[:space:]]+(.*) ]]; then
        content="${BASH_REMATCH[1]}"

        if echo "$content" | grep -q "images"; then
            # Verify the storage is actually active
            if pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$CURRENT_NAME"; then
                STORAGE_MAP["$CURRENT_NAME"]="$CURRENT_TYPE"
                STORAGE_LIST+=("$CURRENT_NAME")

                case "$CURRENT_TYPE" in
                    lvmthin|lvm)  label="LVM (${CURRENT_TYPE})" ;;
                    zfspool)      label="ZFS" ;;
                    dir)          label="Directory" ;;
                    nfs|cifs|glusterfs) label="Network (${CURRENT_TYPE})" ;;
                    rbd|cephfs)   label="Ceph (${CURRENT_TYPE})" ;;
                    *)            label="${CURRENT_TYPE}" ;;
                esac
                echo -e "  ${GREEN}●${NC} ${BOLD}${CURRENT_NAME}${NC} — ${label}"
            fi
        fi
        CURRENT_NAME=""
        CURRENT_TYPE=""
    fi
done < /etc/pve/storage.cfg

# Fallback: some storage types (lvm, lvmthin, zfspool) implicitly support images
# even without an explicit content line. Check pvesm status for these.
while IFS= read -r line; do
    [[ "$line" == Name* ]] && continue
    name=$(echo "$line" | awk '{print $1}')
    type=$(echo "$line" | awk '{print $2}')
    status=$(echo "$line" | awk '{print $3}')

    # Skip already-found storages or inactive ones
    [[ -n "${STORAGE_MAP[$name]+x}" ]] && continue
    [[ "$status" != "active" ]] && continue

    # These types always support disk images
    if [[ "$type" == "lvmthin" || "$type" == "lvm" || "$type" == "zfspool" || "$type" == "rbd" ]]; then
        STORAGE_MAP["$name"]="$type"
        STORAGE_LIST+=("$name")

        case "$type" in
            lvmthin|lvm)  label="LVM (${type})" ;;
            zfspool)      label="ZFS" ;;
            rbd)          label="Ceph (${type})" ;;
            *)            label="${type}" ;;
        esac
        echo -e "  ${GREEN}●${NC} ${BOLD}${name}${NC} — ${label}"
    fi
done < <(pvesm status 2>/dev/null)

if [[ ${#STORAGE_LIST[@]} -eq 0 ]]; then
    error "No storage pools with 'images' content type found."
fi

echo
if [[ ${#STORAGE_LIST[@]} -eq 1 ]]; then
    STORAGE="${STORAGE_LIST[0]}"
    info "Only one storage available, auto-selected: ${STORAGE} (${STORAGE_MAP[$STORAGE]})"
else
    prompt STORAGE "Select storage pool (${STORAGE_LIST[*]})" "${STORAGE_LIST[0]}"
    if [[ -z "${STORAGE_MAP[$STORAGE]+x}" ]]; then
        error "Invalid storage pool: ${STORAGE}"
    fi
fi

STORAGE_TYPE="${STORAGE_MAP[$STORAGE]}"
success "Using storage: ${STORAGE} (${STORAGE_TYPE})"

# ──────────────────────────────────────────────
# VM configuration prompts
# ──────────────────────────────────────────────
echo -e "\n${BOLD}── VM Configuration ──${NC}\n"

while true; do
    prompt VMID "VM ID (100-999999)" "9000"
    if ! [[ "$VMID" =~ ^[0-9]+$ ]] || [[ "$VMID" -lt 100 ]]; then
        warn "VM ID must be a number >= 100. Try again."
        continue
    fi
    if qm status "$VMID" &>/dev/null; then
        warn "VM ${VMID} already exists. Choose a different ID."
        continue
    fi
    break
done

prompt VM_NAME "VM hostname" "ubuntu-cloud"
prompt CPU_CORES "CPU cores" "2"
prompt RAM_MB "RAM in MB" "2048"
prompt DISK_SIZE "Disk size (e.g. 20G, 50G)" "20G"

# ──────────────────────────────────────────────
# Network configuration
# ──────────────────────────────────────────────
echo -e "\n${BOLD}── Network Configuration ──${NC}\n"

BRIDGES=$(ip link show type bridge 2>/dev/null | grep -oP '^\d+: \K[^:]+' || echo "vmbr0")
info "Detected bridges: ${BRIDGES}"

prompt BRIDGE "Network bridge" "vmbr0"

echo -e "  ${CYAN}1)${NC} DHCP"
echo -e "  ${CYAN}2)${NC} Static IP"
prompt IP_MODE "IP mode (1 or 2)" "2"

if [[ "$IP_MODE" == "2" ]]; then
    prompt VM_IP "Static IP with CIDR (e.g. 192.168.1.100/24)" ""
    prompt GATEWAY "Gateway" ""
    prompt DNS_SERVERS "DNS servers (comma-separated)" "1.1.1.1,8.8.8.8"
    prompt DNS_DOMAIN "Search domain (optional)" ""
    IP_CONFIG="ip=${VM_IP},gw=${GATEWAY}"
else
    IP_CONFIG="ip=dhcp"
    DNS_SERVERS=""
    DNS_DOMAIN=""
fi

prompt VLAN_TAG "VLAN tag (leave empty for none)" ""

# ──────────────────────────────────────────────
# User & SSH configuration
# ──────────────────────────────────────────────
echo -e "\n${BOLD}── User & SSH Configuration ──${NC}\n"

prompt CI_USER "Cloud-init username" "$DEFAULT_USER"

if confirm "Set a password for ${CI_USER}?"; then
    prompt_password CI_PASS "Password"
else
    CI_PASS=""
fi

SSH_KEYS_FILE=""
if confirm "Add an SSH public key?"; then
    prompt SSH_KEY_INPUT "Path to SSH public key file on this server, or paste the key directly" "$HOME/.ssh/id_rsa.pub"

    # Resolve the key content
    if [[ -f "$SSH_KEY_INPUT" ]]; then
        SSH_KEY_CONTENT=$(cat "$SSH_KEY_INPUT")
        success "SSH key file found: ${SSH_KEY_INPUT}"
    elif echo "$SSH_KEY_INPUT" | grep -qE '^(ssh-(rsa|ed25519|ecdsa)|ecdsa-sha2-)'; then
        # Input looks like an actual key pasted inline
        SSH_KEY_CONTENT="$SSH_KEY_INPUT"
    else
        # Not a valid file and not a key — probably a path that doesn't exist here
        warn "File not found: ${SSH_KEY_INPUT}"
        warn "If the key is on another machine, paste the key content directly."
        echo
        read -rp "$(echo -e "${BOLD}Paste your SSH public key (or leave empty to skip)${NC}: ")" SSH_KEY_CONTENT
    fi

    # Validate it looks like an SSH public key
    if [[ -z "$SSH_KEY_CONTENT" ]]; then
        info "No SSH key provided. Skipping."
        SSH_KEYS_FILE=""
    elif ! echo "$SSH_KEY_CONTENT" | grep -qE '^(ssh-(rsa|ed25519|ecdsa)|ecdsa-sha2-)'; then
        warn "Does not look like a valid SSH public key. Skipping."
        SSH_KEYS_FILE=""
    else
        # Write to a clean temp file (one key per line, no trailing whitespace)
        SSH_KEYS_FILE=$(mktemp /tmp/ssh_key_XXXXXX.pub)
        echo "$SSH_KEY_CONTENT" | sed 's/[[:space:]]*$//' > "$SSH_KEYS_FILE"
        success "SSH key validated and ready."
    fi
fi

# ──────────────────────────────────────────────
# Software options
# ──────────────────────────────────────────────
echo -e "\n${BOLD}── Software Packages ──${NC}\n"

info "The following will be installed via cloud-init on first boot:"
echo -e "  ${GREEN}●${NC} qemu-guest-agent"
echo -e "  ${GREEN}●${NC} Docker Engine (official repo)"
echo -e "  ${GREEN}●${NC} Docker Compose v2 (plugin)"
echo

INSTALL_DOCKER=true
if ! confirm "Install Docker + Compose v2?"; then
    INSTALL_DOCKER=false
fi

INSTALL_AGENT=true
if ! confirm "Install qemu-guest-agent?"; then
    INSTALL_AGENT=false
fi

# ──────────────────────────────────────────────
# OS Selection & Cloud Image
# ──────────────────────────────────────────────
echo -e "\n${BOLD}── Operating System ──${NC}\n"

echo -e "  ${CYAN}Ubuntu:${NC}"
echo -e "    ${BOLD}1)${NC}  Ubuntu 22.04 LTS (Jammy)"
echo -e "    ${BOLD}2)${NC}  Ubuntu 24.04 LTS (Noble)"
echo -e "    ${BOLD}3)${NC}  Ubuntu 24.10 (Oracular)"
echo -e ""
echo -e "  ${CYAN}Debian:${NC}"
echo -e "    ${BOLD}4)${NC}  Debian 11 (Bullseye)"
echo -e "    ${BOLD}5)${NC}  Debian 12 (Bookworm)"
echo -e ""
echo -e "  ${CYAN}Fedora:${NC}"
echo -e "    ${BOLD}6)${NC}  Fedora 40"
echo -e "    ${BOLD}7)${NC}  Fedora 41"
echo -e ""
echo -e "  ${CYAN}Other:${NC}"
echo -e "    ${BOLD}8)${NC}  Custom image (provide path or URL)"
echo

prompt OS_CHOICE "Select OS (1-8)" "1"

# OS_FAMILY is used later for Docker install method (apt vs dnf)
case "$OS_CHOICE" in
    1)
        OS_NAME="Ubuntu 22.04 LTS (Jammy)"
        OS_FAMILY="ubuntu"
        CLOUD_IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
        CLOUD_IMG_FILE="jammy-server-cloudimg-amd64.img"
        DEFAULT_USER="ubuntu"
        ;;
    2)
        OS_NAME="Ubuntu 24.04 LTS (Noble)"
        OS_FAMILY="ubuntu"
        CLOUD_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
        CLOUD_IMG_FILE="noble-server-cloudimg-amd64.img"
        DEFAULT_USER="ubuntu"
        ;;
    3)
        OS_NAME="Ubuntu 24.10 (Oracular)"
        OS_FAMILY="ubuntu"
        CLOUD_IMG_URL="https://cloud-images.ubuntu.com/oracular/current/oracular-server-cloudimg-amd64.img"
        CLOUD_IMG_FILE="oracular-server-cloudimg-amd64.img"
        DEFAULT_USER="ubuntu"
        ;;
    4)
        OS_NAME="Debian 11 (Bullseye)"
        OS_FAMILY="debian"
        CLOUD_IMG_URL="https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2"
        CLOUD_IMG_FILE="debian-11-genericcloud-amd64.qcow2"
        DEFAULT_USER="debian"
        ;;
    5)
        OS_NAME="Debian 12 (Bookworm)"
        OS_FAMILY="debian"
        CLOUD_IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
        CLOUD_IMG_FILE="debian-12-genericcloud-amd64.qcow2"
        DEFAULT_USER="debian"
        ;;
    6)
        OS_NAME="Fedora 40"
        OS_FAMILY="fedora"
        CLOUD_IMG_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-40-1.14.x86_64.qcow2"
        CLOUD_IMG_FILE="Fedora-Cloud-Base-Generic-40-1.14.x86_64.qcow2"
        DEFAULT_USER="fedora"
        ;;
    7)
        OS_NAME="Fedora 41"
        OS_FAMILY="fedora"
        CLOUD_IMG_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
        CLOUD_IMG_FILE="Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
        DEFAULT_USER="fedora"
        ;;
    8)
        OS_NAME="Custom"
        OS_FAMILY="custom"
        DEFAULT_USER="root"
        echo
        echo -e "  ${CYAN}1)${NC} apt-based (Ubuntu/Debian)"
        echo -e "  ${CYAN}2)${NC} dnf-based (Fedora/RHEL)"
        prompt CUSTOM_PKG_MGR "Package manager type (1 or 2)" "1"
        if [[ "$CUSTOM_PKG_MGR" == "2" ]]; then
            OS_FAMILY="fedora"
        else
            OS_FAMILY="debian"
        fi
        ;;
    *)
        error "Invalid selection: ${OS_CHOICE}"
        ;;
esac

success "Selected: ${OS_NAME}"

echo -e "\n${BOLD}── Cloud Image ──${NC}\n"

if [[ "$OS_CHOICE" == "8" ]]; then
    prompt CUSTOM_IMG "Path to .img/.qcow2 file or download URL" ""
    if [[ "$CUSTOM_IMG" =~ ^https?:// ]]; then
        CLOUD_IMG_URL="$CUSTOM_IMG"
        CLOUD_IMG_FILE=$(basename "$CUSTOM_IMG")
    elif [[ -f "$CUSTOM_IMG" ]]; then
        CLOUD_IMG_PATH="$CUSTOM_IMG"
        CLOUD_IMG_FILE=$(basename "$CUSTOM_IMG")
    else
        error "File not found and not a URL: ${CUSTOM_IMG}"
    fi
fi

CLOUD_IMG_PATH="${CLOUD_IMG_PATH:-/var/lib/vz/template/iso/${CLOUD_IMG_FILE}}"

if [[ -f "$CLOUD_IMG_PATH" ]]; then
    success "Cloud image already downloaded: ${CLOUD_IMG_PATH}"
else
    info "${OS_NAME} cloud image not found locally."
    if confirm "Download ${OS_NAME} cloud image now?"; then
        mkdir -p "$(dirname "$CLOUD_IMG_PATH")"
        info "Downloading from ${CLOUD_IMG_URL} ..."
        wget -q --show-progress -O "$CLOUD_IMG_PATH" "$CLOUD_IMG_URL" \
            || error "Failed to download cloud image."
        success "Cloud image downloaded."
    else
        prompt CLOUD_IMG_PATH "Enter path to existing .img/.qcow2 file" ""
        [[ -f "$CLOUD_IMG_PATH" ]] || error "File not found: ${CLOUD_IMG_PATH}"
    fi
fi

# ──────────────────────────────────────────────
# Additional options
# ──────────────────────────────────────────────
echo -e "\n${BOLD}── Additional Options ──${NC}\n"

if confirm "Enable QEMU Guest Agent in VM config?"; then
    AGENT=1
else
    AGENT=0
fi

if confirm "Start VM after creation?"; then
    START_VM=true
else
    START_VM=false
fi

# ──────────────────────────────────────────────
# Summary & confirmation
# ──────────────────────────────────────────────
echo -e "\n${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║               Configuration Summary              ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════╣${NC}"
printf "${BOLD}║${NC} %-18s │ %-28s ${BOLD}║${NC}\n" "OS"           "$OS_NAME"
printf "${BOLD}║${NC} %-18s │ %-28s ${BOLD}║${NC}\n" "VM ID"        "$VMID"
printf "${BOLD}║${NC} %-18s │ %-28s ${BOLD}║${NC}\n" "Hostname"     "$VM_NAME"
printf "${BOLD}║${NC} %-18s │ %-28s ${BOLD}║${NC}\n" "CPU Cores"    "$CPU_CORES"
printf "${BOLD}║${NC} %-18s │ %-28s ${BOLD}║${NC}\n" "RAM"          "${RAM_MB} MB"
printf "${BOLD}║${NC} %-18s │ %-28s ${BOLD}║${NC}\n" "Disk"         "$DISK_SIZE"
printf "${BOLD}║${NC} %-18s │ %-28s ${BOLD}║${NC}\n" "Storage"      "${STORAGE} (${STORAGE_TYPE})"
printf "${BOLD}║${NC} %-18s │ %-28s ${BOLD}║${NC}\n" "Network"      "${BRIDGE}"
printf "${BOLD}║${NC} %-18s │ %-28s ${BOLD}║${NC}\n" "IP Config"    "$IP_CONFIG"
[[ -n "$VLAN_TAG" ]] && \
printf "${BOLD}║${NC} %-18s │ %-28s ${BOLD}║${NC}\n" "VLAN"         "$VLAN_TAG"
[[ -n "$DNS_SERVERS" ]] && \
printf "${BOLD}║${NC} %-18s │ %-28s ${BOLD}║${NC}\n" "DNS"          "$DNS_SERVERS"
printf "${BOLD}║${NC} %-18s │ %-28s ${BOLD}║${NC}\n" "User"         "$CI_USER"
printf "${BOLD}║${NC} %-18s │ %-28s ${BOLD}║${NC}\n" "SSH Key"      "${SSH_KEYS_FILE:-none}"
printf "${BOLD}║${NC} %-18s │ %-28s ${BOLD}║${NC}\n" "Guest Agent"  "$( [[ $AGENT -eq 1 ]] && echo Yes || echo No )"
printf "${BOLD}║${NC} %-18s │ %-28s ${BOLD}║${NC}\n" "Docker"       "$( $INSTALL_DOCKER && echo Yes || echo No )"
printf "${BOLD}║${NC} %-18s │ %-28s ${BOLD}║${NC}\n" "QEMU Agent"   "$( $INSTALL_AGENT && echo Yes || echo No )"
printf "${BOLD}║${NC} %-18s │ %-28s ${BOLD}║${NC}\n" "Auto-start"   "$( $START_VM && echo Yes || echo No )"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"

echo
if ! confirm "Proceed with VM creation?"; then
    warn "Aborted by user."
    exit 0
fi

# ──────────────────────────────────────────────
# Build cloud-init vendor/user data (snippets)
# ──────────────────────────────────────────────
echo -e "\n${BOLD}── Preparing Cloud-Init Snippets ──${NC}\n"

# Find a storage that supports 'snippets' content type from storage.cfg
SNIPPET_STORAGE=""
SNIP_NAME=""
while IFS= read -r line; do
    if [[ "$line" =~ ^([a-zA-Z]+):\ +(.+)$ ]]; then
        SNIP_NAME="${BASH_REMATCH[2]}"
        continue
    fi
    if [[ -n "$SNIP_NAME" && "$line" =~ ^[[:space:]]+content[[:space:]]+(.*) ]]; then
        if echo "${BASH_REMATCH[1]}" | grep -q "snippets"; then
            SNIPPET_STORAGE="$SNIP_NAME"
            break
        fi
        SNIP_NAME=""
    fi
done < /etc/pve/storage.cfg

if [[ -z "$SNIPPET_STORAGE" ]]; then
    warn "No storage with 'snippets' content type found."
    warn "Enabling snippets on 'local' storage ..."
    pvesm set local --content iso,vztmpl,snippets 2>/dev/null || true
    SNIPPET_STORAGE="local"
fi

# Resolve the filesystem path for the snippets directory
SNIPPET_PATH=$(pvesm path "${SNIPPET_STORAGE}:snippets/" 2>/dev/null | sed 's|/$||' || echo "/var/lib/vz/snippets")
# Fallback: common default
if [[ ! -d "$SNIPPET_PATH" ]]; then
    SNIPPET_PATH="/var/lib/vz/snippets"
fi
mkdir -p "$SNIPPET_PATH"

VENDOR_FILE="${SNIPPET_PATH}/vm-${VMID}-vendor.yaml"

# Build the cloud-init config
cat > "$VENDOR_FILE" <<'VENDOREOF'
#cloud-config
package_update: true
package_upgrade: true
VENDOREOF

# Enable password SSH auth if a password was set
if [[ -n "$CI_PASS" ]]; then
    cat >> "$VENDOR_FILE" <<'PWEOF'

# Enable SSH password authentication
ssh_pwauth: true
chpasswd:
  expire: false
PWEOF
fi

cat >> "$VENDOR_FILE" <<'PKGEOF'

packages:
PKGEOF

# Conditionally add packages
if $INSTALL_AGENT; then
    echo "  - qemu-guest-agent" >> "$VENDOR_FILE"
fi

if $INSTALL_DOCKER; then
    if [[ "$OS_FAMILY" == "fedora" ]]; then
        cat >> "$VENDOR_FILE" <<'DOCKEREOF'
  - ca-certificates
  - curl
  - dnf-plugins-core

runcmd:
  # Install Docker from official repository (dnf)
  - dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
  - dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  - systemctl enable --now docker
DOCKEREOF
    else
        # apt-based (Ubuntu / Debian)
        cat >> "$VENDOR_FILE" <<'DOCKEREOF'
  - ca-certificates
  - curl
  - gnupg

runcmd:
  # Install Docker from official repository (apt)
  - install -m 0755 -d /etc/apt/keyrings
  - |
    . /etc/os-release
    DOCKER_DIST="$ID"
    curl -fsSL "https://download.docker.com/linux/${DOCKER_DIST}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_DIST} $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list
  - apt-get update -y
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  - systemctl enable --now docker
DOCKEREOF
    fi
else
    # If no docker, still need runcmd for agent
    echo "" >> "$VENDOR_FILE"
    echo "runcmd:" >> "$VENDOR_FILE"
fi

if $INSTALL_AGENT; then
    cat >> "$VENDOR_FILE" <<'AGENTEOF'
  # Enable qemu-guest-agent
  - systemctl enable --now qemu-guest-agent
AGENTEOF
fi

# Add user to docker group if docker is installed
if $INSTALL_DOCKER; then
    cat >> "$VENDOR_FILE" <<USEREOF
  # Add cloud-init user to docker group
  - usermod -aG docker ${CI_USER}
USEREOF
fi

# Final reboot to ensure guest agent is picked up
cat >> "$VENDOR_FILE" <<'REBOOTEOF'

power_state:
  mode: reboot
  message: "Cloud-init provisioning complete. Rebooting..."
  timeout: 30
  condition: true
REBOOTEOF

success "Cloud-init vendor config written to ${VENDOR_FILE}"

# ──────────────────────────────────────────────
# Create the VM
# ──────────────────────────────────────────────
echo -e "\n${BOLD}── Creating VM ──${NC}\n"

NET0="virtio,bridge=${BRIDGE}"
[[ -n "$VLAN_TAG" ]] && NET0+=",tag=${VLAN_TAG}"

info "Creating VM ${VMID} ..."
qm create "$VMID" \
    --name "$VM_NAME" \
    --ostype l26 \
    --cores "$CPU_CORES" \
    --memory "$RAM_MB" \
    --net0 "$NET0" \
    --scsihw virtio-scsi-single \
    --agent "$AGENT" \
    --serial0 socket \
    --vga serial0

success "VM shell created."

# Import disk
info "Importing cloud image disk to ${STORAGE} ..."
qm set "$VMID" --scsi0 "${STORAGE}:0,import-from=${CLOUD_IMG_PATH},iothread=1,discard=on"
success "Disk imported."

# Resize disk
if [[ "$DISK_SIZE" != "0" ]]; then
    info "Resizing disk to ${DISK_SIZE} ..."
    qm disk resize "$VMID" scsi0 "$DISK_SIZE"
    success "Disk resized."
fi

# Add cloud-init drive
info "Adding cloud-init drive ..."
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
success "Cloud-init drive added."

# Set boot order
qm set "$VMID" --boot order=scsi0

# ──────────────────────────────────────────────
# Configure cloud-init
# ──────────────────────────────────────────────
info "Configuring cloud-init ..."

qm set "$VMID" --ciuser "$CI_USER"

if [[ -n "$CI_PASS" ]]; then
    qm set "$VMID" --cipassword "$CI_PASS"
fi

if [[ -n "$SSH_KEYS_FILE" ]]; then
    qm set "$VMID" --sshkeys "$SSH_KEYS_FILE"
fi

qm set "$VMID" --ipconfig0 "$IP_CONFIG"

if [[ -n "$DNS_SERVERS" ]]; then
    qm set "$VMID" --nameserver "${DNS_SERVERS//,/ }"
fi

if [[ -n "$DNS_DOMAIN" ]]; then
    qm set "$VMID" --searchdomain "$DNS_DOMAIN"
fi

# Attach the vendor cloud-init snippet
qm set "$VMID" --cicustom "vendor=${SNIPPET_STORAGE}:snippets/vm-${VMID}-vendor.yaml"

success "Cloud-init configured."

# Regenerate cloud-init image
qm cloudinit update "$VMID" 2>/dev/null || true

# ──────────────────────────────────────────────
# Start VM (optional)
# ──────────────────────────────────────────────
if $START_VM; then
    info "Starting VM ${VMID} ..."
    qm start "$VMID"
    success "VM ${VMID} started."
    echo
    info "The VM will reboot once after first boot to complete provisioning."
    info "Docker and guest agent will be available after the reboot (~2-3 min)."
fi

echo -e "\n${GREEN}${BOLD}VM ${VMID} (${VM_NAME}) created successfully!${NC}\n"

if [[ "$IP_MODE" == "2" ]]; then
    IP_DISPLAY="${VM_IP%%/*}"
    echo -e "  Connect:  ${CYAN}ssh ${CI_USER}@${IP_DISPLAY}${NC}"
fi

echo -e "  Console:  ${CYAN}qm terminal ${VMID}${NC}"
echo -e "  Status:   ${CYAN}qm status ${VMID}${NC}"
if $INSTALL_DOCKER; then
    echo -e "  Docker:   ${CYAN}docker compose version${NC}  (after first-boot reboot)"
fi
echo
