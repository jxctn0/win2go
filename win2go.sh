#!/bin/bash
set -e

# =======================
# Win2Go USB Creator
# =======================

# Colors
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
RESET="\033[0m"

# Globals
ISO_FILE=""
DRIVE=""
DRIVERS=""
USERNAME="$USER"
AUTO_YES=false
VERBOSE=false

# =======================
# Helper functions
# =======================

check_dependencies() {
    local deps=("parted" "mkfs.vfat" "mkfs.ntfs" "wimlib-imagex" "lsblk" "wget")
    local missing=()

    for tool in "${deps[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing+=("$tool")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Error: Missing required tools: ${missing[*]}${RESET}"
        echo "Debian/Ubuntu: wimtools, parted, dosfstools, ntfs-3g"
        echo "Fedora: wimlib-utils, parted, dosfstools, ntfs-3g"
        echo "Arch Linux/Manjaro: wimlib, parted, dosfstools, ntfs-3g"
        echo "macOS (using Homebrew / Atomic): wimlib, parted, dosfstools, ntfs-3g, wget"
        echo "For Atomic systems (Linux containerized), ensure /dev access is allowed for USB"
        exit 1
    fi
}

clear_step() {
    clear
    echo -e "${CYAN}=== $1 ===${RESET}"
}

run_with_spinner() {
    local cmd="$*"
    local spin=('◐' '◓' '◑' '◒')
    local i=0
    local start_time=$(date +%s)

    bash -c "$cmd" &
    local pid=$!

    while kill -0 $pid 2>/dev/null; do
        local now=$(date +%s)
        local elapsed=$((now - start_time))
        local h=$((elapsed/3600))
        local m=$(((elapsed%3600)/60))
        local s=$((elapsed%60))
        printf "\r${CYAN}%s... %s [Elapsed: %02d:%02d:%02d]${RESET}" "$cmd" "${spin[$i]}" "$h" "$m" "$s" >&2
        i=$(( (i+1) %4 ))
        sleep 0.2
    done

    wait $pid
    local total=$(( $(date +%s) - start_time ))
    local h=$((total/3600))
    local m=$(((total%3600)/60))
    local s=$((total%60))
    printf "\r${GREEN}%s completed ✅ [Total: %02d:%02d:%02d]${RESET}\n" "$cmd" "$h" "$m" "$s" >&2
}

# Ctrl+C and error/exit handler
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${RESET}"
    sudo umount /mnt/win 2>/dev/null || true
    sudo umount /mnt/boot 2>/dev/null || true
    sudo umount /mnt/iso 2>/dev/null || true
    rm -rf "$TEMP_WIN" "$TEMP_BOOT"
    if [[ -n "$DOWNLOADED_ISO" ]]; then
        read -p "Delete downloaded ISO? (y/N): " deliso
        [[ "$deliso" =~ ^[Yy](es)?$ ]] && rm -f "$DOWNLOADED_ISO"
    fi
}
trap cleanup EXIT
trap cleanup ERR
trap cleanup INT

# =======================
# Parse CLI arguments
# =======================
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --iso|-i) ISO_FILE="$2"; shift ;;
        --drive|-d) DRIVE="$2"; shift ;;
        --drivers|-r) DRIVERS="$2"; shift ;;
        --user|-u) USERNAME="$2"; shift ;;
        -y) AUTO_YES=true ;;
        -v) VERBOSE=true ;;
        *) echo -e "${YELLOW}Unknown parameter passed: $1${RESET}" ;;
    esac
    shift
done

# =======================
# Step 0: Dependency check
# =======================

check_dependencies

# =======================
# Step 1: ISO Selection
# =======================
clear_step "Step 1: Select Windows ISO"

ISOS=()
for f in ./ ~/Downloads; do
    MATCHES=$(find "$f" -maxdepth 1 -type f \( -iname "*win*.iso" -o -iname "*tiny10*.iso" -o -iname "*win10*.iso" -o -iname "*win11*.iso" \) 2>/dev/null || true)
    if [[ -n "$MATCHES" ]]; then
        ISOS+=($MATCHES)
    fi 
done

echo "Available ISOs:"
for i in "${!ISOS[@]}"; do
    echo "$((i+1))) ${ISOS[$i]}"
done
echo "$(( ${#ISOS[@]} + 1 ))) Download ISO"

