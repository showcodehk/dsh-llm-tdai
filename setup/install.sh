#!/usr/bin/env bash
#
# Install the dsh-llm-tdai plugin into a DSH profile.
#
#   curl -fsSL https://raw.githubusercontent.com/showcodehk/dsh-llm-tdai/main/setup/install.sh | bash
#
# Options (environment variables):
#   DSH_PROFILE        profile to install into           (default: desktop)
#   DSH_BIN            path to the dsh CLI               (default: auto-detect)
#   DSH_LLM_TDAI_URL   download URL for the tarball      (default: latest release)
#   DSH_LLM_TDAI_PKG   local tarball, skips the download (for offline installs)
#
set -euo pipefail

# Where the release lives. Moving hosts means editing this block only - the three
# install commands stay identical.
HOST="https://github.com"
OWNER="showcodehk"
REPO="dsh-llm-tdai"
PACKAGE="dsh-llm-tdai"

# The `latest/download` alias is a permanent URL: it resolves to the asset of the
# newest non-draft, non-prerelease release. That is why the published asset keeps
# the same name in every release - the alias matches the name exactly, so a
# version-carrying name would change the URL on every bump.
URL="${DSH_LLM_TDAI_URL:-${HOST}/${OWNER}/${REPO}/releases/latest/download/${PACKAGE}.tgz}"

PROFILE="${DSH_PROFILE:-desktop}"
# Fixed name on disk so the recorded `file:` dependency never dangles when a new
# version appears; re-installs overwrite it in place.
CACHE_NAME="${PACKAGE}.tgz"

# A self-signed host needs the check skipped. Off by default; GitHub does not
# need it, so this only matters for a mirrored or internal staging deployment.
CURL_FLAGS="-fsSL"
if [ "${DSH_LLM_TDAI_INSECURE:-0}" = "1" ]; then
  CURL_FLAGS="$CURL_FLAGS -k"
fi

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

WGET_FLAGS="-q"
if [ "${DSH_LLM_TDAI_INSECURE:-0}" = "1" ]; then
  WGET_FLAGS="$WGET_FLAGS --no-check-certificate"
fi

# fetch_to <url> [outfile] - stdout when no outfile is given.
fetch_to() {
  if command -v curl >/dev/null 2>&1; then
    if [ -n "${2:-}" ]; then curl $CURL_FLAGS "$1" -o "$2"; else curl $CURL_FLAGS "$1"; fi
  elif command -v wget >/dev/null 2>&1; then
    if [ -n "${2:-}" ]; then wget $WGET_FLAGS "$1" -O "$2"; else wget $WGET_FLAGS "$1" -O -; fi
  else
    die "curl or wget is required"
  fi
}

# The CLI ships inside the desktop app; prefer whatever is already on PATH.
find_dsh() {
  if [ -n "${DSH_BIN:-}" ]; then
    [ -x "$DSH_BIN" ] || die "DSH_BIN is set but not executable: $DSH_BIN"
    printf '%s' "$DSH_BIN"
    return 0
  fi
  if command -v dsh >/dev/null 2>&1; then
    command -v dsh
    return 0
  fi
  for candidate in \
    "/Applications/DeepSeekHarness.app/Contents/Resources/runtime/cli/bin/dsh" \
    "$HOME/Applications/DeepSeekHarness.app/Contents/Resources/runtime/cli/bin/dsh" \
    "$HOME/.local/share/deepseek-harness/runtime/cli/bin/dsh" \
    "/opt/deepseek-harness/runtime/cli/bin/dsh"
  do
    if [ -x "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

DSH=$(find_dsh) || die "dsh CLI not found. Add it to PATH, or set DSH_BIN=/path/to/dsh."

# Quit the app first: `--profile` refuses to run while the desktop host is open.
if pgrep -f "DeepSeekHarness" >/dev/null 2>&1; then
  say "Quit DeepSeekHarness completely (including the tray icon), then run this again."
  die "the desktop host is still running"
fi

# The profile records a `file:` dependency pointing at wherever the tarball
# lived, so it must outlive this script. A fixed cache path also keeps re-installs
# predictable; a temp directory would be deleted and break the next pnpm run.
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
CACHE="${DSH_LLM_TDAI_CACHE:-$DSH_HOME/.plugin-cache}"
mkdir -p "$CACHE"
TGZ="$CACHE/$CACHE_NAME"

if [ -n "${DSH_LLM_TDAI_PKG:-}" ]; then
  say "using local package: $DSH_LLM_TDAI_PKG"
  if [ "$DSH_LLM_TDAI_PKG" != "$TGZ" ]; then
    cp "$DSH_LLM_TDAI_PKG" "$TGZ" || die "cannot read $DSH_LLM_TDAI_PKG"
  fi
else
  say "downloading $URL"
  fetch_to "$URL" "$TGZ" || die "download failed: $URL"
fi

[ -s "$TGZ" ] || die "downloaded file is empty: $TGZ"

# Removing first keeps re-installs honest: pnpm matches a `file:` dependency by
# path + version, so re-adding the same asset would report "Already up to date"
# and leave the previous copy in place.
say "removing any previous copy"
"$DSH" plugin --profile "$PROFILE" remove "$PACKAGE" >/dev/null 2>&1 || true

# `remove` leaves a symlink behind when the package was installed from a
# directory; pnpm does not clean it up.
STALE="$DSH_HOME/profiles/$PROFILE/node_modules/$PACKAGE"
if [ -e "$STALE" ] || [ -L "$STALE" ]; then
  rm -rf "$STALE"
fi

say "installing into profile '$PROFILE'"
"$DSH" plugin --profile "$PROFILE" add "$TGZ"

say ""
say "done. Start DeepSeekHarness and pick the provider that routes to your memory proxy."
say "If the provider name or routing changed, check the profile config first."
