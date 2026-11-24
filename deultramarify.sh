#!/usr/bin/env bash
#
# deultramarify.sh
#
# Convert any Ultramarine Linux edition (Plasma, GNOME, Budgie or Xfce) back
# to the matching clean Fedora spin, then download the latest stable Fedora
# release for an offline system upgrade.
#
# The script is the inverse of Ultramarine's Fedora -> Ultramarine migration
# script.  It is deliberately conservative:
#   * it keeps RPM Fusion and the user's third-party applications;
#   * it replaces Ultramarine/Terra-patched packages with Fedora versions when
#     a Fedora build of the same package exists, instead of deleting them;
#   * it pins the upgrade to the detected Fedora spin before downloading it.
#
# Usage:
#   sudo ./deultramarify.sh              # interactive conversion + upgrade
#   sudo ./deultramarify.sh --check      # read-only checks and dry runs
#   sudo ./deultramarify.sh --yes        # unattended (reboots when ready)
#
set -Eeuo pipefail
umask 077

SCRIPT_NAME=$(basename "$0")
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
MODE=run
ASSUME_YES=0
CURRENT=""
LATEST=""
IS_UM=0
UM_IDENTITY=""
UM_RELEASE_PKG=""
UM_VARIANT_ID=""
FEDORA_SPIN=""
DESKTOP_NAME=""
RELEASE_PKG=""
IDENTITY_PKG=""
TARGET_VARIANT_ID=""
CRITICAL_DESKTOP_PKGS=()
VARIANT_EXCLUDES=()
PATCHED_PKGS=()

usage() {
  cat <<EOF
Usage: sudo $SCRIPT_NAME [--check] [--yes]

  --check, --dry-run   Run all read-only checks and dry runs. No changes.
  --yes, -y            Do not prompt; reboot automatically when ready.

Without options the script prompts once before changing anything and again
before rebooting into the downloaded Fedora upgrade.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --check|--dry-run) MODE=check ;;
    --yes|-y)          ASSUME_YES=1 ;;
    --help|-h)         usage; exit 0 ;;
    *)
      echo "Unknown option: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ $MODE == run && $EUID -ne 0 ]]; then
  echo "This script must run as root. Use: sudo $SCRIPT_NAME" >&2
  exit 1
fi

if [[ $EUID -eq 0 ]]; then
  LOG="/var/log/deultramarify-$MODE-$TIMESTAMP.log"
else
  LOG="/tmp/deultramarify-$MODE-$TIMESTAMP.log"
fi
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/deultramarify.$MODE.XXXXXX")
: >"$LOG"
chmod 600 "$LOG"

log() {
  printf '%s\n' "$*" | tee -a "$LOG"
}

section() {
  printf '\n==> %s\n' "$*" | tee -a "$LOG"
}

abort() {
  local msg=$*
  {
    printf '\nERROR: %s\n' "$msg"
    printf 'Log: %s\n' "$LOG"
    if [[ -n ${BACKUP_DIR:-} ]]; then
      printf 'Backup: %s\n' "$BACKUP_DIR"
    fi
  } | tee -a "$LOG" >&2
  exit 1
}

