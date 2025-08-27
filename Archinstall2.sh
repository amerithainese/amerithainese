#!/usr/bin/env bash
set -euo pipefail

# Easy-Arch (unencrypted BTRFS + snapshots) installer — improved version
# WARNING: This will DELETE the selected disk. Backup important data first.
# Logs: /tmp/easy-arch.log

LOGFILE="/tmp/easy-arch.log"
exec > >(tee -a "$LOGFILE") 2>&1

# Ensure root privileges and Arch ISO environment
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This installer must be run as root from an Arch ISO/live environment." >&2
  exit 1
fi
if [[ ! -f /etc/arch-release ]]; then
  echo "ERROR: This script must run from an Arch Linux ISO." >&2
  exit 1
fi

clear
BOLD='\e[1m'; BRED='\e[91m'; BBLUE='\e[34m'; BGREEN='\e[92m'; BYELLOW='\e[93m'; RESET='\e[0m'

info_print () { echo -e "${BOLD}${BGREEN}[ ${BYELLOW}•${BGREEN} ] $1${RESET}"; }
input_print () { echo -ne "${BOLD}${BYELLOW}[ ${BGREEN}•${BYELLOW} ] $1${RESET}"; }
error_print () { echo -e "${BOLD}${BRED}[ ${BBLUE}•${BRED} ] $1${RESET}"; }

# Helper to compute partition device (nvme -> p1, sd -> 1)
partdev() {
  local disk="$1"; local num="$2"
  if [[ "$disk" =~ [0-9]$ ]]; then
    printf "%sp%s" "$disk" "$num"
  else
    printf "%s%s" "$disk" "$num"
  fi
}

# Virtualization check
virt_check () {
    hypervisor=$(systemd-detect-virt || true)
    case $hypervisor in
        kvm )   info_print "KVM detected — installing qemu-guest-agent."; pacstrap /mnt qemu-guest-agent; systemctl enable qemu-guest-agent --root=/mnt ;;
        vmware ) info_print "VMware detected — installing open-vm-tools."; pacstrap /mnt open-vm-tools; systemctl enable vmtoolsd --root=/mnt ;;
        oracle ) info_print "VirtualBox detected — installing virtualbox-guest-utils."; pacstrap /mnt virtualbox-guest-utils; systemctl enable vboxservice --root=/mnt ;;
        microsoft ) info_print "Hyper-V detected — enabling hyperv services."; pacstrap /mnt hyperv; systemctl enable hv_fcopy_daemon --root=/mnt ;;
        * ) info_print "No common hypervisor detected.";;
    esac
}

# Kernel selector
kernel_selector () {
    info_print "List of kernels:"
    info_print "1) linux (stable)"
    info_print "2) linux-lts"
    info_print "3) linux-zen"
    info_print "4) linux-hardened"
    input_print "Select kernel (1-4): "
    read -r kernel_choice
    case $kernel_choice in
        1) kernel="linux";;
        2) kernel="linux-lts";;
        3) kernel="linux-zen";;
        4) kernel="linux-hardened";;
        *) error_print "Invalid kernel choice"; return 1;;
    esac
    return 0
}

# Network selector
network_selector () {
    info_print "Network utilities:"
    info_print "1) iwd"
    info_print "2) NetworkManager"
    info_print "3) wpa_supplicant + dhcpcd"
    info_print "4) dhcpcd only"
    info_print "5) I'll do it manually"
    input_print "Choose (1-5): "
    read -r network_choice
    if ! [[ "$network_choice" =~ ^[1-5]$ ]]; then error_print "Invalid choice"; return 1; fi
    return 0
}

