#!/usr/bin/env bash
# Win2Go USB Creator for Linux with colors, formatting, driver installation, OOBE skip, Windows 11 bypass
# Save as win2go.sh, make executable (chmod +x win2go.sh)
# WARNING: This will erase the selected target drive.

set -euo pipefail

# Color escape codes
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

# Defaults / variables
ISO=""
USB_DEVICE=""
AUTO_RUN="false"
VERBOSE="false"
DRIVER_PATH=""
USERNAME="${USER:-user}"
DOWNLOADED_ISO=""

# cleanup on ctrl+c (SIGINT)
cleanup_on_interrupt() {
    echo -e "\n${YELLOW}⚠️ Interrupt detected — cleaning up...${RESET}"
    sudo umount /mnt/iso /mnt/win /mnt/boot 2>/dev/null || true
    if [[ -n "$DOWNLOADED_ISO" && -f "$DOWNLOADED_ISO" ]]; then
        read -p "Delete downloaded ISO $DOWNLOADED_ISO? (yes/no): " _del
        if [[ "$_del" == "yes" ]]; then
            rm -f "$DOWNLOADED_ISO" && echo -e "${GREEN}Deleted $DOWNLOADED_ISO${RESET}"
        fi
    fi
    echo -e "${GREEN}Cleanup complete. Exiting.${RESET}"
    exit 1
}
trap cleanup_on_interrupt SIGINT

# parse CLI args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso|-i)
            ISO="$2"; shift 2;;
        --drive|-d)
            USB_DEVICE="$2"; shift 2;;
        --drivers|-r)
            DRIVER_PATH="$2"; shift 2;;
        --user|-u)
            USERNAME="$2"; shift 2;;
        -y)
            AUTO_RUN="true"; shift 1;;
        -v)
            VERBOSE="true"; shift 1;;
        *)
            echo -e "${RED}Unknown argument: $1${RESET}"; exit 1;;
    esac
done

PROMPT="true"
[[ "$AUTO_RUN" == "true" && -n "$ISO" && -n "$USB_DEVICE" ]] && PROMPT="false"

# dependency check
for cmd in wimlib-imagex parted mkfs.vfat mkfs.ntfs lsblk fdisk tar wget; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${RED}Missing dependency: $cmd. Please install it and re-run.${RESET}"; exit 1
    fi
done

# helper to clear and show step title
clear_step() {
    clear
    printf "%b\n" "${BOLD}${CYAN}=== $1 ===${RESET}"
}

# --- Step 0: ISO selection / download ---
clear_step "Step 0: Windows ISO Selection"

if [[ -n "$ISO" ]]; then
    if [[ "$ISO" =~ ^https?:// ]]; then
        ISO_FILENAME="./$(basename "$ISO")"
        if [[ ! -f "$ISO_FILENAME" ]]; then
            echo -e "${CYAN}Downloading ISO from: $ISO${RESET}"
            wget -O "$ISO_FILENAME" "$ISO"
            DOWNLOADED_ISO="$ISO_FILENAME"
        fi
        ISO="$ISO_FILENAME"
    else
        if [[ ! -f "$ISO" ]]; then
            echo -e "${RED}Specified ISO not found: $ISO${RESET}"; exit 1
        fi
    fi
    echo -e "${GREEN}Using ISO: $ISO${RESET}"
else
    # Search current directory and ~/Downloads
    ISOS=()
    while IFS= read -r -d '' f; do ISOS+=("$f"); done < <(find . ~/Downloads -maxdepth 1 -type f \( -iname '*win*10*.iso' -o -iname '*win*11*.iso' -o -iname '*tiny10*.iso' -o -iname '*tiny11*.iso' \) -print0 2>/dev/null || true)

    PS3=$'\n''Select an ISO or choose Download ISO: '
    options=("${ISOS[@]}" "Download ISO" "Cancel")
    select opt in "${options[@]}"; do
        if [[ "$opt" == "Download ISO" ]]; then
            echo -e "${CYAN}Download options:${RESET}"
            echo "1) Official Microsoft ISO (enter a direct download URL)"
            echo "2) Tiny10 23H2 x64 (archive.org)"
            read -p "Choice [1/2]: " dlc
            case "$dlc" in
                1)
                    read -p "Enter ISO URL: " url
                    ISO_FILENAME="./$(basename "$url")"
                    wget -O "$ISO_FILENAME" "$url"
                    ISO="$ISO_FILENAME"
                    DOWNLOADED_ISO="$ISO_FILENAME"
                    ;;
                2)
                    ISO="tiny10_23h2.iso"
                    if [[ ! -f "$ISO" ]]; then
                        wget -O "$ISO" "https://archive.org/download/tiny-10-23-h2/tiny10%20x64%2023h2.iso"
                    fi
                    DOWNLOADED_ISO="$ISO"
                    ;;
                *) echo -e "${RED}Invalid choice${RESET}"; continue;;
            esac
            break
        elif [[ "$opt" == "Cancel" ]]; then
            echo -e "${YELLOW}Cancelled.${RESET}"; exit 0
        elif [[ -n "$opt" ]]; then
            ISO="$opt"
            break
        else
            echo "Invalid selection"; continue
        fi
    done
    echo -e "${GREEN}Selected ISO: $ISO${RESET}"
