#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# FORGE CV Align — Offline installer
#
# Unpacks the prebuilt conda env shipped in this bundle (no network), runs
# a self-test, then hands off to install.sh to deploy the Flame hook and
# write ~/.forge/config.yaml.
#
# Usage:
#   bash install_offline.sh                          # env "forge-cv", interactive deploy
#   bash install_offline.sh --global                 # deploy to /opt/Autodesk/shared/python
#   bash install_offline.sh --env myenv --global
#   bash install_offline.sh --prefix /opt/forge-cv --project /path/to/flame/project
#
# Any option not listed below is passed through to install.sh.
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_ARCHIVE="$BUNDLE_DIR/env/forge-cv-env.tar.gz"
DEFAULT_ENV="forge-cv"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}OK${NC}  $*"; }
warn() { echo -e "  ${YELLOW}!!${NC}  $*"; }
err()  { echo -e "  ${RED}ERR${NC} $*"; }
info() { echo -e "  ${CYAN}--${NC}  $*"; }

# ── Parse args ─────────────────────────────────────────────────────
ENV_NAME=""
PREFIX=""
FORCE=""
SKIP_SMOKE=""
PASSTHROUGH=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)        ENV_NAME="$2"; shift 2 ;;
        --prefix)     PREFIX="$2";   shift 2 ;;
        --force)      FORCE="yes";   shift ;;
        --skip-smoke) SKIP_SMOKE="yes"; shift ;;
        -h|--help)
            echo "Usage: bash install_offline.sh [OPTIONS] [install.sh OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --env NAME        Env name under conda's envs dir (default: $DEFAULT_ENV)"
            echo "  --prefix DIR      Unpack the env to DIR instead (conda not required)"
            echo "  --force           Replace an existing env at the target location"
            echo "  --skip-smoke      Skip the post-install alignment self-test"
            echo ""
            echo "Passed through to install.sh:"
            echo "  --global          Deploy hook globally (/opt/Autodesk/shared/python)"
            echo "  --project PATH    Deploy to a Flame project (repeatable)"
            exit 0 ;;
        *)  PASSTHROUGH+=("$1"); shift ;;
    esac
done

echo ""
echo -e "${CYAN}=== FORGE CV Align — Offline Install ($(cat "$BUNDLE_DIR/VERSION" 2>/dev/null || echo unknown)) ===${NC}"
echo ""

# ── Verify bundle ──────────────────────────────────────────────────
if [[ "$(uname -s)-$(uname -m)" != "Linux-x86_64" ]]; then
    err "This bundle is for linux x86_64 (got $(uname -s) $(uname -m))"
    exit 1
fi
if [[ ! -f "$ENV_ARCHIVE" ]]; then
    err "Env archive not found: $ENV_ARCHIVE"
    exit 1
fi
if command -v sha256sum &>/dev/null && [[ -f "$BUNDLE_DIR/SHA256SUMS" ]]; then
    info "Verifying bundle checksums..."
    if (cd "$BUNDLE_DIR" && sha256sum --quiet -c SHA256SUMS); then
        ok "Checksums match"
    else
        err "Checksum mismatch — bundle is corrupt or was modified"
        exit 1
    fi
fi

# ── Resolve target prefix ──────────────────────────────────────────
if [[ -n "$PREFIX" && -n "$ENV_NAME" ]]; then
    err "Use --env or --prefix, not both"
    exit 1
fi
if [[ -z "$PREFIX" ]]; then
    ENV_NAME="${ENV_NAME:-$DEFAULT_ENV}"
    if ! command -v conda &>/dev/null; then
        err "conda not found. Activate Anaconda first, or pass --prefix DIR."
        exit 1
    fi
    # First writable conda envs dir (a root-owned Anaconda base falls back
    # to ~/.conda/envs), so `conda activate NAME` finds it afterwards.
    CONDA_BASE="$(conda info --base)"
    for d in "$CONDA_BASE/envs" "$HOME/.conda/envs"; do
        if mkdir -p "$d" 2>/dev/null && [[ -w "$d" ]]; then
            PREFIX="$d/$ENV_NAME"
            break
        fi
    done
    if [[ -z "$PREFIX" ]]; then
        err "No writable conda envs directory found; pass --prefix DIR"
        exit 1
    fi
fi
mkdir -p "$(dirname "$PREFIX")"
PREFIX="$(cd "$(dirname "$PREFIX")" && pwd)/$(basename "$PREFIX")"

if [[ -e "$PREFIX" ]]; then
    if [[ -n "$FORCE" ]]; then
        warn "Replacing existing env at $PREFIX"
        rm -rf "$PREFIX"
    else
        err "$PREFIX already exists (use --force to replace it)"
        exit 1
    fi
fi

# ── Unpack env ─────────────────────────────────────────────────────
info "Unpacking env to $PREFIX..."
mkdir -p "$PREFIX"
tar -xzf "$ENV_ARCHIVE" -C "$PREFIX"
# Rewrites the build-time prefix baked into scripts/shebangs/text files.
"$PREFIX/bin/python" "$PREFIX/bin/conda-unpack"
ok "Env unpacked"

PYTHON="$PREFIX/bin/python"
if "$PYTHON" -c "import forge_io, cv2, OpenImageIO, PyOpenColorIO; from forge_cv.solver import solve_alignment" 2>/dev/null; then
    ok "forge_io + forge_cv imports OK"
else
    err "Import check failed:"
    "$PYTHON" -c "import forge_io, cv2, OpenImageIO, PyOpenColorIO; from forge_cv.solver import solve_alignment"
    exit 1
fi
if "$PYTHON" -c "import torch; from lightglue import SuperPoint" 2>/dev/null; then
    ok "SuperPoint deps present (torch + lightglue, CPU)"
fi

# ── Self-test ──────────────────────────────────────────────────────
if [[ -z "$SKIP_SMOKE" ]]; then
    info "Running alignment self-test..."
    if "$PYTHON" "$BUNDLE_DIR/smoke_offline.py"; then
        ok "Self-test passed"
    else
        err "Self-test failed — see output above"
        exit 1
    fi
fi

# ── Hand off to install.sh for hook deploy + config ────────────────
echo ""
exec bash "$BUNDLE_DIR/install.sh" --python "$PYTHON" ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