if [[ -z "$ISO_FILE" ]]; then
    read -p "#? " iso_choice
    if [[ "$iso_choice" -eq $(( ${#ISOS[@]} + 1 )) ]]; then
        echo "1) Official ISO"
        echo "2) Tiny10 ISO"
        read -p "Choice: " dlchoice
        if [[ "$dlchoice" -eq 1 ]]; then
            read -p "Enter ISO URL: " ISO_FILE
        else
            ISO_FILE="https://archive.org/download/tiny-10-23-h2/tiny10%20x64%2023h2.iso"
        fi
    else
        ISO_FILE="${ISOS[$((iso_choice-1))]}"
    fi
fi

# Download ISO if URL
if [[ "$ISO_FILE" =~ ^https?:// ]]; then
    DOWNLOADED_ISO="./$(basename "$ISO_FILE")"
    ISO_FILE="$DOWNLOADED_ISO"
    echo "Downloading ISO..."
    run_with_spinner "wget -O \"$ISO_FILE\" \"$ISO_FILE\""
fi
echo -e "${GREEN}Selected ISO: $ISO_FILE${RESET}"

# =======================
# Step 2: USB Drive Selection
# =======================
clear_step "Step 2: Select USB drive"

IFS=$'\n' DRIVES=($(lsblk -dpno NAME,SIZE,MODEL | grep -v "loop\|sr0"))
for i in "${!DRIVES[@]}"; do
    echo "$((i+1))) ${DRIVES[$i]}"
done

if ! $AUTO_YES || [[ -z "$DRIVE" ]]; then
    read -p "Select the drive number to use: " drv_choice
    DRIVE=$(echo "${DRIVES[$((drv_choice-1))]}" | awk '{print $1}')
fi

# Warn large drives
SIZE_GB=$(lsblk -dn -b -o SIZE "$DRIVE")
SIZE_GB=$((SIZE_GB / 1024 / 1024 / 1024))
if [[ $SIZE_GB -gt 64 ]]; then
    read -p "⚠️ WARNING: $DRIVE is larger than 64GB. Type YES to continue: " yn
    [[ "$yn" != "YES" ]] && exit 1
fi

# Unmount partitions
MOUNTED=$(lsblk -ln -o MOUNTPOINT "$DRIVE" | grep -v "^$" || true)
if [[ -n "$MOUNTED" ]]; then
    echo "⚠️ $DRIVE is mounted, forcing unmount..."
    sudo umount -l "${DRIVE}"* 2>/dev/null || true
fi

sudo udevadm settle

read -p "⚠️ This will ERASE all data on $DRIVE. Continue? (y/N): " yn
[[ ! "$yn" =~ ^[Yy](es)?$ ]] && exit 1

# =======================
# Step 3: Partitioning & Formatting
# =======================
clear_step "Step 3: Partitioning $DRIVE"
run_with_spinner "sudo parted $DRIVE --script mklabel gpt"
run_with_spinner "sudo parted $DRIVE --script mkpart EFI fat32 1MiB 513MiB"
run_with_spinner "sudo parted $DRIVE --script set 1 esp on"
run_with_spinner "sudo parted $DRIVE --script mkpart WIN ntfs 513MiB 100%"

# Wait for the OS to see the new partition table before formatting
echo "Settling partition table..."
sudo udevadm settle
sleep 2

echo "Unmount drive and kill processes accessing it..."
sudo umount -l "${DRIVE}"* 2>/dev/null || true
sudo fuser -kvm "$DRIVE" >/dev/null 2>&1 || true
sudo umount -l "${DRIVE}"* 2>/dev/null || true

echo "Settling partition table... again..."
sudo udevadm settle
sleep 2

# Logic to support non-USB block devices
PART1="${DRIVE}1"
PART2="${DRIVE}2"

if [ ! -b "$PART1" ]; then
    PART1="${DRIVE}p1"
    PART2="${DRIVE}p2"
fi

run_with_spinner "sudo mkfs.vfat -F32 $PART1"
run_with_spinner "sudo mkfs.ntfs -f $PART2"

# Mount partitions
sudo mkdir -p /mnt/win /mnt/boot /mnt/iso
sudo mount "$PART2" /mnt/win
sudo mount "$PART1" /mnt/boot
sudo mount -t iso9660,udf -o loop,ro "$ISO_FILE" /mnt/iso

# =======================
# Step 4: Extract WIM to temp
# =======================
clear_step "Step 4: Extract Windows image to temp folder"
TEMP_WIN=$(mktemp -d)
TEMP_BOOT=$(mktemp -d)

IMAGE_INDEX=1  # Default index, could add multi-index selection

# Check if it's .wim or .esd
if [ -f /mnt/iso/sources/install.wim ]; then
    WIM_PATH="/mnt/iso/sources/install.wim"
else
    WIM_PATH="/mnt/iso/sources/install.esd"
fi

run_with_spinner "sudo wimlib-imagex apply $WIM_PATH $IMAGE_INDEX $TEMP_WIN --no-acls --no-attributes --include-invalid-names"

# Copy EFI/boot to temp
[[ -d "$TEMP_WIN/EFI" ]] && cp -r "$TEMP_WIN/EFI" "$TEMP_BOOT/"
[[ -d "$TEMP_WIN/boot" ]] && cp -r "$TEMP_WIN/boot" "$TEMP_BOOT/"

# =======================
# Step 5: Copy to USB
# =======================
clear_step "Step 5: Copying Windows files to USB"
run_with_spinner "sudo rsync -ah --info=progress2 $TEMP_WIN/ /mnt/win/"
run_with_spinner "sudo rsync -ah --info=progress2 $TEMP_BOOT/ /mnt/boot/"

# =======================
# Step 6: Driver Installation
# =======================
if [[ -n "$DRIVERS" && -d "$DRIVERS" ]]; then
    clear_step "Step 6: Installing drivers for first boot"
    sudo cp -r "$DRIVERS"/* /mnt/win/Drivers/
    echo "SetupComplete.cmd" > /mnt/win/Windows/Setup/Scripts/SetupComplete.cmd
fi

# =======================
# Step 7: OOBE Skip & User Creation
# =======================
clear_step "Step 7: Auto user creation & OOBE skip"
AUTO_USER="$USERNAME"
# Here, implement autounattend.xml or registry modifications if needed

# =======================
# Step 8: Cleanup
# =======================
clear_step "Step 8: Cleanup & unmount"
sudo umount /mnt/win
sudo umount /mnt/boot
sudo umount /mnt/iso
rm -rf "$TEMP_WIN" "$TEMP_BOOT"

echo -e "${GREEN}Windows To Go USB successfully created!${RESET}"
