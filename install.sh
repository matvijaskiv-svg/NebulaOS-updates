#!/usr/bin/env bash
# NebulaOS on an existing Arch-based system (Garuda, EndeavourOS, CachyOS, Arch) — no reinstall.
# Apps, files, users and the bootloader stay. It adds the [nebulaos] repository, installs the
# NebulaOS desktop on top of KDE Plasma and saves everything it changes, so `sudo nebulaos-undo`
# brings the old desktop back.
#
#   bash install.sh          in a terminal
#   bash install.sh --gui    with windows only (what the double-click file "Install NebulaOS" runs)
set -euo pipefail

REPO_URL=https://github.com/matvijaskiv-svg/NebulaOS-updates/releases/download/repo
DRY=${NEBULA_DRY_RUN:-0}
run() { if [[ $DRY == 1 ]]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi; }
step() { printf 'STEP %s %s\n' "$1" "$2"; }

# ---------------------------------------------------------------- root part (sudo / pkexec)
if [[ ${1:-} == --root-part ]]; then
  STAMP=$2; NEED_PLASMA=$3; USER_BACKUP=$4; TARGET_USER=$5
  SYS_BACKUP=/var/lib/nebulaos-before/$STAMP
  step 2 "Saving the system files NebulaOS replaces"
  run mkdir -p "$SYS_BACKUP"
  for f in /etc/xdg/kdeglobals /etc/xdg/kwinrc /etc/xdg/plasmarc /etc/xdg/kglobalshortcutsrc /etc/xdg/kcminputrc \
           /etc/xdg/ksplashrc /etc/xdg/konsolerc /etc/xdg/breezerc /etc/xdg/kcm-about-distrorc \
           /etc/sddm.conf.d/05-nebula-theme.conf; do
    [[ -e $f ]] && run cp -a --parents "$f" "$SYS_BACKUP/"
  done
  run cp -a /etc/pacman.conf "$SYS_BACKUP/pacman.conf"

  step 3 "Adding the NebulaOS repository"
  if ! grep -q '^\[nebulaos\]' /etc/pacman.conf && ! grep -q 'nebulaos-repo.conf' /etc/pacman.conf; then
    if [[ $DRY == 1 ]]; then echo "[dry-run] add [nebulaos] to /etc/pacman.conf"
    else printf '\n[nebulaos]\nSigLevel = Optional TrustAll\nServer = %s\n' "$REPO_URL" >> /etc/pacman.conf; fi
  fi

  step 4 "Downloading and installing NebulaOS (10–30 minutes)"
  extra=()
  [[ $NEED_PLASMA == 1 ]] && extra+=(plasma-meta sddm)
  run pacman -Syu --needed --noconfirm \
    --overwrite '/etc/xdg/*' --overwrite '/etc/sddm.conf.d/*' --overwrite '/etc/nebulaos/*' \
    --overwrite '/etc/pacman.d/nebulaos-repo.conf' \
    nebulaos-desktop "${extra[@]}"
  # From now on the repository comes from the package's own file (it keeps the address after updates).
  if [[ $DRY != 1 && -f /etc/pacman.d/nebulaos-repo.conf ]]; then
    python3 - <<'PY'
import re
p = "/etc/pacman.conf"
s = open(p).read()
s = re.sub(r"\n\[nebulaos\]\nSigLevel = Optional TrustAll\nServer = [^\n]+\n", "\n", s)
if "nebulaos-repo.conf" not in s:
    s = s.rstrip("\n") + "\n\nInclude = /etc/pacman.d/nebulaos-repo.conf\n"
open(p, "w").write(s)
PY
  fi

  step 5 "Finishing"
  if [[ $NEED_PLASMA == 1 ]] && ! systemctl is-enabled -q sddm 2>/dev/null; then run systemctl enable sddm; fi
  undo=$(mktemp)
  cat > "$undo" <<EOF
#!/usr/bin/env bash
# Back to the desktop you had before NebulaOS ($STAMP). Run: sudo nebulaos-undo
set -uo pipefail
[[ \$EUID -eq 0 ]] || { echo "Run: sudo nebulaos-undo"; exit 1; }
user=$TARGET_USER
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
  run install -m 0755 "$undo" /usr/local/bin/nebulaos-undo
  rm -f "$undo"
  step 6 "Done"
  exit 0