fi

# Step 0.5: verbose ISO info
if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${BLUE}ISO file info:${RESET}"
    ls -lh "$ISO"
    echo
fi

# --- Step 1: Drive selection ---
clear_step "Step 1: Select USB Drive"

if [[ -z "$USB_DEVICE" ]]; then
    # list block devices
    echo -e "${BLUE}Available block devices:${RESET}"
    mapfile -t DEVICES < <(lsblk -dn -o NAME,SIZE,MODEL | awk '{printf "%s|%s|%s\n",$1,$2,$3}')
    declare -A DRIVE_MAP
    idx=1
    for line in "${DEVICES[@]}"; do
        name=$(echo "$line" | cut -d'|' -f1)
        size=$(echo "$line" | cut -d'|' -f2)
        model=$(echo "$line" | cut -d'|' -f3)
        dev="/dev/$name"
        printf "%b\n" "${YELLOW}$idx)${RESET} ${BLUE}$dev${RESET} - $size - ${model}"
        DRIVE_MAP[$idx]="$dev"
        idx=$((idx+1))
    done
    read -p "Select drive number: " choice
    USB_DEVICE="${DRIVE_MAP[$choice]:-}"
    if [[ -z "$USB_DEVICE" ]]; then
        echo -e "${RED}Invalid selection${RESET}"; exit 1
    fi
fi

# sanity checks
if [[ ! -b "$USB_DEVICE" ]]; then
    echo -e "${RED}Invalid block device: $USB_DEVICE${RESET}"; exit 1
fi

# warn on large drives (>64GB)
size_bytes=$(lsblk -b -dn -o SIZE "$USB_DEVICE")
if (( size_bytes > 68719476736 )); then
    echo -e "${YELLOW}⚠️ $USB_DEVICE is larger than 64GB. Make sure this is the correct removable drive.${RESET}"
    if [[ "$PROMPT" == "true" ]]; then
        read -p "Type YES to continue: " mustyes
        if [[ "$mustyes" != "YES" ]]; then echo "Aborting."; exit 1; fi
    fi
fi

# Unmount any auto-mounted partitions from the device
if mount | grep -q "^$USB_DEVICE"; then
    echo -e "${YELLOW}Unmounting auto-mounted partitions from $USB_DEVICE...${RESET}"
    while read -r part; do
        sudo umount "/dev/$part" 2>/dev/null || true
    done < <(lsblk -ln -o NAME "$USB_DEVICE" | tail -n +2)
fi

if [[ "$PROMPT" == "true" ]]; then
    read -p "⚠️ This will ERASE all data on $USB_DEVICE. Continue? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then echo "Aborting."; exit 1; fi
fi

if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${BLUE}Device info:${RESET}"
    lsblk "$USB_DEVICE"
    echo
    sudo fdisk -l "$USB_DEVICE" || true
    echo
fi

# --- Step 2: Partition the USB ---
clear_step "Step 2: Partitioning USB ($USB_DEVICE)"

