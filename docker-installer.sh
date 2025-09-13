#!/bin/bash
set -e

# helper functions 
info()    { echo -e "\033[1;34m[INFO]\033[0m $1"; }
success() { echo -e "\033[1;32m[✔]\033[0m $1"; }
warn()    { echo -e "\033[1;33m[⚠]\033[0m $1"; }
error()   { echo -e "\033[1;31m[✖]\033[0m $1"; }

# check dependencies and install if missing
for cmd in whiptail pvesh pct pveam jq curl; do
    if ! command -v $cmd &> /dev/null; then
        warn "$cmd not found, installing..."
        apt-get update && apt-get install -y whiptail jq curl
    fi
done

# banner
echo -e "\033[1;34m    ____             __              __   \033[0m"
echo -e "\033[1;34m   / __ \____  _____/ /_____  ____  / /   \033[0m"
echo -e "\033[1;34m  / / / / __ \/ ___/ //_/ _ \/ __ \/ /    \033[0m"
echo -e "\033[1;34m / /_/ / /_/ / /__/ ,< /  __/ / / / /     \033[0m"
echo -e "\033[1;34m/_____/\____/\___/_/|_|\___/_/ /_/_/      \033[0m"
echo -e "\033[1;36m  ___          __        __                \033[0m"
echo -e "\033[1;36m / _ \___ ___ / /  ___  / /__  ___         \033[0m"
echo -e "\033[1;36m/ , _/ -_|_-</ /__/ _ \/ / _ \/ -_)        \033[0m"
echo -e "\033[1;36m/_/|_|\__/___/____/\___/_/\___/\__/         \033[0m"
echo -e "\033[1;32m========================================\033[0m"
echo -e "\033[1;32m      Docker + Portainer LXC Setup     \033[0m"
echo -e "\033[1;32m========================================\033[0m"
echo -e "\033[1;32m            Created by: \033[1;33mCaleb Kibet\033[0m"
echo ""


# select template storage
TEMPLATE_STORAGES=($(pvesh get /nodes/localhost/storage --output-format=json \
  | jq -r '.[] | select(.content | test("vztmpl")) | .storage'))
if [ ${#TEMPLATE_STORAGES[@]} -eq 0 ]; then
    error "No storage supports LXC templates."
    exit 1
fi
OPTIONS=()
for s in "${TEMPLATE_STORAGES[@]}"; do OPTIONS+=("$s" "" OFF); done
TEMPLATE_STORAGE=$(whiptail --title "Select Template Storage" \
  --radiolist "Choose storage for LXC template:" 15 60 5 "${OPTIONS[@]}" 3>&1 1>&2 2>&3)

# select container storage
CT_STORAGES=($(pvesh get /nodes/localhost/storage --output-format=json \
  | jq -r '.[] | select(.content | test("rootdir")) | .storage'))
if [ ${#CT_STORAGES[@]} -eq 0 ]; then
    error "No storage supports container rootfs."
    exit 1
fi
OPTIONS=()
for s in "${CT_STORAGES[@]}"; do OPTIONS+=("$s" "" OFF); done
CT_STORAGE=$(whiptail --title "Select Container Storage" \
  --radiolist "Choose storage for LXC rootfs:" 15 60 5 "${OPTIONS[@]}" 3>&1 1>&2 2>&3)

# gather input with defaults
DEFAULT_VMID=$(pvesh get /cluster/nextid)
VMID=$(whiptail --inputbox "Enter VMID" 8 60 "$DEFAULT_VMID" 3>&1 1>&2 2>&3)
DEFAULT_HOSTNAME="docker-lxc"
HOSTNAME=$(whiptail --inputbox "Enter Hostname" 8 60 "$DEFAULT_HOSTNAME" 3>&1 1>&2 2>&3)
PASSWORD=$(whiptail --passwordbox "Enter Root Password" 8 60 3>&1 1>&2 2>&3)
MEMORY=$(whiptail --inputbox "Enter Memory (MB)" 8 60 2048 3>&1 1>&2 2>&3)
CORES=$(whiptail --inputbox "Enter CPU Cores" 8 60 $(nproc) 3>&1 1>&2 2>&3)

# disk
DISK="10G"
DISK_NUMBER=10

# default IP and Gateway
DEFAULT_IP="10.0.0.$((100 + VMID))/24"
DEFAULT_GW=$(ip route show default | awk '/default/ {print $3}')
IP=$(whiptail --inputbox "Enter IP address (CIDR)" 8 60 "$DEFAULT_IP" 3>&1 1>&2 2>&3)
GW=$(whiptail --inputbox "Enter Gateway" 8 60 "$DEFAULT_GW" 3>&1 1>&2 2>&3)

# confirm settings
whiptail --title "Confirm Settings" --yesno "VMID: $VMID
Hostname: $HOSTNAME
Memory: $MEMORY MB
CPU: $CORES
Disk: $DISK
IP: $IP
Gateway: $GW
Continue?" 20 60 || exit 1

# download template if needed
TEMPLATE="debian-12-standard_12.12-1_amd64.tar.zst"
TEMPLATE_PATH="/var/lib/vz/template/cache/$TEMPLATE"
if [ ! -f "$TEMPLATE_PATH" ]; then
    info "Downloading Debian 12 template..."
    pveam update && pveam download $TEMPLATE_STORAGE $TEMPLATE
fi
success "Template ready."

# detect storage type for rootfs
STORAGE_TYPE=$(pvesh get /nodes/localhost/storage --output-format=json \
    | jq -r ".[] | select(.storage==\"$CT_STORAGE\") | .type")
if [ "$STORAGE_TYPE" = "lvmthin" ] || [ "$STORAGE_TYPE" = "lvm" ]; then
    ROOTFS_PARAM="$CT_STORAGE:$DISK_NUMBER"
elif [ "$STORAGE_TYPE" = "dir" ] || [ "$STORAGE_TYPE" = "nfs" ] || [ "$STORAGE_TYPE" = "cifs" ]; then
    ROOTFS_PARAM="$CT_STORAGE:$DISK"
elif [ "$STORAGE_TYPE" = "zfspool" ]; then
    ROOTFS_PARAM="$CT_STORAGE:size=$DISK"
else
    error "Unsupported storage type: $STORAGE_TYPE"; exit 1
fi

# create LXC container
info "Creating LXC container..."
pct create $VMID $TEMPLATE_PATH \
    --hostname $HOSTNAME \
    --rootfs $ROOTFS_PARAM \
    --memory $MEMORY \
    --cores $CORES \
    --net0 name=eth0,bridge=vmbr0,ip=$IP,gw=$GW \
    --password $PASSWORD \
    --features nesting=1 \
    --unprivileged 0
success "Container $VMID created."

# start container
pct start $VMID
success "Container started."

# install Docker & Portainer inside container
info "Installing Docker & Portainer..."
pct exec $VMID -- bash -c "
set -e
apt-get update && apt-get install -y curl apt-transport-https ca-certificates gnupg lsb-release
curl -fsSL https://get.docker.com | sh
docker volume create portainer_data
docker run -d -p 9443:9443 --name portainer --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest
"
success "Docker & Portainer installed and running!"

# final message
IP_NO_MASK=${IP%/*}
whiptail --msgbox "Docker + Portainer LXC created!\n\nVMID: $VMID\nHostname: $HOSTNAME\nIP: $IP_NO_MASK\n\nAccess Portainer at: https://$IP_NO_MASK:9443" 12 60
echo -e "\033[1;32m[✔] Docker + Portainer container setup complete.\033[0m"
echo -e "\033[1;34mAccess Portainer at: https://$IP_NO_MASK:9443\033[0m"