fi

# ---------------------------------------------------------------- user part
GUI=0
[[ ${1:-} == --gui ]] && GUI=1
STAMP=$(date +%Y%m%d-%H%M%S)
USER_BACKUP=$HOME/.local/share/nebulaos-before/$STAMP
SELF=$(readlink -f "$0")

lang=${LANG:-en}
t() {  # t "English" "Italiano" "Русский"
  case $lang in it*) printf '%s' "$2" ;; ru*|uk*) printf '%s' "$3" ;; *) printf '%s' "$1" ;; esac
}
say_error() {
  if [[ $GUI == 1 ]] && command -v kdialog >/dev/null; then kdialog --title NebulaOS --error "$1"
  else printf 'Error: %s\n' "$1" >&2; fi
  exit 1
}

[[ $EUID -ne 0 ]] || say_error "$(t "Run it as your normal user, not root." "Avvialo come utente normale, non root." "Запускайте от обычного пользователя, не root.")"
command -v pacman >/dev/null || say_error "$(t "This is not an Arch-based system." "Questo sistema non è basato su Arch." "Это не система на базе Arch.")"
. /etc/os-release
distro=${PRETTY_NAME:-$ID}
case " ${ID:-} ${ID_LIKE:-} " in *" arch "*|*" garuda "*|*" endeavouros "*|*" cachyos "*|*" manjaro "*) ;;
  *) say_error "$distro: $(t "not Arch-based." "non è basato su Arch." "не на базе Arch.")" ;;
esac
plasma=$(plasmashell --version 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
[[ -z $plasma || $plasma -ge 6 ]] || say_error "$(t "Plasma $plasma is too old: update the system first." "Plasma $plasma è troppo vecchio: aggiorna prima il sistema." "Plasma $plasma слишком старый: сначала обновите систему.")"
NEED_PLASMA=0; [[ -z $plasma ]] && NEED_PLASMA=1

intro=$(t "NebulaOS will be installed on top of $distro.

• Your apps, files, users and passwords stay.
• Your current desktop settings are saved first.
• It downloads a lot: 10–30 minutes. Keep the computer on and connected.
• Changed your mind later? In a terminal: sudo nebulaos-undo

Install NebulaOS now?" \
"NebulaOS verrà installato sopra $distro.

• Le tue app, i file, gli utenti e le password restano.
• Prima vengono salvate le impostazioni attuali del desktop.
• Scarica parecchio: 10–30 minuti. Tieni il computer acceso e connesso.
• Ci ripensi? Nel terminale: sudo nebulaos-undo

Installare NebulaOS adesso?" \
"NebulaOS будет установлена поверх $distro.

• Ваши программы, файлы, пользователи и пароли останутся.
• Сначала сохраняются текущие настройки рабочего стола.
• Скачивается много: 10–30 минут. Не выключайте компьютер и интернет.
• Передумали? В терминале: sudo nebulaos-undo

Установить NebulaOS сейчас?")

if [[ $GUI == 1 ]]; then
  command -v kdialog >/dev/null || say_error "kdialog is missing (sudo pacman -S kdialog)"
  kdialog --title NebulaOS --icon system-software-install --yesno "$intro" || exit 0
else
  printf '%s ' "$intro"; read -r a
  [[ $a == [yYsSдД]* ]] || { echo "Cancelled."; exit 0; }
fi

# 1: user settings (as the user)
mkdir -p "$USER_BACKUP"
for f in kdeglobals kwinrc plasma-org.kde.plasma.desktop-appletsrc plasmashellrc plasmarc kglobalshortcutsrc \
         kcminputrc kxkbrc ksplashrc konsolerc dolphinrc breezerc kscreenlockerrc; do
  [[ -f $HOME/.config/$f ]] && cp -a "$HOME/.config/$f" "$USER_BACKUP/"
done
[[ -d $HOME/.local/share/konsole ]] && cp -a "$HOME/.local/share/konsole" "$USER_BACKUP/konsole"
command -v flatpak >/dev/null && flatpak remote-add --user --if-not-exists flathub \
  https://dl.flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 || true

label() {
  case $1 in
    2) t "Saving system files…" "Salvo i file di sistema…" "Сохраняю системные файлы…" ;;
    3) t "Adding the NebulaOS repository…" "Aggiungo il repository di NebulaOS…" "Подключаю репозиторий NebulaOS…" ;;
    4) t "Downloading and installing NebulaOS (10–30 minutes)…" "Scarico e installo NebulaOS (10–30 minuti)…" "Скачиваю и устанавливаю NebulaOS (10–30 минут)…" ;;
    5) t "Finishing…" "Ultimi ritocchi…" "Завершаю…" ;;
    *) t "Done" "Fatto" "Готово" ;;
  esac
}