sudo parted "$USB_DEVICE" --script mklabel gpt
sudo parted "$USB_DEVICE" --script mkpart EFI fat32 1MiB 513MiB
sudo parted "$USB_DEVICE" --script set 1 esp on
sudo parted "$USB_DEVICE" --script mkpart WIN ntfs 513MiB 100%
sudo mkfs.vfat -F32 "${USB_DEVICE}1"
sudo mkfs.ntfs -f "${USB_DEVICE}2"

# --- Step 3: Mount ISO and target partitions ---
clear_step "Step 3: Mounting ISO & target partitions"

sudo mkdir -p /mnt/iso /mnt/win /mnt/boot

# If /mnt/iso already mounted (maybe user mounted manually), reuse; else mount loop ISO
if mount | grep -q " /mnt/iso "; then
    echo -e "${YELLOW}/mnt/iso already mounted, reusing.${RESET}"
else
    sudo mount -o loop "$ISO" /mnt/iso
fi

# Ensure any auto-mounted partitions of the USB are unmounted
while read -r part; do
    sudo umount "/dev/$part" 2>/dev/null || true
done < <(lsblk -ln -o NAME "$USB_DEVICE" | tail -n +2)

sudo mount "${USB_DEVICE}2" /mnt/win
sudo mount "${USB_DEVICE}1" /mnt/boot

# --- Step 4: Detect WIM/ESD and Windows version ---
clear_step "Step 4: Detecting WIM/ESD and Windows version"

if [[ -f /mnt/iso/sources/install.wim ]]; then
    IMAGE_FILE="/mnt/iso/sources/install.wim"
elif [[ -f /mnt/iso/sources/install.esd ]]; then
    IMAGE_FILE="/mnt/iso/sources/install.esd"
else
    echo -e "${RED}No install.wim or install.esd found in ISO (checked /mnt/iso/sources).${RESET}"
    cleanup_on_interrupt
fi

# Print WIM info in verbose
if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${BLUE}WIM/ESD info:${RESET}"
    wimlib-imagex info "$IMAGE_FILE"
fi

WIM_DISPLAY=$(wimlib-imagex info "$IMAGE_FILE" | awk -F: '/Display Name/ {print substr($0,index($0,$2)+1)}' | sed -n '1p' || true)
IS_WIN11="false"
if echo "$WIM_DISPLAY" | grep -qi "Windows 11"; then
    IS_WIN11="true"
fi

# Multi-index selection
INDEX_COUNT=$(wimlib-imagex info "$IMAGE_FILE" | grep -c '^Index:')
if (( INDEX_COUNT > 1 )); then
    echo -e "${BLUE}Multiple editions found in the image:${RESET}"
    wimlib-imagex info "$IMAGE_FILE" | awk '/^Index:/{print $0} /^Name:/{print "  "$0}' 
    if [[ "$PROMPT" == "true" ]]; then
        read -p "Enter index to apply (number): " IMAGE_INDEX
    else
        IMAGE_INDEX=1
    fi
else
    IMAGE_INDEX=1
fi
echo -e "${GREEN}Applying image index: $IMAGE_INDEX${RESET}"

# --- Step 5: Apply WIM/ESD ---
clear_step "Step 5: Applying Windows image (this will probably take a while)"

sudo wimlib-imagex apply "$IMAGE_FILE" "$IMAGE_INDEX" /mnt/win

# --- Step 6: Copy EFI and boot files ---
clear_step "Step 6: Copy EFI and boot files"

if [[ -d /mnt/win/EFI ]]; then
    sudo cp -r /mnt/win/EFI /mnt/boot/ || true
    echo -e "${GREEN}Copied EFI directory.${RESET}"
else
    echo -e "${YELLOW}⚠️ EFI directory not found in image — continuing.${RESET}"
fi

if [[ -d /mnt/win/boot ]]; then
    sudo cp -r /mnt/win/boot /mnt/boot/ || true
    echo -e "${GREEN}Copied boot directory.${RESET}"
else
    echo -e "${YELLOW}⚠️ boot directory not found in image — continuing.${RESET}"
fi

