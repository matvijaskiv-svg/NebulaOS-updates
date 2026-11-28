#!/usr/bin/env bash
# NebulaOS on an existing Arch-based system (Garuda, EndeavourOS, CachyOS, Arch) — no reinstall.
# Apps, files, users and the bootloader stay. It adds the [nebulaos] repository, installs the
# NebulaOS desktop on top of KDE Plasma and saves everything it changes, so `sudo nebulaos-undo`
# brings the old desktop back.
#
#   curl -fsSLO https://raw.githubusercontent.com/matvijaskiv-svg/NebulaOS-updates/main/install.sh
#   bash install.sh            (run as your normal user, not root)
set -euo pipefail

REPO_URL=https://github.com/matvijaskiv-svg/NebulaOS-updates/releases/download/repo
STAMP=$(date +%Y%m%d-%H%M%S)
USER_BACKUP=$HOME/.local/share/nebulaos-before/$STAMP
SYS_BACKUP=/var/lib/nebulaos-before/$STAMP
DRY=${NEBULA_DRY_RUN:-0}

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
run() { if [[ $DRY == 1 ]]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi; }

[[ $EUID -ne 0 ]] || die "run it as your normal user (it asks for sudo itself)."
command -v pacman >/dev/null || die "this is not an Arch-based system (no pacman)."
command -v sudo >/dev/null || die "sudo is missing."
. /etc/os-release
distro=${PRETTY_NAME:-$ID}
case " ${ID:-} ${ID_LIKE:-} " in *" arch "*|*" garuda "*|*" endeavouros "*|*" cachyos "*|*" manjaro "*) ;;
  *) die "$distro is not Arch-based." ;;
esac
if [[ ${ID:-} == manjaro ]]; then
  echo "Note: Manjaro holds packages back for weeks; NebulaOS follows Arch, so some parts may not match yet."
fi
plasma=$(plasmashell --version 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)

bold "NebulaOS on $distro"
cat <<EOF
What happens:
  • adds the [nebulaos] update repository and installs the NebulaOS desktop on KDE Plasma 6
    $( [[ -z $plasma ]] && echo "(Plasma is not installed: it will be installed too)" )
  • your apps, files, users, passwords and boot menu stay as they are
  • your current desktop settings are saved to $USER_BACKUP
  • system files it replaces are saved to $SYS_BACKUP
  • to go back at any time: sudo nebulaos-undo
EOF
[[ -n $plasma && $plasma -lt 6 ]] && die "Plasma $plasma is too old; NebulaOS needs Plasma 6 (update the system first)."
read -r -p "Continue? [y/N] " a
[[ $a == [yYsS]* ]] || { echo "Cancelled."; exit 0; }

bold "1/5 Saving your current desktop settings"
run mkdir -p "$USER_BACKUP"
for f in kdeglobals kwinrc plasma-org.kde.plasma.desktop-appletsrc plasmashellrc plasmarc kglobalshortcutsrc \
         kcminputrc kxkbrc ksplashrc konsolerc dolphinrc breezerc kscreenlockerrc; do
  [[ -f $HOME/.config/$f ]] && run cp -a "$HOME/.config/$f" "$USER_BACKUP/"
done
[[ -d $HOME/.local/share/konsole ]] && run cp -a "$HOME/.local/share/konsole" "$USER_BACKUP/konsole"
printf '%s\n' "$USER_BACKUP" > /tmp/nebulaos-user-backup

bold "2/5 Saving the system files NebulaOS replaces"
files=(/etc/xdg/kdeglobals /etc/xdg/kwinrc /etc/xdg/plasmarc /etc/xdg/kglobalshortcutsrc /etc/xdg/kcminputrc
       /etc/xdg/ksplashrc /etc/xdg/konsolerc /etc/xdg/breezerc /etc/xdg/kcm-about-distrorc
       /etc/sddm.conf.d/05-nebula-theme.conf)