log=$(mktemp /tmp/nebulaos-install.XXXX.log)
if [[ $GUI == 1 ]]; then
  root=(pkexec)
  command -v pkexec >/dev/null || say_error "pkexec is missing"
  ref=$(kdialog --title NebulaOS --progressbar "$(t "Waiting for your password…" "Aspetto la tua password…" "Жду ваш пароль…")" 6)
  bar() { qdbus6 $ref Set "" value "$1" >/dev/null 2>&1 || qdbus $ref Set "" value "$1" >/dev/null 2>&1 || true
          qdbus6 $ref setLabelText "$2" >/dev/null 2>&1 || qdbus $ref setLabelText "$2" >/dev/null 2>&1 || true; }
  bar 1 "$(t "Waiting for your password…" "Aspetto la tua password…" "Жду ваш пароль…")"
  NEBULA_DRY_RUN=$DRY "${root[@]}" env NEBULA_DRY_RUN="$DRY" bash "$SELF" --root-part "$STAMP" "$NEED_PLASMA" "$USER_BACKUP" "$USER" \
    > "$log" 2>&1 &
  pid=$!
  last=0
  while kill -0 "$pid" 2>/dev/null; do
    n=$(grep -oE '^STEP [0-9]' "$log" | tail -1 | cut -d' ' -f2 || true)
    if [[ -n $n && $n != "$last" ]]; then last=$n; bar "$n" "$(label "$n")"; fi
    sleep 1
  done
  wait "$pid" && ok=1 || ok=0
  qdbus6 $ref close >/dev/null 2>&1 || qdbus $ref close >/dev/null 2>&1 || true
  if [[ $ok == 1 ]]; then
    if kdialog --title NebulaOS --icon nebulaos --yesno "$(t "NebulaOS is installed!

Log out now to see it? (Save your work first.)
Super+M switches mode · Super+H opens Settings." "NebulaOS è installato!

Uscire ora dalla sessione per vederlo? (Salva prima il tuo lavoro.)
Super+M cambia modo · Super+H apre le Impostazioni." "NebulaOS установлена!

Выйти из сеанса сейчас, чтобы увидеть её? (Сначала сохраните работу.)
Super+M — смена режима · Super+H — Настройки.")"; then
      qdbus6 org.kde.Shutdown /Shutdown logout >/dev/null 2>&1 || qdbus org.kde.Shutdown /Shutdown logout >/dev/null 2>&1 || true
    fi
  else
    kdialog --title NebulaOS --error "$(t "The installation did not finish. Nothing important was changed.
Details are in" "L'installazione non è finita. Niente di importante è stato cambiato.
I dettagli sono in" "Установка не завершилась. Ничего важного не изменено.
Подробности в") $log

$(grep -v '^STEP' "$log" | tail -8)"
    exit 1
  fi
else
  sudo env NEBULA_DRY_RUN="$DRY" bash "$SELF" --root-part "$STAMP" "$NEED_PLASMA" "$USER_BACKUP" "$USER" 2>&1 | tee "$log" |
    while IFS= read -r line; do
      if [[ $line == STEP* ]]; then printf '\033[1m%s\033[0m\n' "$(label "${line:5:1}")"; else printf '%s\n' "$line"; fi
    done
  [[ ${PIPESTATUS[0]} == 0 ]] || { echo "The installation did not finish. Log: $log"; exit 1; }
  echo "NebulaOS is installed. Log out and log back in. Super+M switches mode. Undo: sudo nebulaos-undo"
fi
