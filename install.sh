#!/usr/bin/env bash
# forgeplan installer
# Usage:
#   ./install.sh              Install to /usr/local
#   ./install.sh --prefix ~   Install to ~/bin and ~/share/forgeplan
#   ./install.sh --uninstall  Remove forgeplan
#   ./install.sh --check-deps Check dependencies only
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PREFIX="/usr/local"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="install"
REMOTE_INSTALL=false
REPO_URL="https://github.com/tamzid958/forgeplan.git"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)     PREFIX="${2:?--prefix requires a path}"; shift 2 ;;
    --uninstall)  ACTION="uninstall"; shift ;;
    --check-deps) ACTION="check_deps"; shift ;;
    --help|-h)
      echo "Usage: ./install.sh [--prefix <path>] [--uninstall] [--check-deps]"
      echo ""
      echo "  --prefix <path>   Install location (default: /usr/local)"
      echo "  --uninstall       Remove forgeplan"
      echo "  --check-deps      Check dependencies only"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

BINDIR="${PREFIX}/bin"
DATADIR="${PREFIX}/share/forgeplan"

# ---------------------------------------------------------------------------
# Check dependencies
# ---------------------------------------------------------------------------
check_deps() {
  local platform
  platform="$(uname -s)"
  echo "Checking dependencies..."
  echo "  Platform: ${platform} ($(uname -m))"

  # Platform check
  case "$platform" in
    Linux|Darwin)
      echo "  ✅ Supported platform"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      echo "  ❌ Native Windows is not supported"
      echo "     Use WSL: wsl --install"
      echo "     Or Docker: docker build -t forgeplan ."
      exit 1
      ;;
    *)
      echo "  ⚠️  Unknown platform: ${platform} — may work but untested"
      ;;
  esac

  local failed=0

  # Bash version
  local bash_path=""
  for bp in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash; do
    if [[ -x "$bp" ]]; then
      local ver
      ver=$("$bp" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo "0")
      if [[ "$ver" -ge 4 ]]; then
        bash_path="$bp"
        echo "  ✅ bash $("$bp" --version | head -1 | sed 's/.*version //' | cut -d' ' -f1) ($bp)"
        break
      fi
    fi
  done
  if [[ -z "$bash_path" ]]; then
    echo "  ❌ bash >= 4.0 required"
    if [[ "$(uname)" == "Darwin" ]]; then
      echo "     Fix: brew install bash"
    else
      echo "     Fix: apt install bash  or  yum install bash"
    fi
    failed=1
  fi

  # Helper for platform-specific install hints
  _fix_hint() {
    local tool="$1"
    if [[ "$platform" == "Darwin" ]]; then
      echo "     Fix: brew install ${tool}"
    else
      echo "     Fix: apt install ${tool}  or  yum install ${tool}"
    fi
  }

  # curl
  if command -v curl > /dev/null 2>&1; then
    echo "  ✅ curl $(curl --version 2>/dev/null | head -1 | cut -d' ' -f2)"
  else
    echo "  ❌ curl not found"
    _fix_hint curl
    failed=1
  fi

  # jq
  if command -v jq > /dev/null 2>&1; then
    echo "  ✅ jq $(jq --version 2>&1)"
  else
    echo "  ❌ jq not found"
    _fix_hint jq
    failed=1
  fi

  # git
  if command -v git > /dev/null 2>&1; then
    echo "  ✅ git $(git --version | cut -d' ' -f3)"
  else
    echo "  ❌ git not found"
    _fix_hint git
    failed=1
  fi

  # Claude Code (optional at install time)
  if command -v claude > /dev/null 2>&1; then
    echo "  ✅ claude (found)"
  else
    echo "  ⚠️  claude not found (required at runtime)"
    echo "     Fix: npm install -g @anthropic-ai/claude-code"
    if [[ "$platform" == "Darwin" ]]; then
      echo "      or: brew install claude-code"
    fi
  fi

  if [[ $failed -eq 1 ]]; then
    echo ""
    echo "Some required dependencies are missing. Install them and try again."
    exit 1
  fi

  echo ""
  echo "All required dependencies found."
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
do_install() {
  check_deps

  echo ""

  # Fall back to ~/.local if default /usr/local isn't writable
  if [[ "$PREFIX" == "/usr/local" ]] && ! mkdir -p "${BINDIR}" "${DATADIR}/lib" 2>/dev/null; then
    echo "⚠️  Cannot write to /usr/local, falling back to ~/.local"
    PREFIX="${HOME}/.local"
    BINDIR="${PREFIX}/bin"
    DATADIR="${PREFIX}/share/forgeplan"
  fi

  echo "Installing forgeplan to ${PREFIX}..."

  if ! mkdir -p "${BINDIR}" "${DATADIR}/lib" 2>/dev/null; then
    echo ""
    echo "ERROR: Permission denied writing to ${PREFIX}." >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  1. Run with sudo:          sudo ./install.sh" >&2
    echo "  2. Install to home dir:    ./install.sh --prefix ~/.local" >&2
    exit 1
  fi

  # Copy main script with install dir embedded
  sed "s|FP_INSTALL_DIR=__INSTALL_DIR__|FP_INSTALL_DIR=${DATADIR}|" \
    "${SCRIPT_DIR}/forgeplan.sh" > "${BINDIR}/forgeplan"
  chmod +x "${BINDIR}/forgeplan"

  # Copy library modules
  cp "${SCRIPT_DIR}"/lib/*.sh "${DATADIR}/lib/"

  # Copy templates and examples
  cp "${SCRIPT_DIR}"/prompt.template*.md "${DATADIR}/" 2>/dev/null || true
  cp "${SCRIPT_DIR}/.env.example" "${DATADIR}/"
  cp "${SCRIPT_DIR}/forgeplan.config.json.example" "${DATADIR}/"
  cp "${SCRIPT_DIR}/VERSION" "${DATADIR}/"

  echo ""
  echo "✅ forgeplan installed to ${BINDIR}/forgeplan"

  # Check if BINDIR is on PATH
  if ! echo "$PATH" | tr ':' '\n' | grep -qx "${BINDIR}"; then
    echo ""
    echo "⚠️  ${BINDIR} is not on your PATH. Add it:"
    echo "   echo 'export PATH=\"${BINDIR}:\$PATH\"' >> ~/.$(basename "$SHELL")rc"
  fi

  echo ""
  echo "Next steps:"
  echo "  cd /path/to/your-project"
  echo "  forgeplan --init-project    # interactive setup"
  echo "  forgeplan --init            # map OpenProject statuses"
  echo "  forgeplan --doctor          # verify everything works"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
do_uninstall() {
  echo "Uninstalling forgeplan from ${PREFIX}..."

  if [[ -f "${BINDIR}/forgeplan" ]]; then
    rm -f "${BINDIR}/forgeplan"
    echo "  Removed ${BINDIR}/forgeplan"
  else
    echo "  ${BINDIR}/forgeplan not found (already removed?)"
  fi

  if [[ -d "${DATADIR}" ]]; then
    rm -rf "${DATADIR}"
    echo "  Removed ${DATADIR}/"
  else
    echo "  ${DATADIR}/ not found (already removed?)"
  fi

  echo ""
  echo "✅ forgeplan uninstalled"
  echo "   Per-project files (.env, forgeplan.config.json) are NOT removed."
}

# ---------------------------------------------------------------------------
# Remote install: clone repo to temp dir if script is piped or not in repo
# ---------------------------------------------------------------------------
setup_script_dir() {
  if [[ ! -f "${SCRIPT_DIR}/forgeplan.sh" ]]; then
    REMOTE_INSTALL=true
    local tmpdir
    tmpdir="$(mktemp -d)"
    echo "Downloading forgeplan..."
    git clone --depth 1 "${REPO_URL}" "${tmpdir}" 2>/dev/null
    SCRIPT_DIR="${tmpdir}"
  fi
}

cleanup_remote() {
  if [[ "$REMOTE_INSTALL" == true && -d "$SCRIPT_DIR" ]]; then
    rm -rf "$SCRIPT_DIR"
  fi
}

# ---------------------------------------------------------------------------
# Route
# ---------------------------------------------------------------------------
setup_script_dir
trap cleanup_remote EXIT

case "$ACTION" in
  install)    do_install ;;
  uninstall)  do_uninstall ;;
  check_deps) check_deps ;;
esac
