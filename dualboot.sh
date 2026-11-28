#!/usr/bin/env bash
# NebulaOS NEXT TO Garuda (or any Arch-based system on btrfs) — choose the system at every boot.
# No USB stick and no repartitioning: NebulaOS goes into its own btrfs subvolumes (@nebula,
# @nebula-home) on the same partition, and a "NebulaOS" entry is added to the existing GRUB menu.
# Garuda, its apps, files and snapshots are not touched.
#
#   curl -fsSLO https://raw.githubusercontent.com/matvijaskiv-svg/NebulaOS-updates/main/dualboot.sh
#   sudo bash dualboot.sh            install
#   sudo bash dualboot.sh remove     delete NebulaOS again (Garuda stays)
set -euo pipefail

REPO_URL=https://github.com/matvijaskiv-svg/NebulaOS-updates/releases/download/repo
TOP=/mnt/nebulaos-top
TARGET=/mnt/nebulaos
GRUB_ENTRY=/etc/grub.d/41_nebulaos
NEED_GB=${NEBULA_NEED_GB:-20}
# For testing only: another btrfs device instead of the one / lives on, fewer packages, no GRUB.
DEV=${NEBULA_DEV:-}
PKGS_OVERRIDE=${NEBULA_PKGS:-}
NO_GRUB=${NEBULA_NO_GRUB:-0}

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
CREATED=0
FINISHED=0
cleanup() {
  umount -R "$TARGET" 2>/dev/null || true
  if [[ $CREATED == 1 && $FINISHED == 0 ]]; then   # failed half way: leave nothing behind
    echo "Installation stopped — removing the unfinished NebulaOS (your system is untouched)." >&2
    delete_subvol "$TOP/@nebula-home" 2>/dev/null || true
    delete_subvol "$TOP/@nebula" 2>/dev/null || true
    rm -f "$GRUB_ENTRY"
  fi
  umount "$TOP" 2>/dev/null || true
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "run it with sudo: sudo bash dualboot.sh"
if [[ -z $DEV ]]; then
  [[ $(findmnt -no FSTYPE /) == btrfs ]] || die "the system disk is not btrfs. Use install.sh (NebulaOS on top) instead."
  DEV=$(findmnt -no SOURCE / | sed 's/\[.*//')
fi
UUID=$(blkid -s UUID -o value "$DEV")
[[ -n $UUID ]] || die "cannot read the UUID of $DEV"

update_grub() {
  [[ $NO_GRUB == 1 ]] && return 0
  if command -v update-grub >/dev/null; then update-grub
  else grub-mkconfig -o /boot/grub/grub.cfg; fi
}

delete_subvol() {   # nested subvolumes first (systemd creates some under /var/lib)
  local path=$1 sub
  [[ -d $path ]] || return 0
  while read -r sub; do
    [[ -n $sub ]] && btrfs subvolume delete "$TOP/$sub" >/dev/null 2>&1 || true
  done < <(btrfs subvolume list -o "$path" | awk '{print $NF}' | sed 's#^<FS_TREE>/##' | sort -r)
  btrfs subvolume delete "$path" >/dev/null
}

mkdir -p "$TOP"
mount -o subvolid=5 "$DEV" "$TOP"

if [[ ${1:-} == remove ]]; then
  bold "Removing NebulaOS (Garuda stays)"
  read -r -p "Delete NebulaOS and everything saved inside it? [y/N] " a
  [[ $a == [yYsS]* ]] || { echo "Cancelled."; exit 0; }
  delete_subvol "$TOP/@nebula-home"
  delete_subvol "$TOP/@nebula"
  rm -f "$GRUB_ENTRY"
  update_grub
  echo "NebulaOS removed."
  exit 0
fi

[[ ! -e $TOP/@nebula ]] || die "NebulaOS is already installed next to this system (remove: sudo bash dualboot.sh remove)."
free=$(btrfs filesystem usage -b "$TOP" 2>/dev/null | awk '/Free \(estimated\)/ {print $3; exit}')
[[ -z $free || $free -ge $((NEED_GB * 1024 ** 3)) ]] || die "needs ${NEED_GB} GB free on the disk, there are $((free / 1024 ** 3)) GB."
user=${SUDO_USER:-}
[[ -n $user && $user != root ]] || read -r -p "User name for NebulaOS: " user
[[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] || die "bad user name: $user"

. /etc/os-release
bold "NebulaOS next to ${PRETTY_NAME:-this system}"
cat <<EOF
  • NebulaOS gets its own space on $DEV (btrfs subvolumes @nebula and @nebula-home)
  • at every start you choose "NebulaOS" or your current system in the boot menu
  • your current system, apps, files and snapshots are not touched
  • user: $user (you choose the NebulaOS password in a moment)
  • remove it later: sudo bash dualboot.sh remove
EOF
echo "Mode: 1) Gaming  2) Hacking  3) Server"
read -r -p "Choose [1]: " m
case ${m:-1} in 2) mode=hacking ;; 3) mode=server ;; *) mode=gaming ;; esac
read -r -p "Install NebulaOS ($mode)? [y/N] " a
[[ $a == [yYsS]* ]] || { echo "Cancelled."; exit 0; }

