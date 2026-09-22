#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# FORGE CV Align — Offline bundle builder
#
# Builds a self-contained linux-64 bundle for air-gapped installs:
#   1. conda env from packaging/environment.yml (conda-forge)
#   2. pip: opencv-python-headless, forge-io, forge-align (non-editable)
#   3. optional SuperPoint: CPU torch + LightGlue, with model weights cached
#      inside the env so nothing is fetched at solve time
#   4. conda-pack the env and wrap it with the installer + hook sources
#
# Run on the oldest target distro (CI uses rockylinux 9.5) so pip picks
# wheels compatible with the target's glibc. Needs network, conda, conda-pack
# and git on PATH.
#
# Usage:
#   bash packaging/build_bundle.sh
#
# Environment:
#   OUT_DIR          output directory              (default: <repo>/dist)
#   VERSION          bundle version label          (default: git describe)
#   WITH_SUPERPOINT  1 = include torch + LightGlue (default: 1)
#   BUILD_PREFIX     scratch env prefix            (default: /tmp/forge-cv-build)
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_DIR/dist}"
WITH_SUPERPOINT="${WITH_SUPERPOINT:-1}"
BUILD_PREFIX="${BUILD_PREFIX:-/tmp/forge-cv-build}"
TORCH_INDEX="https://download.pytorch.org/whl/cpu"
# LightGlue has no releases; pin the commit so bundles are reproducible.
LIGHTGLUE_REF="eb42fee2d71449efb0aa5c10549752b5d75384d8"

if [[ -z "${VERSION:-}" ]]; then
    PKG_VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$REPO_DIR/pyproject.toml")"
    GIT_REV="$(git -C "$REPO_DIR" describe --tags --always --dirty 2>/dev/null || echo unknown)"
    VERSION="${PKG_VERSION}-${GIT_REV}"
fi
BUNDLE_NAME="forge-align-offline-${VERSION}-linux-64"
STAGE="$OUT_DIR/$BUNDLE_NAME"
ENV_PY="$BUILD_PREFIX/bin/python"

echo "=== Building $BUNDLE_NAME ==="

for tool in conda conda-pack git; do
    command -v "$tool" &>/dev/null || { echo "ERR: $tool not on PATH" >&2; exit 1; }
done

# ── 1. Conda env ───────────────────────────────────────────────────
rm -rf "$BUILD_PREFIX"
conda env create -y -p "$BUILD_PREFIX" -f "$REPO_DIR/packaging/environment.yml"

# Keep pip from touching conda-managed numpy (conda-pack refuses envs where
# pip overwrote conda files).
CONSTRAINTS="$BUILD_PREFIX/.pip-constraints.txt"
"$ENV_PY" -c "import numpy; print(f'numpy=={numpy.__version__}')" > "$CONSTRAINTS"
PIP=("$ENV_PY" -m pip install --no-cache-dir -c "$CONSTRAINTS")

# ── 2. forge-align + forge-io + opencv ─────────────────────────────
"${PIP[@]}" "$REPO_DIR"

# ── 3. Optional SuperPoint stack ───────────────────────────────────
if [[ "$WITH_SUPERPOINT" == "1" ]]; then
    # CPU wheels: solver.py only uses mps (macOS) or cpu, so CUDA would be
    # ~3 GB of dead weight.
    "${PIP[@]}" --index-url "$TORCH_INDEX" torch torchvision
    "${PIP[@]}" kornia packaging
    # --no-deps: LightGlue requires opencv-python, which clobbers the
    # headless cv2 install.
    "${PIP[@]}" --no-deps "lightglue @ git+https://github.com/cvg/LightGlue.git@${LIGHTGLUE_REF}"

    # Pre-fetch weights into the env; forge_cv.solver points TORCH_HOME here.
    TORCH_HOME="$BUILD_PREFIX/share/forge-cv/torch" "$ENV_PY" -c "
from lightglue import LightGlue, SuperPoint
SuperPoint(max_num_keypoints=4096)
LightGlue(features='superpoint')
"
    ls -l "$BUILD_PREFIX/share/forge-cv/torch/hub/checkpoints"
fi

# LightGlue's missing opencv-python / matplotlib are intentional (see above).
if ! PIP_CHECK="$("$ENV_PY" -m pip check 2>&1)"; then
    echo "$PIP_CHECK"
    if grep -v '^lightglue ' <<<"$PIP_CHECK" | grep -q .; then
        echo "ERR: pip check found broken requirements" >&2
        exit 1
    fi
fi
rm -f "$CONSTRAINTS"

# ── 4. Verify imports before packing ───────────────────────────────
"$ENV_PY" -c "
import cv2, numpy, OpenImageIO, PyOpenColorIO, forge_io
from forge_cv.solver import solve_alignment
print('cv2', cv2.__version__, '| numpy', numpy.__version__,
      '| OIIO', OpenImageIO.VERSION_STRING, '| OCIO', PyOpenColorIO.__version__)
"
"$BUILD_PREFIX/bin/ffmpeg" -hide_banner -version | head -1

# ── 5. Pack + stage bundle ─────────────────────────────────────────
rm -rf "$STAGE" "$OUT_DIR/$BUNDLE_NAME.tar"*
mkdir -p "$STAGE/env"

conda list -p "$BUILD_PREFIX" --explicit --md5 > "$STAGE/env/conda-explicit.txt"
"$ENV_PY" -m pip freeze > "$STAGE/env/pip-freeze.txt"
conda-pack -p "$BUILD_PREFIX" -o "$STAGE/env/forge-cv-env.tar.gz" -j -1

cp "$REPO_DIR/packaging/install_offline.sh" "$STAGE/"
cp "$REPO_DIR/packaging/smoke_offline.py" "$STAGE/"
cp "$REPO_DIR/packaging/README_OFFLINE.md" "$STAGE/"
# forge_cv/ itself is installed in the env; shipping the source tree too
# would shadow it for anything run from the bundle dir.
cp "$REPO_DIR"/{install.sh,uninstall.sh,README.md} "$STAGE/"
cp -R "$REPO_DIR/scripts" "$STAGE/"
find "$STAGE" -name "__pycache__" -prune -exec rm -rf {} +
echo "$VERSION" > "$STAGE/VERSION"
# conda-pack writes its archive 0600; other users on the target must read it.
chmod -R a+rX "$STAGE"

(cd "$STAGE" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)

# Outer tar is uncompressed: the env inside is already gzipped.
tar -C "$OUT_DIR" -cf "$OUT_DIR/$BUNDLE_NAME.tar" "$BUNDLE_NAME"
(cd "$OUT_DIR" && sha256sum "$BUNDLE_NAME.tar" > "$BUNDLE_NAME.tar.sha256")
rm -rf "$STAGE"

echo ""
ls -lh "$OUT_DIR/$BUNDLE_NAME.tar"
echo "=== Built $OUT_DIR/$BUNDLE_NAME.tar ==="