network_installer () {
  case $network_choice in
    1) info_print "Installing iwd..."; pacstrap /mnt iwd; systemctl enable iwd --root=/mnt ;;
    2) info_print "Installing NetworkManager..."; pacstrap /mnt networkmanager; systemctl enable NetworkManager --root=/mnt ;;
    3) info_print "Installing wpa_supplicant + dhcpcd..."; pacstrap /mnt wpa_supplicant dhcpcd; systemctl enable wpa_supplicant --root=/mnt; systemctl enable dhcpcd --root=/mnt ;;
    4) info_print "Installing dhcpcd..."; pacstrap /mnt dhcpcd; systemctl enable dhcpcd --root=/mnt ;;
    5) info_print "Skipping network installation (manual).";;
  esac
}

userpass_selector () {
  input_print "Enter username to create (leave empty to skip): "
  read -r username
  if [[ -z "${username:-}" ]]; then username=""; return 0; fi
  input_print "Enter password for $username: "
  read -r -s userpass; echo
  input_print "Confirm password: "
  read -r -s userpass2; echo
  if [[ "$userpass" != "$userpass2" || -z "$userpass" ]]; then error_print "Passwords don't match or empty"; return 1; fi
  return 0
}

rootpass_selector () {
  input_print "Enter root password: "
  read -r -s rootpass; echo
  input_print "Confirm root password: "
  read -r -s rootpass2; echo
  if [[ "$rootpass" != "$rootpass2" || -z "$rootpass" ]]; then error_print "Passwords don't match or empty"; return 1; fi
  return 0
}

microcode_detector () {
  CPU=$(grep -m1 vendor_id /proc/cpuinfo || true)
  if [[ "$CPU" == *"AuthenticAMD"* ]]; then microcode="amd-ucode"; else microcode="intel-ucode"; fi
  info_print "Microcode package chosen: $microcode"
}

hostname_selector () {
  input_print "Enter hostname: "
  read -r hostname
  if [[ -z "${hostname:-}" ]]; then error_print "Hostname required"; return 1; fi
  return 0
}

locale_selector () {
  input_print "Locale (e.g. en_US.UTF-8 — leave empty for en_US.UTF-8, or '/' to browse): "
  read -r locale
  case "$locale" in
    '') locale="en_US.UTF-8"; info_print "Using $locale"; return 0;;
    '/') less -S /etc/locale.gen; clear; return 1;;
    *) if [[ "$locale" =~ ^[a-z]{2,3}_[A-Z]{2}\.(UTF-8|utf8)$ ]] && grep -q "^#\?$locale " /etc/locale.gen; then info_print "Using $locale"; return 0; else error_print "Invalid or not found locale"; return 1; fi;;
  esac
}

keyboard_selector () {
  input_print "Console keymap (empty => us, '/' to list): "
  read -r kblayout
  case "$kblayout" in
    '') kblayout="us"; info_print "Using us"; return 0;;
    '/') localectl list-keymaps | less; clear; return 1;;
    *) if localectl list-keymaps | grep -Fxq "$kblayout"; then loadkeys "$kblayout"; info_print "Loaded $kblayout"; return 0; else error_print "Keymap not found"; return 1; fi;;
  esac
}

# Check network connectivity
check_network () {
  info_print "Checking network connectivity..."
  if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
    error_print "No network connectivity. Please configure the network (e.g., 'iwctl' or 'nmcli') and try again."
    exit 1
  fi
  info_print "Network is up."
}

# Start UI
echo -ne "${BOLD}${BYELLOW}
======================================================================
 Easy-Arch (unencrypted BTRFS + snapshots) — improved script
 WARNING: This WILL DELETE the selected disk.
 Logs: $LOGFILE
======================================================================
${RESET}"
info_print "Starting installer"

# Verify UEFI
if [[ ! -d /sys/firmware/efi ]]; then
  error_print "UEFI not detected. This script only supports UEFI systems."
  exit 1
fi

until keyboard_selector; do :; done