on_error() {
  local rc=$?
  {
    printf '\nERROR: command failed (exit %s) at line %s: %s\n' "$rc" "$1" "$2"
    printf 'Log: %s\n' "$LOG"
    printf 'Preflight logs: %s\n' "$WORK_DIR"
    if [[ -n ${BACKUP_DIR:-} ]]; then
      printf 'Backup: %s\n' "$BACKUP_DIR"
    fi
    if [[ $MODE == check ]]; then
      printf 'Check mode: no changes were made.\n'
    else
      printf 'The system may be partially converted. Review the log before rebooting.\n'
      printf 'If the release swap did not complete, the system still boots Ultramarine normally.\n'
    fi
  } | tee -a "$LOG" >&2
  exit "$rc"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# Run a command, tee output to the main log, and return its real exit status.
run() {
  local rc=0
  printf '\n+ %s\n' "$*" | tee -a "$LOG"
  "$@" 2>&1 | tee -a "$LOG" || rc=$?
  return "$rc"
}

# Like run(), but also keeps a separate copy for parsing (dry runs).
run_capture() {
  local out=$1
  shift
  local rc=0
  printf '\n+ %s\n' "$*" | tee -a "$LOG"
  "$@" 2>&1 | tee -a "$LOG" "$out" || rc=$?
  return "$rc"
}

show_txn_summary() {
  local out=$1
  grep -E '^(Transaction Summary:| (Installing|Upgrading|Replacing|Removing|Downgrading):|Total size|After this operation|Nothing to do)' \
    "$out" 2>/dev/null | tail -20 | tee -a "$LOG" || true
}

check_txn() {
  local out=$1
  if grep -q 'Failed to resolve the transaction' "$out" 2>/dev/null; then
    return 1
  fi
  if ! grep -q '^Transaction Summary:' "$out" 2>/dev/null && \
     ! grep -q 'Nothing to do' "$out" 2>/dev/null; then
    return 1
  fi
  return 0
}

repo_exists() {
  local v=$1
  curl -fsI --max-time 20 \
    "https://dl.fedoraproject.org/pub/fedora/linux/releases/$v/Everything/x86_64/os/repodata/repomd.xml" \
    >/dev/null 2>&1
}

latest_from_bodhi() {
  curl -fsSL --max-time 30 -H 'Accept: application/json' \
    'https://bodhi.fedoraproject.org/releases/?state=current' 2>/dev/null |
    python3 -c 'import json,sys,re
d=json.load(sys.stdin)
vals=[int(m.group(1)) for r in d.get("releases",[]) if (m:=re.match(r"^F(\d+)$", r.get("name","")))]
print(max(vals) if vals else "")' 2>/dev/null || true
}

latest_from_dl() {
  local v
  for v in $(curl -fsSL --max-time 30 \
      'https://dl.fedoraproject.org/pub/fedora/linux/releases/' 2>/dev/null |
      grep -oE 'href="[0-9]+/"' | grep -oE '[0-9]+' | sort -rn | uniq); do
    if repo_exists "$v"; then
      printf '%s\n' "$v"
      return 0
    fi
  done
  return 1
}

repo_ids_present() {
  local prefix=$1
  grep -qiE "^[[:space:]]*\\[${prefix}" /etc/yum.repos.d/*.repo 2>/dev/null
}

# Build the DNF base command.  dnf5 treats a --disablerepo pattern that matches
# no repository as a hard error, so only add each option while a matching repo
# file still exists.  build_dnf() is called again after the Ultramarine/Terra
# repository files have been removed.
build_dnf() {
  DNF=(dnf -y)
  if repo_ids_present ultramarine; then
    DNF+=(--disablerepo='ultramarine*')
  fi
  if repo_ids_present terra; then
    DNF+=(--disablerepo='terra*')
  fi
  DNF_TARGET=("${DNF[@]}" --releasever="$LATEST")
  if ((${#VARIANT_EXCLUDES[@]})); then
    DNF_TARGET+=("${VARIANT_EXCLUDES[@]}")
  fi
}

target_pkg_exists() {
  local p=$1
  local out
  out=$("${DNF[@]}" --releasever="$LATEST" repoquery --qf '%{name}\n' "$p" 2>/dev/null | tail -1 || true)
  [[ $out == "$p" ]]
}

# Do not rely on `rpm -q --qf '%{VENDOR}'` here: with both i686 and x86_64
# builds installed it concatenates the values ("TerraTerra") and the compare
# silently fails.  Query the whole rpmdb with a newline-terminated format.
terra_mesa_present() {
  rpm -qa --qf '%{NAME}|%{VENDOR}\n' |
    awk -F'|' '$1 ~ /^mesa-/ && $2=="Terra" { found=1 } END { exit !found }'
}

# All installed packages carrying Ultramarine/Terra branding, either through
# the vendor field or through an Ultramarine release suffix (.umNN).
branded_packages() {
  rpm -qa --qf '%{NAME}|%{VENDOR}|%{RELEASE}\n' |
    awk -F'|' '$2 ~ /Ultramarine/ || $2 ~ /Terra/ || $3 ~ /\.um[0-9]+/ {print $1}' |
    sort -u
}

# Branded packages that also exist in Fedora can be put back with distro-sync.
# The rest are Ultramarine/Terra-only and get removed.
patched_packages() {
  local p
  while IFS= read -r p; do
    case "$p" in
      ultramarine-release*|ultramarine-logos|ultramarine-backgrounds-compat|terra-release*) continue ;;
    esac
    target_pkg_exists "$p" && printf '%s\n' "$p"
  done < <(branded_packages)
  return 0
}

# Work out which Fedora spin matches this Ultramarine install.  The edition is
# taken from os-release first, then from the installed ultramarine-release*
# package, then from the desktop stack itself.  The names come from the
# reverse of Ultramarine's own migrate.sh.
detect_target_spin() {
  local spin="" name="" vid="" umrel=""
  vid=${UM_VARIANT_ID,,}
  umrel=$(rpm -qa --qf '%{NAME}\n' | grep '^ultramarine-release' | sort | tr '\n' ' ' || true)

  case "$vid" in
    kde|plasma)        spin=kde-desktop; name="KDE Plasma" ;;
    gnome|workstation) spin=workstation; name="GNOME" ;;
    budgie|flagship)   spin=budgie; name="Budgie" ;;
    xfce)              spin=xfce; name="Xfce" ;;
    container)         spin=container; name="container" ;;
  esac

  if [[ -z $spin ]]; then
    case " $umrel " in
      *ultramarine-release-kde*) spin=kde-desktop; name="KDE Plasma" ;;
      *ultramarine-release-gnome*) spin=workstation; name="GNOME" ;;
      *ultramarine-release-budgie*|*ultramarine-release-flagship*) spin=budgie; name="Budgie" ;;
      *ultramarine-release-xfce*) spin=xfce; name="Xfce" ;;
      *ultramarine-release-identity-container*) spin=container; name="container" ;;
    esac
  fi

  if [[ -z $spin ]]; then
    if rpm -q plasma-desktop >/dev/null 2>&1; then
      spin=kde-desktop; name="KDE Plasma"
    elif rpm -q gnome-shell >/dev/null 2>&1; then
      spin=workstation; name="GNOME"
    elif rpm -q budgie-desktop >/dev/null 2>&1; then
      spin=budgie; name="Budgie"
    elif rpm -q xfce4-session >/dev/null 2>&1; then
      spin=xfce; name="Xfce"
    fi
  fi

  [[ -n $spin ]] || abort "Could not determine the Ultramarine edition from os-release, release packages or installed desktop."

  FEDORA_SPIN=$spin
  DESKTOP_NAME=$name
  if [[ $spin == container ]]; then
    RELEASE_PKG=fedora-release-container
    IDENTITY_PKG=fedora-release-identity-container
    TARGET_VARIANT_ID=container
    CRITICAL_DESKTOP_PKGS=()
  else
    RELEASE_PKG=fedora-release-$spin
    IDENTITY_PKG=fedora-release-identity-$spin
    TARGET_VARIANT_ID=$spin
    case "$spin" in
      kde-desktop) CRITICAL_DESKTOP_PKGS=(kde-settings-plasma plasma-desktop plasma-workspace plasma-login-manager) ;;
      workstation) CRITICAL_DESKTOP_PKGS=(gnome-shell gnome-session) ;;
      budgie)      CRITICAL_DESKTOP_PKGS=(budgie-desktop) ;;
      xfce)        CRITICAL_DESKTOP_PKGS=(xfce4-session xfwm4) ;;
    esac
  fi
}

remove_file() {
  local f
  for f in "$@"; do
    if [[ -e $f || -L $f ]]; then
      rm -f -- "$f"
      log "Removed $f"
    fi
  done
}

clean_repo_files() {
  local f
  for f in /etc/yum.repos.d/ultramarine*.repo* /etc/yum.repos.d/terra*.repo*; do
    if [[ -e $f || -L $f ]]; then
      remove_file "$f"
    fi
  done
  for f in /etc/yum.repos.d/*.repo*; do
    if [[ -e $f || -L $f ]] && grep -qiE 'ultramarine|fyralabs|terra' "$f" 2>/dev/null; then
      remove_file "$f"
    fi
  done
}

backup_tar() {
  local out=$1
  shift
  local rc=0
  printf '\n+ tar -czf %s %s\n' "$out" "$*" | tee -a "$LOG"
  tar --warning=no-file-changed -czf "$out" "$@" 2>&1 | tee -a "$LOG" || rc=$?
  if (( rc > 1 )); then
    return "$rc"
  fi
  if (( rc == 1 )); then
    log "WARNING: tar reported changed files while reading; archive kept."
  fi
  [[ -s $out ]]
}

# Only touch text config files that actually point at an Ultramarine
# wallpaper.  KDE keeps its setting in a .rc file, Xfce in an XML file, and
# GNOME/Budgie normally keep it in dconf, which is binary and left alone.
fix_user_wallpaper() {
  local user=$1 home=$2
  [[ -n $user && -d $home ]] || return 0

  local files=()
  mapfile -t files < <(
    find "$home/.config" -maxdepth 4 -type f -size -2M \
      \( -name '*.rc' -o -name '*appletsrc*' -o -name '*.xml' \
         -o -name '*.conf' -o -name '*.ini' -o -name keyfile \) \
      -print0 2>/dev/null |
      xargs -0 -r grep -Il -E '/usr/share/(wallpapers/Ultramarine|backgrounds/ultramarine)' 2>/dev/null
  )
  ((${#files[@]})) || return 0

  local f mode owner group
  for f in "${files[@]}"; do
    [[ -f $f ]] || continue
    cp -a "$f" "$BACKUP_DIR/home-$user-$(basename "$f")"
    mode=$(stat -c '%a' "$f")
    owner=$(stat -c '%u' "$f")
    group=$(stat -c '%g' "$f")
    sed -i -E \
      -e 's|/usr/share/wallpapers/Ultramarine[^"[:space:]]*|/usr/share/wallpapers/Default|g' \
      -e 's|/usr/share/backgrounds/ultramarine-linux[^"[:space:]]*|/usr/share/backgrounds/default.jxl|g' \
      -e 's|^DynamicMode=1$|DynamicMode=0|' \
      "$f"
    chown "$owner:$group" "$f"
    chmod "$mode" "$f"
    restorecon "$f" 2>/dev/null || true
    if grep -qE '/usr/share/(wallpapers/Ultramarine|backgrounds/ultramarine)' "$f" 2>/dev/null; then
      abort "Could not update the Ultramarine wallpaper reference in $f."
    fi
    log "Switched Ultramarine wallpaper reference to Fedora default in $f"
  done
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
section "Preflight"
log "deultramarify $TIMESTAMP (mode: $MODE)"
log "Log: $LOG"
log "Preflight logs: $WORK_DIR"

for cmd in dnf rpm curl python3 tar grub2-mkconfig; do
  command -v "$cmd" >/dev/null 2>&1 || abort "Required command not found: $cmd"
done

[[ -r /etc/os-release ]] || abort "/etc/os-release is missing or unreadable."
rpm -q dnf5 >/dev/null 2>&1 || abort "This script requires DNF 5 (dnf5)."

if ! curl -fsS --max-time 20 'https://dl.fedoraproject.org/pub/fedora/linux/releases/' >/dev/null 2>&1; then
  abort "No network access to dl.fedoraproject.org."
fi

CURRENT=$(rpm -E %fedora)
[[ $CURRENT =~ ^[0-9]+$ ]] || abort "Could not determine the current Fedora release."

LATEST=$(latest_from_bodhi || true)
if [[ -z $LATEST ]] || ! repo_exists "$LATEST"; then
  log "Bodhi detection unavailable or invalid; falling back to dl.fedoraproject.org."
  LATEST=$(latest_from_dl || true)
fi
[[ -n $LATEST && $LATEST =~ ^[0-9]+$ ]] || abort "Could not detect the latest stable Fedora release."
if (( LATEST < CURRENT )); then
  abort "Detected latest Fedora ($LATEST) is older than the current release ($CURRENT)."
fi
if (( LATEST > CURRENT + 1 )); then
  abort "Current release is Fedora $CURRENT but the latest is Fedora $LATEST. Fedora only supports upgrading one release at a time."
fi

log "Current Fedora base: $CURRENT"
log "Latest stable Fedora: $LATEST"

UM_VARIANT_ID=$(. /etc/os-release 2>/dev/null; printf '%s' "${VARIANT_ID:-}")

if grep -q '^ID=ultramarine' /etc/os-release 2>/dev/null || \
   rpm -qa --qf '%{NAME}\n' | grep -q '^ultramarine-release'; then
  IS_UM=1
fi

UM_IDENTITY=$(rpm -qa --qf '%{NAME}\n' | grep -m1 '^ultramarine-release-identity' || true)
UM_RELEASE_PKG=$(rpm -qa --qf '%{NAME}\n' |
  grep '^ultramarine-release' | grep -v '^ultramarine-release-identity' | head -1 || true)
detect_target_spin

TARGET_USER="${SUDO_USER:-}"
if [[ -z $TARGET_USER || $TARGET_USER == root ]]; then
  TARGET_USER=$(logname 2>/dev/null || true)
fi
if [[ -z $TARGET_USER || $TARGET_USER == root ]]; then
  TARGET_USER=$(getent passwd 1000 2>/dev/null | cut -d: -f1 || true)
fi
if [[ -n $TARGET_USER ]]; then
  TARGET_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)
fi

if [[ $IS_UM -eq 1 ]]; then
  log "Ultramarine packages detected."
else
  log "No Ultramarine release packages detected; branding cleanup will still run."
fi
log "Detected desktop edition: $DESKTOP_NAME"
log "Target Fedora spin: $FEDORA_SPIN ($RELEASE_PKG / $IDENTITY_PKG)"

AVAIL_ROOT=$(df -Pk / | awk 'NR==2 {print $4}')
AVAIL_BOOT=$(df -Pk /boot | awk 'NR==2 {print $4}')
(( AVAIL_ROOT >= 15 * 1024 * 1024 )) || abort "Less than 15 GiB free on /; the Fedora $LATEST download needs about 7 GiB plus install space."
(( AVAIL_BOOT >= 500 * 1024 )) || abort "Less than 500 MiB free on /boot."
log "Free space: / $((AVAIL_ROOT / 1024 / 1024)) GiB, /boot $((AVAIL_BOOT / 1024)) MiB"

if [[ -n $TARGET_HOME ]] && grep -RIl -E '/usr/share/(wallpapers/Ultramarine|backgrounds/ultramarine)' \
    "$TARGET_HOME/.config" 2>/dev/null | grep -q .; then
  log "A wallpaper config points at the Ultramarine wallpaper; it will be switched to the Fedora default."
fi

# DNF command used for every transaction.  Ultramarine and Terra repositories
# are disabled while they exist so $releasever=45 can never trigger an
# Ultramarine/Terra 45 key prompt.  build_dnf() is called again after those
# repository files are removed.
build_dnf

section "Refreshing Fedora $LATEST metadata"
run "${DNF_TARGET[@]}" --refresh makecache || abort "Could not refresh Fedora $LATEST repository metadata."

section "Checking Fedora $LATEST packages"
for p in \
  "$RELEASE_PKG" \
  "$IDENTITY_PKG" \
  fedora-release-common \
  fedora-logos \
  desktop-backgrounds-compat \
  fedora-bookmarks \
  fedora-appstream-metadata; do
  target_pkg_exists "$p" || abort "Fedora $LATEST package not found: $p"
done
log "All required Fedora $LATEST packages are available."

# Pin the upgrade to the detected spin.  Fedora release packages satisfy their
# identity/variant requirements through capability provides, so without this
# the solver is free to switch editions.  On an unconverted Ultramarine system
# it picked Budgie during testing.
mapfile -t VARIANT_PROVIDERS < <(
  "${DNF_TARGET[@]}" repoquery --qf '%{name}\n' --whatprovides=fedora-release-variant 2>/dev/null |
    grep '^fedora-release' | sort -u
)
mapfile -t IDENTITY_PROVIDERS < <(
  "${DNF_TARGET[@]}" repoquery --qf '%{name}\n' --whatprovides=fedora-release-identity 2>/dev/null |
    grep '^fedora-release' | sort -u
)
printf '%s\n' "${VARIANT_PROVIDERS[@]}" | grep -qx "$RELEASE_PKG" ||
  abort "Fedora $LATEST does not provide the $DESKTOP_NAME release variant ($RELEASE_PKG)."
printf '%s\n' "${IDENTITY_PROVIDERS[@]}" | grep -qx "$IDENTITY_PKG" ||
  abort "Fedora $LATEST does not provide the $DESKTOP_NAME release identity ($IDENTITY_PKG)."

for p in "${VARIANT_PROVIDERS[@]}"; do
  if [[ $p != "$RELEASE_PKG" ]]; then
    VARIANT_EXCLUDES+=(--exclude="$p")
  fi
done
for p in "${IDENTITY_PROVIDERS[@]}"; do
  if [[ $p != "$IDENTITY_PKG" ]]; then
    VARIANT_EXCLUDES+=(--exclude="$p")
  fi
done
if ((${#VARIANT_EXCLUDES[@]})); then
  DNF_TARGET+=("${VARIANT_EXCLUDES[@]}")
  log "Pinned Fedora $LATEST to $DESKTOP_NAME (${#VARIANT_EXCLUDES[@]} other variant packages excluded)."
fi

# ---------------------------------------------------------------------------
# Dry runs
# ---------------------------------------------------------------------------
section "Dry runs"

SWAP_FROM=${UM_IDENTITY:-$UM_RELEASE_PKG}
if (( IS_UM )) && [[ -n $SWAP_FROM ]]; then
  run_capture "$WORK_DIR/sim-release.log" \
    "${DNF[@]}" swap --allowerasing --assumeno "$SWAP_FROM" "$RELEASE_PKG" || true
  check_txn "$WORK_DIR/sim-release.log" || abort "The Ultramarine -> Fedora release swap cannot be resolved."
  show_txn_summary "$WORK_DIR/sim-release.log"
fi

if rpm -q ultramarine-backgrounds-compat >/dev/null 2>&1; then
  run_capture "$WORK_DIR/sim-backgrounds.log" \
    "${DNF[@]}" swap --allowerasing --assumeno ultramarine-backgrounds-compat desktop-backgrounds-compat || true
  check_txn "$WORK_DIR/sim-backgrounds.log" || abort "The background package swap cannot be resolved."
  show_txn_summary "$WORK_DIR/sim-backgrounds.log"
fi

mapfile -t PATCHED_PKGS < <(patched_packages)
if ((${#PATCHED_PKGS[@]})); then
  log "Branded packages with Fedora builds will be replaced:"
  printf '  %s\n' "${PATCHED_PKGS[@]}" | tee -a "$LOG"
  run_capture "$WORK_DIR/sim-patched.log" \
    "${DNF[@]}" distro-sync --allowerasing --from-repo=fedora,updates --assumeno "${PATCHED_PKGS[@]}" || true
  check_txn "$WORK_DIR/sim-patched.log" || abort "The branded package replacement cannot be resolved."
  show_txn_summary "$WORK_DIR/sim-patched.log"
fi

if (( CURRENT < LATEST )); then
  run_capture "$WORK_DIR/sim-target-upgrade.log" \
    "${DNF_TARGET[@]}" upgrade --allowerasing --assumeno || true
  check_txn "$WORK_DIR/sim-target-upgrade.log" || abort "The Fedora $LATEST upgrade cannot be resolved from the current system."
  show_txn_summary "$WORK_DIR/sim-target-upgrade.log"
  if ! grep -qE "${RELEASE_PKG}[[:space:]]+noarch[[:space:]]+0:${LATEST}-" \
      "$WORK_DIR/sim-target-upgrade.log"; then
    abort "The Fedora $LATEST pre-conversion upgrade plan does not select $RELEASE_PKG."
  fi
  log "The pre-conversion dry run is pinned to the Fedora $DESKTOP_NAME variant."
fi

if ! rpm -qa gpg-pubkey --qf '%{SUMMARY}\n' | grep -q "Fedora ($LATEST)"; then
  log "Fedora $LATEST signing key is not imported yet; the run will import it before downloading."
fi

if [[ $MODE == check ]]; then
  section "Check complete"
  log "No changes were made."
  log "Current Fedora base: $CURRENT; latest stable Fedora: $LATEST."
  log "Preflight and dry runs passed."
  exit 0
fi

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
if (( ASSUME_YES == 0 )); then
  section "Confirmation"
  cat <<EOF | tee -a "$LOG"
This will:
  1. Replace the Ultramarine release packages with the Fedora $DESKTOP_NAME packages.
  2. Remove Ultramarine and Terra repositories and packages.
  3. Replace Ultramarine/Terra-patched packages with Fedora builds where one exists.
  4. Keep RPM Fusion and your third-party applications (Steam, VLC, VS Code, etc.).
  5. Download Fedora Linux $LATEST for an offline upgrade.
  6. Switch wallpaper configs that point at the Ultramarine wallpaper to the Fedora default.

A backup of /etc, /boot/loader/entries, GRUB config, package lists and affected
user config files will be saved under /var/backups/deultramarify-$TIMESTAMP/.

EOF
  read -r -p "Continue? [y/N] " ans </dev/tty || ans=n
  [[ $ans =~ ^[Yy]$ ]] || { log "Aborted."; exit 1; }
fi

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
section "Backing up"
BACKUP_DIR="/var/backups/deultramarify-$TIMESTAMP"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

backup_tar "$BACKUP_DIR/etc.tar.gz" -C / etc
if [[ -d /boot/loader/entries ]]; then
  backup_tar "$BACKUP_DIR/boot-entries.tar.gz" -C / boot/loader/entries
fi
if [[ -f /boot/grub2/grub.cfg ]]; then
  cp -a /boot/grub2/grub.cfg "$BACKUP_DIR/grub.cfg"
fi
cp -a /etc/skel "$BACKUP_DIR/skel"
if [[ -n $TARGET_HOME && -d $TARGET_HOME/.config ]]; then
  while IFS= read -r f; do
    rel=${f#"$TARGET_HOME/"}
    mkdir -p "$BACKUP_DIR/home/$(dirname "$rel")"
    cp -a "$f" "$BACKUP_DIR/home/$rel"
  done < <(grep -RIl -E '/usr/share/(wallpapers/Ultramarine|backgrounds/ultramarine)' \
    "$TARGET_HOME/.config" 2>/dev/null)
fi
if [[ -f /usr/lib/os-release ]]; then
  cp -a /usr/lib/os-release "$BACKUP_DIR/usr-lib-os-release"
fi
if [[ -f /usr/lib/ultramarine-release ]]; then
  cp -a /usr/lib/ultramarine-release "$BACKUP_DIR/usr-lib-ultramarine-release"
fi
readlink -f /etc/os-release >"$BACKUP_DIR/etc-os-release-target.txt" 2>/dev/null || true

rpm -qa --qf '%{NAME}-%{EVR}.%{ARCH}|%{VENDOR}|%{PACKAGER}\n' >"$BACKUP_DIR/rpm-qa.txt"
dnf repolist --all >"$BACKUP_DIR/dnf-repolist.txt" 2>&1 || true
rpm -qa gpg-pubkey --qf '%{NAME}-%{VERSION}-%{RELEASE}|%{SUMMARY}\n' >"$BACKUP_DIR/rpm-gpg-keys.txt"
flatpak remotes >"$BACKUP_DIR/flatpak-remotes.txt" 2>&1 || true
df -hT >"$BACKUP_DIR/df.txt" 2>&1 || true
lsblk -f >"$BACKUP_DIR/lsblk.txt" 2>&1 || true
findmnt -R / >"$BACKUP_DIR/findmnt.txt" 2>&1 || true
efibootmgr -v >"$BACKUP_DIR/efibootmgr.txt" 2>&1 || true
log "Backup written to $BACKUP_DIR"

# ---------------------------------------------------------------------------
# Signing key
# ---------------------------------------------------------------------------
section "Fedora $LATEST signing key"
if ! rpm -qa gpg-pubkey --qf '%{SUMMARY}\n' | grep -q "Fedora ($LATEST)"; then
  if [[ -f /etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-$LATEST-primary ]]; then
    run rpm --import "/etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-$LATEST-primary"
  else
    run curl -fsSL --max-time 30 https://fedoraproject.org/fedora.gpg -o "$WORK_DIR/fedora.gpg"
    run rpm --import "$WORK_DIR/fedora.gpg"
  fi
fi
rpm -qa gpg-pubkey --qf '%{SUMMARY}\n' | grep -q "Fedora ($LATEST)" || \
  abort "Fedora $LATEST signing key is still missing."

# ---------------------------------------------------------------------------
# Release swap
# ---------------------------------------------------------------------------
if (( IS_UM )); then
  section "Converting Ultramarine release packages to Fedora"
  if [[ -n $SWAP_FROM ]]; then
    run "${DNF[@]}" swap --allowerasing "$SWAP_FROM" "$RELEASE_PKG"
  else
    run "${DNF[@]}" install --allowerasing "$RELEASE_PKG" "$IDENTITY_PKG"
  fi
else
  section "Ensuring Fedora release packages"
  run "${DNF[@]}" install "$RELEASE_PKG" "$IDENTITY_PKG"
fi

grep -q '^ID=fedora' /etc/os-release || abort "/etc/os-release does not identify as Fedora after the release swap."
rpm -q "$RELEASE_PKG" fedora-release-common "$IDENTITY_PKG" >/dev/null || \
  abort "One or more Fedora release packages are missing after the release swap."
log "Fedora release packages installed."

# ---------------------------------------------------------------------------
# Backgrounds
# ---------------------------------------------------------------------------
section "Replacing Ultramarine backgrounds"
if rpm -q ultramarine-backgrounds-compat >/dev/null 2>&1; then
  run "${DNF[@]}" swap --allowerasing ultramarine-backgrounds-compat desktop-backgrounds-compat
  run "${DNF[@]}" upgrade desktop-backgrounds-compat
else
  run "${DNF[@]}" install desktop-backgrounds-compat
fi
rpm -q desktop-backgrounds-compat >/dev/null || abort "desktop-backgrounds-compat is not installed."

# ---------------------------------------------------------------------------
# Patched packages
# ---------------------------------------------------------------------------
section "Replacing branded packages with Fedora builds"
mapfile -t PATCHED_PKGS < <(patched_packages)
if ((${#PATCHED_PKGS[@]})); then
  log "Replacing with Fedora builds:"
  printf '  %s\n' "${PATCHED_PKGS[@]}" | tee -a "$LOG"
  run "${DNF[@]}" distro-sync --allowerasing --from-repo=fedora,updates "${PATCHED_PKGS[@]}"
  for p in "${PATCHED_PKGS[@]}"; do
    if rpm -q --qf '%{VENDOR}|%{RELEASE}\n' "$p" 2>/dev/null | \
       grep -qE 'Ultramarine|Terra|\.um[0-9]+'; then
      abort "Package $p is still an Ultramarine/Terra build after distro-sync."
    fi
  done
else
  log "No branded packages have Fedora replacements."
fi

# ---------------------------------------------------------------------------
# Remove Ultramarine and Terra packages
# ---------------------------------------------------------------------------
section "Removing Ultramarine and Terra packages"

mapfile -t REMOVE_PKGS < <(branded_packages)
if ((${#REMOVE_PKGS[@]})); then
  log "Packages to remove:"
  printf '  %s\n' "${REMOVE_PKGS[@]}" | tee -a "$LOG"
  run "${DNF[@]}" remove --no-autoremove "${REMOVE_PKGS[@]}"
else
  log "No Ultramarine/Terra packages to remove."
fi

LEFTOVERS=$(branded_packages)
if [[ -n $LEFTOVERS ]]; then
  abort "Ultramarine/Terra packages remain: $LEFTOVERS"
fi

# Safety net: removing an Ultramarine theme must not cascade into the Fedora
# desktop stack.  Abort here rather than download an upgrade to a broken
# desktop.  The list of critical packages follows the detected spin.
for p in "$RELEASE_PKG" fedora-release-common "$IDENTITY_PKG" "${CRITICAL_DESKTOP_PKGS[@]}"; do
  [[ -n $p ]] || continue
  rpm -q "$p" >/dev/null 2>&1 || \
    abort "Critical package $p is missing after the removal transaction."
done

# The repo packages were just removed, so their .repo files may already be
# gone.  Remove any remaining Ultramarine/Terra repository files now, before
# the next DNF command, and rebuild the DNF command without --disablerepo
# options for repositories that no longer exist.
clean_repo_files
build_dnf
log "Repository files cleaned; DNF command rebuilt."

# ---------------------------------------------------------------------------
# Fedora extras
# ---------------------------------------------------------------------------
section "Installing Fedora branding extras"
run "${DNF[@]}" install fedora-bookmarks fedora-appstream-metadata fedora-logos desktop-backgrounds-compat
for p in "$RELEASE_PKG" "$IDENTITY_PKG" fedora-release-common \
         fedora-logos fedora-bookmarks fedora-appstream-metadata desktop-backgrounds-compat; do
  rpm -q "$p" >/dev/null || abort "Missing Fedora package after conversion: $p"
done

# ---------------------------------------------------------------------------
# Repo/key/branding cleanup
# ---------------------------------------------------------------------------
section "Cleaning Ultramarine/Terra files"

remove_file \
  /etc/ultramarine-release \
  /usr/lib/ultramarine-release \
  /etc/debuginfod/ultramarine.urls \
  /etc/logrotate.d/ultramarine-logrotate.conf \
  /etc/profile.d/ultramarine-shell.sh \
  /usr/lib/systemd/system-preset/89-ultramarine-default.preset

for f in /etc/anaconda/profile.d/ultramarine-*.conf \
         /etc/pki/rpm-gpg/RPM-GPG-KEY-um* \
         /etc/pki/rpm-gpg/RPM-GPG-KEY-ultramarine* \
         /etc/pki/rpm-gpg/RPM-GPG-KEY-terra* \
         /etc/pki/rpm-gpg/RPM-GPG-KEY-fyralabs*; do
  if [[ -e $f || -L $f ]]; then
    remove_file "$f"
  fi
done

for d in /etc/com.fyralabs.Taidan /usr/share/taidan /usr/share/ultramarine-shell-config \
         /usr/share/backgrounds/ultramarine-linux; do
  if [[ -d $d ]]; then
    find "$d" -depth -type d -empty -delete 2>/dev/null || true
    if [[ -d $d ]]; then
      log "NOTE: leftover directory $d contains files; inspect manually."
    fi
  fi
done

for d in /usr/share/plasma/look-and-feel/org.ultramarine-linux.ultramarine.desktop; do
  if [[ -d $d ]]; then
    log "NOTE: leftover theme directory $d contains files; inspect manually."
  fi
done

# Remove imported Ultramarine/Terra RPM signing keys.
mapfile -t BAD_KEYS < <(
  rpm -qa gpg-pubkey --qf '%{NAME}-%{VERSION}-%{RELEASE}|%{SUMMARY}\n' |
    grep -E 'Ultramarine|Terra' | cut -d'|' -f1
)
if ((${#BAD_KEYS[@]})); then
  run rpm -e "${BAD_KEYS[@]}"
fi
if rpm -qa gpg-pubkey --qf '%{SUMMARY}\n' | grep -q -E 'Ultramarine|Terra'; then
  abort "Ultramarine/Terra RPM signing keys are still imported."
fi

run fc-cache -f >/dev/null 2>&1 || true
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  run gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Wallpaper
# ---------------------------------------------------------------------------
section "Updating wallpaper references"
fix_user_wallpaper "$TARGET_USER" "$TARGET_HOME"

# ---------------------------------------------------------------------------
# /etc/skel
# ---------------------------------------------------------------------------
section "Cleaning Ultramarine shell references from /etc/skel"
for f in /etc/skel/.bashrc /etc/skel/.zshrc; do
  [[ -f $f ]] || continue
  grep -q -E 'Ultramarine|starship init' "$f" || continue
  cp -a "$f" "$BACKUP_DIR/skel-$(basename "$f")"
  sed -i -E \
    -e '/^# Ultramarine .* config$/d' \
    -e '/^# initialize starship$/d' \
    -e '/^eval "\$\(starship init (bash|zsh)\)"$/d' \
    "$f"
  log "Removed Ultramarine/starship lines from $f"
done
if grep -q -E 'Ultramarine|starship init' /etc/skel/.bashrc /etc/skel/.zshrc 2>/dev/null; then
  abort "Ultramarine/starship lines remain in /etc/skel."
fi

# ---------------------------------------------------------------------------
# GRUB / BLS titles
# ---------------------------------------------------------------------------
section "Updating GRUB and boot entry titles"
if [[ -d /boot/loader/entries ]]; then
  for f in /boot/loader/entries/*.conf; do
    [[ -e $f ]] || continue
    if grep -q '^title Ultramarine' "$f"; then
      sed -i -E 's/^title Ultramarine Linux/title Fedora Linux/; s/^title Ultramarine/title Fedora Linux/' "$f"
      log "Updated boot entry title in $f"
    fi
    if grep -qi '^grub_class[[:space:]]\+ultramarine' "$f"; then
      sed -i -E 's/^grub_class[[:space:]]+ultramarine[[:space:]]*$/grub_class fedora/I' "$f"
      log "Updated grub_class in $f"
    fi
  done
fi

if [[ -f /boot/grub2/grub.cfg ]]; then
  cp -a /boot/grub2/grub.cfg "$BACKUP_DIR/grub.cfg.before-mkconfig"
fi
run grub2-mkconfig -o /boot/grub2/grub.cfg
chmod 644 /boot/grub2/grub.cfg 2>/dev/null || true

if grep -rqi 'ultramarine' /boot/loader/entries /boot/grub2/grub.cfg 2>/dev/null; then
  log "NOTE: an 'ultramarine' string is still present in the boot configuration; inspect manually."
fi

# ---------------------------------------------------------------------------
# Final conversion verification
# ---------------------------------------------------------------------------
section "Final Fedora conversion verification"
grep -E '^(NAME|VERSION_ID|ID|VARIANT_ID|PRETTY_NAME)=' /etc/os-release | tee -a "$LOG"
grep -q '^ID=fedora' /etc/os-release || abort "Final /etc/os-release is not Fedora."
grep -q "^VARIANT_ID=$TARGET_VARIANT_ID" /etc/os-release || \
  abort "Final /etc/os-release is not the Fedora $DESKTOP_NAME variant (expected VARIANT_ID=$TARGET_VARIANT_ID)."

for cap in system-release fedora-release-variant fedora-release-identity \
           system-logos system-backgrounds-compat system-bookmarks; do
  provider=$(rpm -q --whatprovides "$cap" 2>/dev/null | head -1 || true)
  log "$cap -> ${provider:-MISSING}"
  [[ -n $provider ]] || abort "No provider for $cap after conversion."
done

VARIANT_PROVIDER=$(rpm -q --whatprovides fedora-release-variant 2>/dev/null | head -1 || true)
[[ $VARIANT_PROVIDER == "$RELEASE_PKG"-* ]] || \
  abort "fedora-release-variant is provided by '$VARIANT_PROVIDER', not $RELEASE_PKG."

if dnf repolist --all 2>/dev/null | grep -qiE 'ultramarine|terra'; then
  abort "Ultramarine/Terra repositories are still enabled."
fi
if grep -ril -E 'ultramarine|taidan|fyralabs' /etc/yum.repos.d 2>/dev/null | grep -q .; then
  abort "Ultramarine/Terra repository files still exist."
fi

# ---------------------------------------------------------------------------
# Upgrade plan verification (post-conversion)
# ---------------------------------------------------------------------------
if (( CURRENT < LATEST )); then
  section "Verifying Fedora $LATEST upgrade plan"
  POST_SIM="$WORK_DIR/sim-post-upgrade.log"
  run_capture "$POST_SIM" "${DNF_TARGET[@]}" upgrade --allowerasing --assumeno || true
  check_txn "$POST_SIM" || abort "The Fedora $LATEST upgrade cannot be resolved after conversion."
  show_txn_summary "$POST_SIM"

  if grep -q 'Nothing to do' "$POST_SIM"; then
    log "No upgrade transaction is needed."
  else
    if ! grep -qE "${RELEASE_PKG}[[:space:]]+noarch[[:space:]]+0:${LATEST}-" "$POST_SIM"; then
      abort "The Fedora $LATEST upgrade plan does not select $RELEASE_PKG-$LATEST."
    fi
    if ! grep -qE "${IDENTITY_PKG}[[:space:]]+noarch[[:space:]]+0:${LATEST}-" "$POST_SIM"; then
      abort "The Fedora $LATEST upgrade plan does not select $IDENTITY_PKG-$LATEST."
    fi
    for p in "${VARIANT_PROVIDERS[@]}" "${IDENTITY_PROVIDERS[@]}"; do
      [[ $p == "$RELEASE_PKG" || $p == "$IDENTITY_PKG" ]] && continue
      if grep -qE "(^|[[:space:]])${p}([[:space:]]|$)" "$POST_SIM"; then
        abort "The Fedora $LATEST upgrade plan selects $p instead of $DESKTOP_NAME."
      fi
    done
    log "Upgrade plan uses $RELEASE_PKG-$LATEST / $IDENTITY_PKG-$LATEST."
  fi
fi

# ---------------------------------------------------------------------------
# Download the upgrade
# ---------------------------------------------------------------------------
if (( CURRENT < LATEST )); then
  section "Downloading Fedora $LATEST"
  log "This downloads roughly 7 GiB and can take a while."
  run "${DNF_TARGET[@]}" system-upgrade download --allowerasing
  run "${DNF[@]}" system-upgrade status || true
else
  section "Upgrade download"
  log "The system is already on Fedora $LATEST; skipping the download."
fi

# ---------------------------------------------------------------------------
# Post-upgrade check script
# ---------------------------------------------------------------------------
section "Writing post-upgrade check script"
cat >/root/deultramarify-postcheck.sh <<EOF
#!/usr/bin/env bash
set -uo pipefail
umask 077
LOG=/var/log/deultramarify-postcheck.log
EXPECTED_VARIANT=$TARGET_VARIANT_ID
EXPECTED_RELEASE=$RELEASE_PKG
EXPECTED_IDENTITY=$IDENTITY_PKG
DESKTOP="$DESKTOP_NAME"
exec > >(tee -a "\$LOG") 2>&1
EOF
cat >>/root/deultramarify-postcheck.sh <<'POSTCHECK'

echo "=== deultramarify post-upgrade check: $(date) ==="
echo "--- os-release ---"
grep -E '^(NAME|VERSION|ID|VERSION_ID|PRETTY_NAME|VARIANT_ID)=' /etc/os-release
echo "--- expected spin ---"
printf 'desktop: %s\nvariant: %s (%s / %s)\n' "$DESKTOP" "$EXPECTED_VARIANT" "$EXPECTED_RELEASE" "$EXPECTED_IDENTITY"
rpm -q "$EXPECTED_RELEASE" "$EXPECTED_IDENTITY" 2>&1 || true
echo "--- release providers ---"
for cap in system-release fedora-release-variant fedora-release-identity system-logos system-backgrounds-compat system-bookmarks; do
  printf '%-28s -> ' "$cap"
  rpm -q --whatprovides "$cap" 2>/dev/null | tr '\n' ' '
  echo
done
echo "--- Ultramarine/Terra packages remaining ---"
rpm -qa --qf '%{NAME}|%{VENDOR}|%{RELEASE}\n' |
  awk -F'|' '$2 ~ /Ultramarine|Terra/ || $3 ~ /\.um[0-9]+/ {print}' || true
echo "--- repositories ---"
dnf repolist 2>&1
echo "--- failed systemd units ---"
systemctl --failed --no-pager 2>&1
echo "--- kernel ---"
uname -r
echo "--- boot entries ---"
ls -1 /boot/loader/entries 2>&1
grep -H '^title' /boot/loader/entries/*.conf 2>&1
echo "--- Ultramarine references under /etc ---"
grep -ril -E 'ultramarine|taidan|fyralabs' /etc 2>/dev/null | head -20 || true
echo "--- wallpaper references ---"
grep -RIl -E '/usr/share/(wallpapers/Ultramarine|backgrounds/ultramarine)' /home/*/.config 2>/dev/null | head -20 || true
echo "--- dnf check ---"
dnf check 2>&1 | tail -20
echo "=== done ==="
POSTCHECK
chmod 700 /root/deultramarify-postcheck.sh

# ---------------------------------------------------------------------------
# Finish
# ---------------------------------------------------------------------------
section "Conversion complete"
log "Converted edition: $DESKTOP_NAME -> Fedora $FEDORA_SPIN"
log "Fedora base: $CURRENT"
log "Latest stable Fedora: $LATEST"
log "Backup: $BACKUP_DIR"
log "Log: $LOG"
log "Post-upgrade check: sudo /root/deultramarify-postcheck.sh"
log "RPM Fusion and third-party applications were kept."
log "Terra-only extras (starship, system76-scheduler, extra fonts/udev rules) were removed."
log "UM's BBR/MTU sysctl tweaks were removed; Fedora networking defaults apply."

if (( CURRENT < LATEST )); then
  log "Fedora $LATEST is downloaded and ready for the offline upgrade."
  log "The upgrade runs on the next boot and can take 20-60 minutes. Do not interrupt it."
  if (( ASSUME_YES == 1 )); then
    log "Rebooting now (--yes)."
    run "${DNF[@]}" system-upgrade reboot
  else
    read -r -p "Reboot now to install Fedora $LATEST? [y/N] " ans </dev/tty || ans=n
    if [[ $ans =~ ^[Yy]$ ]]; then
      run "${DNF[@]}" system-upgrade reboot
    else
      log "Not rebooting. When ready, run: sudo dnf system-upgrade reboot"
    fi
  fi
fi