bold "1/5 Making room (btrfs subvolumes)"
btrfs subvolume create "$TOP/@nebula" >/dev/null
btrfs subvolume create "$TOP/@nebula-home" >/dev/null
CREATED=1
mkdir -p "$TARGET"
mount -o subvol=@nebula,compress=zstd,noatime "$DEV" "$TARGET"
mkdir -p "$TARGET/home"
mount -o subvol=@nebula-home,compress=zstd,noatime "$DEV" "$TARGET/home"

bold "2/5 Downloading and installing NebulaOS (a few GB, takes a while)"
command -v pacstrap >/dev/null || pacman -S --needed --noconfirm arch-install-scripts
conf=$(mktemp)
cat > "$conf" <<EOF
[options]
Architecture = auto
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
ParallelDownloads = 5
[core]
Include = /etc/pacman.d/mirrorlist
[extra]
Include = /etc/pacman.d/mirrorlist
[multilib]
Include = /etc/pacman.d/mirrorlist
[nebulaos]
SigLevel = Optional TrustAll
Server = $REPO_URL
EOF
ucode=""
grep -q GenuineIntel /proc/cpuinfo && ucode=intel-ucode
grep -q AuthenticAMD /proc/cpuinfo && ucode=amd-ucode
if [[ -n $PKGS_OVERRIDE ]]; then
  read -r -a pkgs <<< "$PKGS_OVERRIDE"
else
  pkgs=(base linux linux-headers linux-firmware btrfs-progs networkmanager sudo sddm nebulaos-desktop
        libreoffice-fresh firefox pipewire pipewire-alsa pipewire-pulse wireplumber ufw)
  [[ -n $ucode ]] && pkgs+=("$ucode")
fi
pacstrap -C "$conf" -K "$TARGET" "${pkgs[@]}"
rm -f "$conf"

bold "3/5 Setting it up"
# Only NebulaOS's own mounts: the host's swap (zram, swap files) would make every boot wait for it.
genfstab -U "$TARGET" | grep -v '^#' | awk '$3 != "swap"' | sed '/^$/d' > "$TARGET/etc/fstab"
arch-chroot "$TARGET" pacman -Q zram-generator >/dev/null 2>&1 ||
  { [[ -n $PKGS_OVERRIDE ]] || arch-chroot "$TARGET" pacman -S --noconfirm --needed zram-generator >/dev/null 2>&1 || true; }
# Same time zone, language and keyboard as the current system.
[[ -L /etc/localtime ]] && ln -sf "$(readlink /etc/localtime)" "$TARGET/etc/localtime"
for f in locale.conf vconsole.conf; do [[ -f /etc/$f ]] && cp "/etc/$f" "$TARGET/etc/$f"; done
lang=$(sed -n 's/^LANG=//p' /etc/locale.conf 2>/dev/null | tr -d '"')
for l in en_US.UTF-8 ${lang:-}; do sed -i "s/^#\(${l//./\\.} UTF-8\)/\1/" "$TARGET/etc/locale.gen"; done
echo nebulaos > "$TARGET/etc/hostname"
mkdir -p "$TARGET/etc/nebulaos"
echo "$mode" > "$TARGET/etc/nebulaos/default-mode"
grep -q nebulaos-repo.conf "$TARGET/etc/pacman.conf" ||
  printf '\nInclude = /etc/pacman.d/nebulaos-repo.conf\n' >> "$TARGET/etc/pacman.conf"
arch-chroot "$TARGET" /bin/bash -e <<EOF
locale-gen >/dev/null
useradd -m -G wheel -s /bin/bash "$user" 2>/dev/null || true
mkdir -p /etc/sudoers.d
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
systemctl enable NetworkManager sddm >/dev/null 2>&1 || true
systemctl enable bluetooth power-profiles-daemon cups.socket >/dev/null 2>&1 || true
EOF

bold "4/5 NebulaOS password for $user"
if [[ -n ${NEBULA_PASSWORD:-} ]]; then   # tests only
  echo "$user:$NEBULA_PASSWORD" | arch-chroot "$TARGET" chpasswd
else
  until arch-chroot "$TARGET" passwd "$user"; do echo "Try again."; done
fi

bold "5/5 Adding NebulaOS to the boot menu"
initrd=""
[[ -n $ucode && -f $TARGET/boot/$ucode.img ]] && initrd="/@nebula/boot/$ucode.img "
cat > "$GRUB_ENTRY" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry 'NebulaOS' --class nebulaos --class arch --class gnu-linux {
    insmod part_gpt
    insmod part_msdos
    insmod btrfs
    search --no-floppy --fs-uuid --set=root $UUID
    linux /@nebula/boot/vmlinuz-linux root=UUID=$UUID rootflags=subvol=@nebula rw quiet splash
    initrd ${initrd}/@nebula/boot/initramfs-linux.img
}
EOF
chmod 0755 "$GRUB_ENTRY"
# Make sure the menu is shown, so there is a choice at every start.
if [[ $NO_GRUB != 1 && -f /etc/default/grub ]]; then
  sed -i 's/^GRUB_TIMEOUT_STYLE=hidden/GRUB_TIMEOUT_STYLE=menu/; s/^GRUB_TIMEOUT=0$/GRUB_TIMEOUT=5/' /etc/default/grub
fi
update_grub
FINISHED=1

bold "Done!"
echo "Restart the computer and choose NebulaOS in the boot menu."
echo "Your current system is still there as the first entry."
