#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# End-to-end test of an offline bundle. Meant to run as root in a Rocky
# Linux container started with `--network none` and conda on PATH (see
# .github/workflows/offline-bundle.yml):
#
#   1. install into conda's envs dir with a global hook deploy
#   2. check config, hook, `conda env list`, and that SuperPoint weights
#      come from the env (nothing written to ~/.cache/torch)
#   3. uninstall.sh removes hook, config and env
#   4. install again with --prefix + --project, then self-test from there
#
# Usage: bash packaging/test_bundle.sh path/to/forge-align-offline-*.tar
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

BUNDLE_TAR="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
WORK="$(mktemp -d)"
GLOBAL_HOOK="/opt/Autodesk/shared/python/forge_cv_align/forge_cv_align.py"
CONFIG="$HOME/.forge/config.yaml"

step() { echo ""; echo "=== $* ==="; }
fail() { echo "FAIL: $*" >&2; exit 1; }
config_python() { sed -n 's/^conda_python: *//p' "$CONFIG"; }

step "Network is unreachable"
if timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null; then
    fail "network reachable — this test must run air-gapped"
fi
echo "ok"

step "Extract bundle"
tar -xf "$BUNDLE_TAR" -C "$WORK"
BUNDLE_DIR="$(echo "$WORK"/forge-align-offline-*)"
ls -la "$BUNDLE_DIR" "$BUNDLE_DIR/env"

step "Install into conda envs dir, global deploy"
bash "$BUNDLE_DIR/install_offline.sh" --env forge-cv --global < /dev/null
cat "$CONFIG"
PY="$(config_python)"
[[ "$PY" == "$(conda info --base)/envs/forge-cv/bin/python"* ]] || fail "conda_python=$PY"
[[ -f "$GLOBAL_HOOK" ]] || fail "hook not deployed to $GLOBAL_HOOK"
conda env list | grep -q "^forge-cv " || fail "env not visible to conda"
[[ ! -e "$HOME/.cache/torch" ]] || fail "torch downloaded into ~/.cache/torch"

step "Solve from the installed env (outside the bundle dir)"
(cd / && "$PY" "$BUNDLE_DIR/smoke_offline.py")

step "Uninstall"
printf 'y\n' | bash "$BUNDLE_DIR/uninstall.sh"
[[ ! -e "$GLOBAL_HOOK" ]] || fail "hook still present"
[[ ! -e "$CONFIG" ]] || fail "config still present"
! conda env list | grep -q "^forge-cv " || fail "env still present"

step "Install with --prefix + --project"
PROJECT="$WORK/flame_project"
mkdir -p "$PROJECT/setups"
bash "$BUNDLE_DIR/install_offline.sh" --prefix /opt/forge-cv-alt --project "$PROJECT" \
    --skip-smoke < /dev/null
[[ "$(config_python)" == /opt/forge-cv-alt/bin/python* ]] || fail "conda_python=$(config_python)"
[[ -f "$PROJECT/setups/python/forge_cv_align/forge_cv_align.py" ]] || fail "project hook missing"
(cd / && /opt/forge-cv-alt/bin/python "$BUNDLE_DIR/smoke_offline.py")

step "All bundle tests passed"
