#!/usr/bin/env bash
# build.sh - build the crDroid sm8150 (vayu/bhima, Poco X3 Pro) kernel with
# KernelSU-Next (legacy, susfs) re-integrated, on top of your fork of
# crdroidandroid/android_kernel_xiaomi_sm8150.
#
# Run from the kernel repo root (where this ksu-ci/ dir lives).
# Requires: git, python3, make, clang + ld.lld on PATH, bc bison flex cpio
#           zip libssl-dev libelf-dev libncurses-dev
#
# Environment overrides:
#   KSU_REF   ref on the upstream crDroid repo to take KernelSU-Next+susfs
#             from (default: 16.0-ksu). Can be a branch, tag or commit SHA.
#   KSU_LTO   set to "none" to build without LTO (much lower link memory),
#             default keeps the stock crDroid CONFIG_LTO_CLANG=y.
set -euo pipefail

KSU_REF="${KSU_REF:-16.0-ksu}"
UPSTREAM_REPO="https://github.com/crdroidandroid/android_kernel_xiaomi_sm8150"
AK3_REPO="https://github.com/osm0sis/AnyKernel3"
DEFCONFIG="vendor/sm8150-perf_defconfig"
FRAGMENTS=(
  "arch/arm64/configs/vendor/debugfs.config"
  "arch/arm64/configs/vendor/xiaomi/sm8150-common.config"
  "arch/arm64/configs/vendor/xiaomi/vayu.config"
)
CI_DIR="$(cd "$(dirname "$0")" && pwd)"   # ksu-ci/
JOBS="${JOBS:-$(nproc)}"

log() { printf '\033[1;36m>> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
log "Fetching KernelSU-Next + susfs source from crDroid $KSU_REF"
git remote add upstream "$UPSTREAM_REPO" 2>/dev/null || true
git fetch --depth=1 upstream "$KSU_REF"
KSU_SHA="$(git rev-parse FETCH_HEAD)"
echo "KSU ref resolved to: $KSU_SHA"

# ---------------------------------------------------------------------------
log "Taking KernelSU-Next + susfs files wholesale from $KSU_SHA"
git checkout "$KSU_SHA" -- \
  drivers/kernelsu \
  fs/susfs.c \
  include/linux/susfs.h \
  include/linux/susfs_def.h \
  fs/proc/task_mmu.c \
  fs/proc/base.c \
  fs/seq_file.c \
  include/linux/seq_file.h \
  include/linux/pkeys.h

# ---------------------------------------------------------------------------
log "Generating + applying the curated hook patch (fs/*.c, kernel/*.c hooks)"
python3 "$CI_DIR/gen-ksu-patch.py" "$KSU_SHA" > /tmp/ksu-hooks.patch
git apply /tmp/ksu-hooks.patch

log "Applying compatibility patches"
for p in "$CI_DIR"/patches/*.patch; do
  echo "  applying $(basename "$p")"
  git apply "$p"
done

# Commit so the kernel release string stays clean (4.14.357-perf-g<sha>
# instead of ...-dirty), exactly like the official builds.
git add -A
git -c user.name="vayu-ksu-ci" -c user.email="ci@localhost" \
  commit -q -m "Re-integrate KernelSU-Next (legacy) + susfs from crDroid $KSU_REF

Co-authored-by: crDroid sm8150 16.0-ksu ($KSU_SHA)"

# ---------------------------------------------------------------------------
log "Configuring kernel ($DEFCONFIG + fragments)"
make O=out ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- "$DEFCONFIG"
./scripts/kconfig/merge_config.sh -m -O out out/.config "${FRAGMENTS[@]}"
make O=out ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

if [ "${KSU_LTO:-}" = "none" ]; then
  log "KSU_LTO=none -> disabling LTO"
  ./scripts/config --file out/.config -d LTO_CLANG -e LTO_NONE
  make O=out ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
fi

log "Verifying KSU config"
grep -q "^CONFIG_KSU=y" out/.config
grep -q "^CONFIG_KSU_SUSFS=y" out/.config
grep -q "^CONFIG_KSU_MANUAL_HOOK=y" out/.config
echo "CONFIG_KSU / CONFIG_KSU_SUSFS / manual hooks: OK"

if [ "${KSU_SKIP_BUILD:-}" = "1" ]; then
  log "KSU_SKIP_BUILD=1 -> stopping before compilation"
  exit 0
fi

# ---------------------------------------------------------------------------
log "Building Image (this takes ~30-60 min on a GitHub runner)"
make O=out ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- -j"$JOBS" Image

KRELEASE="$(cat out/include/config/kernel.release)"
KSU_GITVER="$(grep -oP 'KSU_GIT_VERSION := \K[0-9]+' drivers/kernelsu/Makefile || true)"
IMAGE="out/arch/arm64/boot/Image"
test -s "$IMAGE"
log "Built: $KRELEASE (KernelSU-Next git version $KSU_GITVER)"

# ---------------------------------------------------------------------------
log "Packaging AnyKernel3 zip"
rm -rf /tmp/anykernel3
git clone --depth=1 "$AK3_REPO" /tmp/anykernel3
rm -rf /tmp/anykernel3/.git /tmp/anykernel3/.github /tmp/anykernel3/README.md
cp "$CI_DIR/anykernel.sh" /tmp/anykernel3/anykernel.sh
cp "$IMAGE" /tmp/anykernel3/
mkdir -p artifacts
( cd /tmp/anykernel3 && zip -qr9 "$OLDPWD/artifacts/AnyKernel3-$KRELEASE-vayu-KSUNext-susfs.zip" . -x "*.git*" )

cp "$IMAGE" "artifacts/Image-$KRELEASE"

{
  echo "kernel release : $KRELEASE"
  echo "kernel repo    : $(git remote get-url origin) @ $(git rev-parse HEAD)"
  echo "ksu source ref : $KSU_SHA (crDroid 16.0-ksu, KernelSU-Next legacy+susfs)"
  echo "ksu git version: $KSU_GITVER"
  echo "built with     : $(clang --version | head -1)"
  echo "built on       : $(date -u)"
} > artifacts/build-info.txt

log "Artifacts:"
ls -la artifacts/