# --- Step 7: Prepare first-boot driver installation (if drivers provided) ---
if [[ -n "$DRIVER_PATH" ]]; then
    if [[ -d "$DRIVER_PATH" ]]; then
        clear_step "Step 7: Prepare first-boot drivers"
        echo -e "${CYAN}Copying drivers into image...${RESET}"
        sudo mkdir -p /mnt/win/Drivers
        sudo cp -r "$DRIVER_PATH"/* /mnt/win/Drivers/ || true
        sudo mkdir -p /mnt/win/Windows/Setup/Scripts
        sudo tee /mnt/win/Windows/Setup/Scripts/SetupComplete.cmd > /dev/null <<'EOF'
@echo off
echo Installing drivers...
for /r C:\Drivers %%i in (*.inf) do (
    pnputil /add-driver "%%i" /install
)
echo Drivers installed. Cleaning up...
rd /s /q C:\Drivers
EOF
        echo -e "${GREEN}Driver installer scheduled at SetupComplete.cmd${RESET}"
    else
        echo -e "${YELLOW}Driver path specified but not found: $DRIVER_PATH — skipping driver copy.${RESET}"
    fi
fi

# --- Step 8: Autounattend.xml for OOBE skip and user creation ---
clear_step "Step 8: Create Autounattend.xml (skip OOBE & create user)"

sudo mkdir -p /mnt/win/Windows/Panther
sudo tee /mnt/win/Windows/Panther/Autounattend.xml > /dev/null <<EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <AutoLogon>
        <Username>${USERNAME}</Username>
        <Password>
          <Value>Password123!</Value>
          <PlainText>true</PlainText>
        </Password>
        <Enabled>true</Enabled>
      </AutoLogon>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>Password123!</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>
</unattend>
EOF
echo -e "${GREEN}Autounattend.xml written (user: ${USERNAME}).${RESET}"

# --- Step 9: Windows 11 bypass (if detected) ---
if [[ "$IS_WIN11" == "true" ]]; then
    clear_step "Step 9: Windows 11 bypass configuration"
    echo -e "${YELLOW}Windows 11 detected. Adding LabConfig bypass keys to SetupComplete.cmd${RESET}"
    sudo mkdir -p /mnt/win/Windows/Setup/Scripts
    # Append bypass to SetupComplete.cmd (create if missing)
    sudo tee -a /mnt/win/Windows/Setup/Scripts/SetupComplete.cmd > /dev/null <<'EOF'
REM Windows 11 OOBE/hardware checks bypass
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f
EOF
    echo -e "${GREEN}Bypass keys added.${RESET}"
fi

# --- Step 10: Final sync, unmount, and safe power-off/eject ---
clear_step "Step 10: Finalizing & cleanup"

sync
sudo umount /mnt/iso /mnt/win /mnt/boot 2>/dev/null || true

# Try to power-off/eject the device if possible (best effort)
if command -v udisksctl >/dev/null 2>&1; then
    echo -e "${BLUE}Powering off the device with udisksctl...${RESET}"
    sudo udisksctl power-off -b "$USB_DEVICE" 2>/dev/null || true
elif command -v eject >/dev/null 2>&1; then
    echo -e "${BLUE}Ejecting device...${RESET}"
    sudo eject "$USB_DEVICE" 2>/dev/null || true
else
    echo -e "${YELLOW}Couldn't power-off/eject automatically; you can safely remove the device now.${RESET}"
fi

echo -e "${GREEN}${BOLD}✅ Windows To Go USB is ready on ${USB_DEVICE}${RESET}"

# Ask about deleting downloaded ISO if any
if [[ -n "$DOWNLOADED_ISO" && -f "$DOWNLOADED_ISO" ]]; then
    read -p "Do you want to delete the downloaded ISO $DOWNLOADED_ISO? (yes/no): " delq
    if [[ "$delq" == "yes" ]]; then
        rm -f "$DOWNLOADED_ISO" && echo -e "${GREEN}Deleted $DOWNLOADED_ISO${RESET}"
    else
        echo -e "${YELLOW}Kept $DOWNLOADED_ISO${RESET}"
    fi
fi

exit 0
