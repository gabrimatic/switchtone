#!/usr/bin/env bash
#
# Installs the latest Switchtone release.
#   curl -fsSL https://raw.githubusercontent.com/gabrimatic/switchtone/main/install.sh | bash
#
# Downloads the release zip, checks its SHA-256 against the release's SHA256SUMS.txt, verifies the app,
# installs it to /Applications and opens it. Nothing else is touched.
#
# Options:
#   --no-open  install without opening the app
#   --help
# Environment:
#   SWITCHTONE_VERSION      install this version (for example 1.0.0) instead of the latest
#   SWITCHTONE_INSTALL_DIR  install here instead of /Applications
#   SWITCHTONE_BASE_URL     where releases are served (default: GitHub releases of gabrimatic/switchtone)

set -euo pipefail

REPO="gabrimatic/switchtone"
BUNDLE_ID="info.gabrimatic.switchtone"
BASE_URL="${SWITCHTONE_BASE_URL:-https://github.com/$REPO/releases/download}"
MIN_MACOS=26
OPEN_APP=true

BOLD=$'\033[1m'; RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'
if [[ ! -t 1 ]]; then BOLD=""; RED=""; GREEN=""; NC=""; fi

say()  { printf '%s\n' "$*"; }
fail() { printf '\n%sInstall stopped.%s %s\n' "$RED" "$NC" "$1" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: install.sh [--no-open]

Installs the latest Switchtone release to /Applications after checking its SHA-256.

  --no-open            install without opening the app

Environment:
  SWITCHTONE_VERSION      install this version (for example 1.0.0) instead of the latest
  SWITCHTONE_INSTALL_DIR  install here instead of /Applications
  SWITCHTONE_BASE_URL     where releases are served (default: GitHub releases of gabrimatic/switchtone)
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN_APP=false ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $arg (try --help)" ;;
  esac
done

say ""
say "${BOLD}Switchtone installer${NC}"

# --- This Mac ---

[[ "$(uname -s)" == "Darwin" ]] || fail "Switchtone is a macOS app. This is $(uname -s)."

# hw.optional.arm64 is 1 on Apple silicon even when this shell runs under Rosetta.
[[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" == "1" ]] \
  || fail "Switchtone needs a Mac with Apple silicon (M1 or later). This Mac has an Intel processor."

MACOS_VERSION="$(sw_vers -productVersion)"
[[ "${MACOS_VERSION%%.*}" =~ ^[0-9]+$ ]] || fail "Could not read the macOS version (got '$MACOS_VERSION')."
(( ${MACOS_VERSION%%.*} >= MIN_MACOS )) \
  || fail "Switchtone needs macOS $MIN_MACOS or later. This Mac runs macOS $MACOS_VERSION. Update macOS, then run this again."

for tool in curl shasum ditto codesign awk; do
  command -v "$tool" >/dev/null 2>&1 || fail "'$tool' is missing. It ships with macOS; check that /usr/bin is on your PATH."
done

if [[ -n "${SWITCHTONE_INSTALL_DIR:-}" ]]; then
  INSTALL_DIR="${SWITCHTONE_INSTALL_DIR%/}"
  [[ -d "$INSTALL_DIR" ]] || fail "$INSTALL_DIR does not exist."
  [[ -w "$INSTALL_DIR" ]] || fail "$INSTALL_DIR is not writable for this user."
elif [[ -w /Applications ]]; then
  INSTALL_DIR="/Applications"
else
  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR" || fail "/Applications is not writable and $INSTALL_DIR could not be created."
  say "/Applications is not writable for this user, so Switchtone goes to $INSTALL_DIR."
fi

# --- Version ---

VERSION="${SWITCHTONE_VERSION:-}"
VERSION="${VERSION#v}"
if [[ -z "$VERSION" ]]; then
  # /releases/latest redirects to /releases/tag/v<version>; reading the redirect needs no API token and no jq.
  LATEST="$(curl -sSL --retry 3 -o /dev/null -w '%{http_code} %{url_effective}' "https://github.com/$REPO/releases/latest")" \
    || fail "Could not reach GitHub to find the latest release. Check your connection, or set SWITCHTONE_VERSION."
  LATEST_URL="${LATEST#* }"
  VERSION="${LATEST_URL##*/tag/v}"
  if [[ "${LATEST%% *}" != "200" || "$LATEST_URL" != */tag/v* || ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "There is no published release to install (GitHub answered ${LATEST%% *}). Build from source instead: see the README."
  fi
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "'$VERSION' is not a version like 1.0.0."

ZIP_NAME="Switchtone-$VERSION.zip"
SUMS_NAME="SHA256SUMS.txt"
RELEASE_URL="$BASE_URL/v$VERSION"

say "Installing Switchtone $VERSION to $INSTALL_DIR"

# --- Download and verify ---

WORK="$(mktemp -d)"
STAGED=""
cleanup() {
  rm -rf "$WORK"
  [[ -z "$STAGED" ]] || rm -rf "$STAGED"
}
trap cleanup EXIT

curl -fsSL --retry 3 -o "$WORK/$ZIP_NAME" "$RELEASE_URL/$ZIP_NAME" \
  || fail "Could not download $RELEASE_URL/$ZIP_NAME. Check your connection, and that release $VERSION exists."
curl -fsSL --retry 3 -o "$WORK/$SUMS_NAME" "$RELEASE_URL/$SUMS_NAME" \
  || fail "Could not download $RELEASE_URL/$SUMS_NAME. Without the checksum list the download cannot be verified."

EXPECTED="$(awk -v f="$ZIP_NAME" '$2 == f { print $1 }' "$WORK/$SUMS_NAME")"
[[ "$EXPECTED" =~ ^[0-9a-f]{64}$ ]] || fail "$SUMS_NAME has no valid entry for $ZIP_NAME."
ACTUAL="$(shasum -a 256 "$WORK/$ZIP_NAME" | awk '{ print $1 }')"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  fail "SHA-256 mismatch for $ZIP_NAME.
  expected $EXPECTED
  got      $ACTUAL
The download is damaged or has been changed. Nothing was installed."
fi
say "  SHA-256 verified"

mkdir "$WORK/unpacked"
ditto -x -k "$WORK/$ZIP_NAME" "$WORK/unpacked" || fail "Could not unpack $ZIP_NAME."
NEW_APP="$WORK/unpacked/Switchtone.app"
[[ -d "$NEW_APP" ]] || fail "$ZIP_NAME does not contain Switchtone.app. Nothing was installed."
codesign --verify --strict --deep "$NEW_APP" 2>/dev/null || fail "Switchtone.app in the download has a broken signature. Nothing was installed."
FOUND_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NEW_APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$FOUND_ID" == "$BUNDLE_ID" ]] || fail "The app in the download is not Switchtone (bundle id '$FOUND_ID'). Nothing was installed."

# --- Install ---

DEST="$INSTALL_DIR/Switchtone.app"

# Quit the copy that is about to be replaced. Another copy elsewhere is left alone.
for pid in $(pgrep -x Switchtone 2>/dev/null || true); do
  if [[ "$(ps -p "$pid" -o comm= 2>/dev/null)" == "$DEST/Contents/MacOS/Switchtone" ]]; then
    say "  Quitting the running Switchtone"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    if kill -0 "$pid" 2>/dev/null; then fail "Switchtone did not quit. Quit it from its menu, then run this again."; fi
  fi
done

STAGED="$INSTALL_DIR/.Switchtone.app.installing"
rm -rf "$STAGED"
ditto "$NEW_APP" "$STAGED" || fail "Could not copy Switchtone into $INSTALL_DIR."

# Swap in two moves, so the old copy comes back if the new one cannot be put in place.
OLD=""
if [[ -e "$DEST" ]]; then
  OLD="$INSTALL_DIR/.Switchtone.app.old"
  rm -rf "$OLD"
  mv "$DEST" "$OLD" || fail "Could not replace $DEST. Quit Switchtone and try again."
fi
if ! mv "$STAGED" "$DEST"; then
  [[ -z "$OLD" ]] || mv "$OLD" "$DEST"
  fail "Could not move Switchtone into place. The previous copy, if any, was put back."
fi
STAGED=""
[[ -z "$OLD" ]] || rm -rf "$OLD"
say "  Installed $DEST"

# Register the app and its Control Center control with the system now, not at the next login.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
pluginkit -a "$DEST/Contents/PlugIns/SwitchtoneControls.appex" >/dev/null 2>&1 || true

if [[ "$OPEN_APP" == true ]]; then
  open "$DEST" || fail "Installed, but could not open Switchtone. Open it from $INSTALL_DIR."
  say "  Opened Switchtone"
fi

say ""
if [[ "$OPEN_APP" == true ]]; then
  say "${GREEN}Done.${NC} Switchtone is open. Its welcome window asks for Input Monitoring, the one permission it needs."
else
  say "${GREEN}Done.${NC} Switchtone is in $INSTALL_DIR."
fi
say "To remove Switchtone later, see the Uninstall section of the README."