# Disk selection
mapfile -t DISKS < <(lsblk -dpnoNAME,SIZE,MODEL | awk '{print $1 "  " $2 "  " substr($0,index($0,$3))}')
if [[ ${#DISKS[@]} -eq 0 ]]; then error_print "No disks found"; exit 1; fi

echo "Available disks:"
PS3="Please select target disk: "
select CHOICE in "${DISKS[@]}"; do
  if [[ -n "$CHOICE" ]]; then
    DISK=$(awk '{print $1}' <<< "$CHOICE")
    info_print "Selected disk: $DISK"
    break
  fi
done

# Validate disk size (minimum 20GiB)
MIN_SIZE=$((20*1024*1024)) # 20GiB in KiB
DISK_SIZE=$(blockdev --getsize64 "$DISK" | awk '{print int($1/1024)}')
if [[ $DISK_SIZE -lt $MIN_SIZE ]]; then
  error_print "Disk $DISK is too small ($DISK_SIZE KiB). Minimum required: $MIN_SIZE KiB."
  exit 1
fi

until kernel_selector; do :; done
until network_selector; do :; done
until locale_selector; do :; done
until hostname_selector; do :; done
until userpass_selector; do :; done
until rootpass_selector; do :; done

input_print "This will wipe $DISK — are you sure? [y/N]: "
read -r disk_response
if ! [[ "${disk_response,,}" =~ ^(y|yes)$ ]]; then error_print "Aborting."; exit 1; fi

info_print "Wiping $DISK (wipefs + sgdisk)"
wipefs -af "$DISK"
sgdisk -Zo "$DISK"

info_print "Creating GPT partitions (ESP + ROOT)"
parted -s "$DISK" mklabel gpt \
  mkpart ESP fat32 1MiB 1025MiB \
  set 1 esp on \
  mkpart ROOT btrfs 1025MiB 100%

# Ensure kernel sees partitions
for i in {1..3}; do
  partprobe "$DISK"
  udevadm settle --timeout=5 && break
  sleep 2
done

ESP_PART=$(partdev "$DISK" 1)
ROOT_PART=$(partdev "$DISK" 2)

# Verify partition devices
if [[ ! -b "$ESP_PART" || ! -b "$ROOT_PART" ]]; then
  error_print "Partition devices not found ($ESP_PART, $ROOT_PART). Inspect $LOGFILE and ensure the kernel created partitions."
  exit 1
fi

info_print "Formatting $ESP_PART (FAT32) and $ROOT_PART (btrfs)"
mkfs.fat -F32 "$ESP_PART"
mkfs.btrfs -f "$ROOT_PART"

info_print "Mounting ROOT and creating subvolumes"
mount "$ROOT_PART" /mnt
btrfs subvolume create /mnt/@ || true
btrfs subvolume create /mnt/@home || true
btrfs subvolume create /mnt/@root || true
btrfs subvolume create /mnt/@srv || true
btrfs subvolume create /mnt/@snapshots || true
btrfs subvolume create /mnt/@var_log || true
btrfs subvolume create /mnt/@var_pkgs || true
umount /mnt

mountopts="ssd,noatime,compress-force=zstd:3,discard=async"
mount -o "$mountopts",subvol=@ "$ROOT_PART" /mnt
mkdir -p /mnt/{home,root,srv,.snapshots,var/{log,cache/pacman/pkg},boot}
mount -o "$mountopts",subvol=@home "$ROOT_PART" /mnt/home
mount -o "$mountopts",subvol=@root "$ROOT_PART" /mnt/root
mount -o "$mountopts",subvol=@srv "$ROOT_PART" /mnt/srv
mount -o "$mountopts",subvol=@snapshots "$ROOT_PART" /mnt/.snapshots
mount -o "$mountopts",subvol=@var_log "$ROOT_PART" /mnt/var/log
mount -o "$mountopts",subvol=@var_pkgs "$ROOT_PART" /mnt/var/cache/pacman/pkg
chmod 750 /mnt/root

info_print "Mounting EFI ($ESP_PART) to /mnt/boot"
mount "$ESP_PART" /mnt/boot

microcode_detector

# Check network before pacstrap
check_network

info_print "Installing base system (pacstrap)"
pacstrap -K /mnt base "$kernel" "$microcode" linux-firmware btrfs-progs grub efibootmgr snapper rsync grub-btrfs snap-pac reflector zram-generator sudo || {
  error_print "pacstrap failed. Check $LOGFILE for details."
  exit 1
}

info_print "Writing hostname and fstab"
echo "$hostname" > /mnt/etc/hostname
genfstab -U /mnt > /mnt/etc/fstab

info_print "Configuring locale and keymap"
sed -i "/^#\?$locale/s/^#//" /mnt/etc/locale.gen
echo "LANG=$locale" > /mnt/etc/locale.conf
echo "KEYMAP=$kblayout" > /mnt/etc/vconsole.conf

info_print "Setting /etc/hosts"
cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain   $hostname
EOF

virt_check
network_installer

info_print "Writing mkinitcpio hooks"
cat > /mnt/etc/mkinitcpio.conf <<'EOF'
HOOKS=(systemd autodetect keyboard sd-vconsole modconf block filesystems)
EOF

# Capture host timezone
HOST_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || echo "UTC")

info_print "Entering chroot to finish configuration"
arch-chroot /mnt /bin/bash -e <<EOF_CHROOT
set -euo pipefail
ln -sf /usr/share/zoneinfo/$HOST_TZ /etc/localtime
hwclock --systohc
locale-gen
mkinitcpio -P

# Snapper: create config for root btrfs
if command -v snapper >/dev/null 2>&1; then
  snapper --no-dbus -c root create-config /
  if btrfs subvolume list / | grep -q "/.snapshots"; then
    btrfs subvolume delete /.snapshots
  fi
  mkdir -p /.snapshots
  chmod 750 /.snapshots
fi

# Install GRUB for EFI
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || {
  echo "ERROR: GRUB installation failed." >&2
  exit 1
}
grub-mkconfig -o /boot/grub/grub.cfg
EOF_CHROOT

info_print "Setting root password"
echo "root:$rootpass" | arch-chroot /mnt chpasswd
rootpass=""; rootpass2=""

if [[ -n "${username:-}" ]]; then
  info_print "Creating user $username with wheel privileges"
  echo "%wheel ALL=(ALL:ALL) ALL" > /mnt/etc/sudoers.d/wheel
  arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$username"
  echo "$username:$userpass" | arch-chroot /mnt chpasswd
  userpass=""; userpass2=""
fi

info_print "Adding pacman hook for /boot backup"
mkdir -p /mnt/etc/pacman.d/hooks
cat > /mnt/etc/pacman.d/hooks/50-bootbackup.hook <<EOF
[Trigger]
Operation = Upgrade
Operation = Install
Operation = Remove
Type = Path
Target = usr/lib/modules/*/vmlinuz

[Action]
Depends = rsync
Description = Backing up /boot...
When = PostTransaction
Exec = /usr/bin/rsync -a --delete /boot /.bootbackup
EOF

info_print "ZRAM config"
cat > /mnt/etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = min(ram, 8192)
EOF

info_print "Pacman niceties"
sed -i 's/^#Color/Color/; /ILoveCandy/!s/$/\nILoveCandy/' /mnt/etc/pacman.conf
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /mnt/etc/pacman.conf

info_print "Enabling services"
services=(reflector.timer snapper-timeline.timer snapper-cleanup.timer btrfs-scrub@-.timer btrfs-scrub@home.timer btrfs-scrub@var-log.timer btrfs-scrub@\\x2esnapshots.timer grub-btrfsd.service systemd-oomd)
for s in "${services[@]}"; do
  if ! systemctl enable "$s" --root=/mnt; then
    error_print "Failed to enable service $s"
  fi
done

info_print "Installation finished. Check $LOGFILE for full output."
info_print "Reboot when ready. If issues occur, run: sudo tail -n 200 $LOGFILE"