run sudo mkdir -p "$SYS_BACKUP"
for f in "${files[@]}"; do
  [[ -e $f ]] && run sudo cp -a --parents "$f" "$SYS_BACKUP/"
done
run sudo cp -a /etc/pacman.conf "$SYS_BACKUP/pacman.conf"

bold "3/5 Adding the NebulaOS repository"
if ! grep -q '^\[nebulaos\]' /etc/pacman.conf && ! grep -q 'nebulaos-repo.conf' /etc/pacman.conf; then
  if [[ $DRY == 1 ]]; then
    echo "[dry-run] add [nebulaos] → $REPO_URL to /etc/pacman.conf"
  else
    printf '\n[nebulaos]\nSigLevel = Optional TrustAll\nServer = %s\n' "$REPO_URL" | sudo tee -a /etc/pacman.conf >/dev/null
  fi
fi

bold "4/5 Installing NebulaOS (this downloads a lot the first time)"
extra=()
[[ -z $plasma ]] && extra+=(plasma-meta sddm)
run sudo pacman -Syu --needed --noconfirm \
  --overwrite '/etc/xdg/*' --overwrite '/etc/sddm.conf.d/*' --overwrite '/etc/nebulaos/*' \
  --overwrite '/etc/pacman.d/nebulaos-repo.conf' \
  nebulaos-desktop "${extra[@]}"
# From now on the repository comes from the package (its file keeps the address after updates).
if [[ $DRY != 1 ]] && [[ -f /etc/pacman.d/nebulaos-repo.conf ]]; then
  sudo python3 - <<'PY'
import re
p = "/etc/pacman.conf"
s = open(p).read()
s = re.sub(r"\n\[nebulaos\]\nSigLevel = Optional TrustAll\nServer = [^\n]+\n", "\n", s)
if "nebulaos-repo.conf" not in s:
    s = s.rstrip("\n") + "\n\nInclude = /etc/pacman.d/nebulaos-repo.conf\n"
open(p, "w").write(s)
PY
fi

bold "5/5 Finishing"
command -v flatpak >/dev/null && run flatpak remote-add --user --if-not-exists flathub \
  https://dl.flathub.org/repo/flathub.flatpakrepo || true
if [[ -z $plasma ]] && ! systemctl is-enabled -q sddm 2>/dev/null; then
  run sudo systemctl enable sddm
fi
undo=$(mktemp)
cat > "$undo" <<EOF
#!/usr/bin/env bash
# Back to the desktop you had before NebulaOS ($STAMP). Run: sudo nebulaos-undo
set -uo pipefail
[[ \$EUID -eq 0 ]] || { echo "Run: sudo nebulaos-undo"; exit 1; }
user=\${SUDO_USER:-$USER}
home=\$(getent passwd "\$user" | cut -d: -f6)
echo "==> Removing the NebulaOS desktop (your apps stay)"
pacman -R --noconfirm nebulaos-desktop || true
echo "==> Restoring system files"
cp -a "$SYS_BACKUP/etc/." /etc/ 2>/dev/null || true
cp -a "$SYS_BACKUP/pacman.conf" /etc/pacman.conf
echo "==> Restoring your desktop settings"
for f in "$USER_BACKUP"/*; do
  [[ -e \$f ]] || continue
  if [[ \$(basename "\$f") == konsole ]]; then cp -a "\$f/." "\$home/.local/share/konsole/"
  else install -o "\$user" -m 0600 "\$f" "\$home/.config/"; fi
done
rm -rf "\$home/.config/nebulaos" "\$home/.local/share/dolphin/view_properties/global"
rm -f /usr/local/bin/nebulaos-undo
echo "Done. Log out and back in to see your old desktop."
EOF
run sudo install -m 0755 "$undo" /usr/local/bin/nebulaos-undo
rm -f "$undo"

bold "NebulaOS is installed."
echo "Log out and log back in. Switch mode: Super+M · Settings: Super+H · Updates: nebula update"
echo "Changed your mind? sudo nebulaos-undo"
