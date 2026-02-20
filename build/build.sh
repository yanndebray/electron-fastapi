#!/usr/bin/env bash
# build/build.sh — Downloads python-build-standalone and creates the bundled environment.
# Usage: ./build.sh [linux-x86_64 | darwin-x86_64 | darwin-aarch64 | windows-x86_64]

set -euo pipefail

# ---------- config ----------
PYTHON_VERSION="3.12.12"
PYTHON_MINOR="${PYTHON_VERSION%.*}"  # e.g. 3.12 — used for stdlib paths
# Pin a specific release for reproducibility
PBS_RELEASE="20260211"
UV_VERSION="0.5"  # minimum version

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUNDLE_DIR="$SCRIPT_DIR/bundle"

# ---------- detect / override target ----------
TARGET="${1:-}"

if [ -z "$TARGET" ]; then
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)    TARGET="linux-x86_64" ;;
    Linux-aarch64)   TARGET="linux-aarch64" ;;
    Darwin-x86_64)   TARGET="darwin-x86_64" ;;
    Darwin-arm64)    TARGET="darwin-aarch64" ;;
    MINGW*|MSYS*|CYGWIN*) TARGET="windows-x86_64" ;;
    *) echo "Cannot detect platform. Pass target as argument."; exit 1 ;;
  esac
fi

echo "==> Building for target: $TARGET"

# ---------- map target to python-build-standalone artifact ----------
# See: https://github.com/astral-sh/python-build-standalone/releases
case "$TARGET" in
  linux-x86_64)
    PBS_TRIPLE="x86_64-unknown-linux-gnu"
    PBS_VARIANT="install_only_stripped"
    PBS_EXT="tar.gz"
    ;;
  linux-aarch64)
    PBS_TRIPLE="aarch64-unknown-linux-gnu"
    PBS_VARIANT="install_only_stripped"
    PBS_EXT="tar.gz"
    ;;
  darwin-x86_64)
    PBS_TRIPLE="x86_64-apple-darwin"
    PBS_VARIANT="install_only_stripped"
    PBS_EXT="tar.gz"
    ;;
  darwin-aarch64)
    PBS_TRIPLE="aarch64-apple-darwin"
    PBS_VARIANT="install_only_stripped"
    PBS_EXT="tar.gz"
    ;;
  windows-x86_64)
    PBS_TRIPLE="x86_64-pc-windows-msvc"
    PBS_VARIANT="install_only_stripped"
    PBS_EXT="tar.gz"
    ;;
  *)
    echo "Unknown target: $TARGET"; exit 1 ;;
esac

PBS_FILENAME="cpython-${PYTHON_VERSION}+${PBS_RELEASE}-${PBS_TRIPLE}-${PBS_VARIANT}.${PBS_EXT}"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/${PBS_FILENAME}"

# ---------- clean & prepare ----------
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"

# ---------- download & extract python-build-standalone ----------
echo "==> Downloading python-build-standalone…"
echo "    $PBS_URL"

DOWNLOAD_DIR="$SCRIPT_DIR/.cache"
mkdir -p "$DOWNLOAD_DIR"

if [ ! -f "$DOWNLOAD_DIR/$PBS_FILENAME" ]; then
  curl -L --fail -o "$DOWNLOAD_DIR/$PBS_FILENAME" "$PBS_URL"
fi

echo "==> Extracting Python runtime…"
mkdir -p "$BUNDLE_DIR/python-runtime"
tar -xf "$DOWNLOAD_DIR/$PBS_FILENAME" -C "$BUNDLE_DIR/python-runtime" --strip-components=1

# ---------- install dependencies into a portable venv ----------
echo "==> Creating isolated venv and installing dependencies…"

# Use the bundled python to create a venv
PYTHON_BIN="$BUNDLE_DIR/python-runtime/bin/python3"
if [[ "$TARGET" == windows-* ]]; then
  PYTHON_BIN="$BUNDLE_DIR/python-runtime/python.exe"
fi

# Use uv if available (much faster), otherwise fall back to pip
if command -v uv &>/dev/null; then
  echo "    Using uv for dependency installation"

  # Compile requirements to a temp file (avoids process substitution issues on MSYS)
  TEMP_REQUIREMENTS="$BUNDLE_DIR/.tmp-requirements.txt"
  (cd "$PROJECT_ROOT/backend" && uv pip compile pyproject.toml -o "$TEMP_REQUIREMENTS")

  # Create a temporary venv using uv, then install into target
  TEMP_VENV="$BUNDLE_DIR/.tmp-venv"
  uv venv "$TEMP_VENV" --python "$PYTHON_BIN"

  # On Windows the venv Python is at Scripts/python.exe, not bin/python
  if [[ "$TARGET" == windows-* ]]; then
    VENV_PYTHON="$TEMP_VENV/Scripts/python.exe"
  else
    VENV_PYTHON="$TEMP_VENV/bin/python"
  fi

  uv pip install \
    --python "$VENV_PYTHON" \
    -r "$TEMP_REQUIREMENTS" \
    --target "$BUNDLE_DIR/python-venv/site-packages"
  rm -rf "$TEMP_VENV" "$TEMP_REQUIREMENTS"
else
  echo "    Using pip for dependency installation"
  "$PYTHON_BIN" -m pip install \
    --target "$BUNDLE_DIR/python-venv/site-packages" \
    -r "$PROJECT_ROOT/backend/requirements.txt" \
    --no-cache-dir
fi

# ---------- strip unnecessary files to reduce size ----------
echo "==> Pruning unnecessary files…"

# Remove test directories, __pycache__, .pyc files, etc.
find "$BUNDLE_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$BUNDLE_DIR" -type d -name "test" -exec rm -rf {} + 2>/dev/null || true
find "$BUNDLE_DIR" -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
find "$BUNDLE_DIR" -type f -name "*.pyc" -delete 2>/dev/null || true
find "$BUNDLE_DIR" -type f -name "*.pyo" -delete 2>/dev/null || true

# Remove pip/setuptools from the runtime (not needed at runtime)
rm -rf "$BUNDLE_DIR/python-runtime/lib/python${PYTHON_MINOR}/ensurepip"
rm -rf "$BUNDLE_DIR/python-runtime/lib/python${PYTHON_MINOR}/site-packages/pip"
rm -rf "$BUNDLE_DIR/python-runtime/lib/python${PYTHON_MINOR}/site-packages/setuptools"

# Remove tkinter and other large unused stdlib modules
rm -rf "$BUNDLE_DIR/python-runtime/lib/python${PYTHON_MINOR}/tkinter"
rm -rf "$BUNDLE_DIR/python-runtime/lib/python${PYTHON_MINOR}/turtle*"
rm -rf "$BUNDLE_DIR/python-runtime/lib/python${PYTHON_MINOR}/idlelib"

echo "==> Bundle ready at: $BUNDLE_DIR"
echo "    Python runtime: $BUNDLE_DIR/python-runtime"
echo "    Site-packages:  $BUNDLE_DIR/python-venv/site-packages"

# Show size summary
du -sh "$BUNDLE_DIR/python-runtime" "$BUNDLE_DIR/python-venv" "$BUNDLE_DIR"
