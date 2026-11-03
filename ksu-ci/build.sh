#!/usr/bin/env bash
# build.sh - build the crDroid sm8150 (vayu/bhima, Poco X3 Pro) kernel with
# KernelSU-Next (+ susfs) re-integrated, on top of your fork of
# crdroidandroid/android_kernel_xiaomi_sm8150.
#
# Run from the kernel repo root (where this ksu-ci/ dir lives).
# Requires: git, python3, make, clang + ld.lld + the llvm-* binutils on PATH,
#           bc bison flex cpio zip libssl-dev libelf-dev libncurses-dev
#
# Environment overrides:
#   KSU_REF        ref on the upstream crDroid repo to take the hook patch,
#                  the susfs files and (in vendored mode) KernelSU-Next from
#                  (default: 16.0-ksu). Can be a branch, tag or commit SHA.
#   KSU_SOURCE     "vendored" (default) = use the KernelSU-Next snapshot that
#                  crDroid ships in KSU_REF (v3.2.0-era, KSU version 33281,
#                  full susfs support).
#                  "latest" = replace drivers/kernelsu with the KernelSU-Next
#                  `legacy` branch (the actively maintained in-tree /
#                  manual-hook line; newer core, KSU version ~33320+).
#                  NOTE: the legacy branch has no susfs integration, so susfs
#                  is force-disabled in this mode.
#   KSU_COMMIT     when KSU_SOURCE=latest: pin to a specific commit on the
#                  KernelSU-Next legacy branch (default: branch head).
#   KSU_SUSFS_MODE "with" | "without" | "both" (default: "with").
#                  Ignored (forced to "without") when KSU_SOURCE=latest.
#   KSU_LTO        "full" (default) = keep the stock crDroid CONFIG_LTO_CLANG=y
#                  full-LTO config (the vmlinux.o link needs LOTS of memory -
#                  on GitHub's 16 GB runners the workflow adds a big swap
#                  file for exactly this reason).
#                  "thin" = keep LTO but switch to CONFIG_THINLTO=y: nearly
#                  the same optimization, dramatically lower link memory and
#                  much faster linking.
#                  "none" = build without LTO (what previously built fine
#                  when the full-LTO link was OOM-killed).
set -euo pipefail

KSU_REF="${KSU_REF:-16.0-ksu}"
KSU_SOURCE="${KSU_SOURCE:-vendored}"
KSU_SUSFS_MODE="${KSU_SUSFS_MODE:-with}"
UPSTREAM_REPO="https://github.com/crdroidandroid/android_kernel_xiaomi_sm8150"
KSU_NEXT_REPO="https://github.com/KernelSU-Next/KernelSU-Next"
KSU_NEXT_BRANCH="legacy"
AK3_REPO="https://github.com/osm0sis/AnyKernel3"
DEFCONFIG="vendor/sm8150-perf_defconfig"
FRAGMENTS=(
  "arch/arm64/configs/vendor/debugfs.config"
  "arch/arm64/configs/vendor/xiaomi/sm8150-common.config"
  "arch/arm64/configs/vendor/xiaomi/vayu.config"
)
CI_DIR="$(cd "$(dirname "$0")" && pwd)"   # ksu-ci/
JOBS="${JOBS:-$(nproc)}"
kmake() { make O="$1" ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- "${@:2}"; }

log() { printf '\033[1;36m>> %s\033[0m\n' "$*"; }

case "$KSU_SOURCE" in
  vendored|latest) ;;
  *) echo "KSU_SOURCE must be 'vendored' or 'latest' (got: $KSU_SOURCE)"; exit 1 ;;
esac
case "$KSU_SUSFS_MODE" in
  with|without|both) ;;
  *) echo "KSU_SUSFS_MODE must be 'with', 'without' or 'both' (got: $KSU_SUSFS_MODE)"; exit 1 ;;
esac

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

# The vendored setuid_hook.c leaves its do_umount label orphaned when
# CONFIG_KSU_SUSFS is off (-Wunused-label is fatal under -Werror); guard
# the label so the with/without-susfs variants build from the same source.
sed -i 's/^do_umount:$/#ifdef CONFIG_KSU_SUSFS\ndo_umount:\n#endif/' \
  drivers/kernelsu/hook/setuid_hook.c

# ---------------------------------------------------------------------------
log "Generating + applying the curated hook patch (fs/*.c, kernel/*.c hooks)"
python3 "$CI_DIR/gen-ksu-patch.py" "$KSU_SHA" > /tmp/ksu-hooks.patch
git apply /tmp/ksu-hooks.patch

log "Applying compatibility patches"
for p in "$CI_DIR"/patches/*.patch; do
  echo "  applying $(basename "$p")"
  git apply "$p"
done

# ---------------------------------------------------------------------------
# KSU_SOURCE=latest: swap the vendored KernelSU-Next snapshot for the
# KernelSU-Next `legacy` branch (same in-tree / manual-hook architecture,
# much newer code). The legacy branch carries no susfs integration, so the
# susfs config stays off in this mode (fs/susfs.c simply is not built).
KSU_DESC="vendored from crDroid $KSU_REF (KernelSU-Next legacy snapshot)"
if [ "$KSU_SOURCE" = "latest" ]; then
  log "Fetching KernelSU-Next upstream '$KSU_NEXT_BRANCH' branch (newer core)"
  KSU_DIR="/tmp/ksu-next-upstream"
  rm -rf "$KSU_DIR"
  git init -q "$KSU_DIR"
  git -C "$KSU_DIR" remote add origin "$KSU_NEXT_REPO"
  # full commit history (needed for the version number) but no blobs;
  # the sparse checkout below then downloads only kernel/
  git -C "$KSU_DIR" fetch -q --filter=blob:none origin "$KSU_NEXT_BRANCH"
  git -C "$KSU_DIR" sparse-checkout set --cone kernel uapi
  git -C "$KSU_DIR" checkout -q FETCH_HEAD
  if [ -n "${KSU_COMMIT:-}" ]; then
    log "Pinning KernelSU-Next to commit $KSU_COMMIT"
    git -C "$KSU_DIR" fetch -q --filter=blob:none origin "$KSU_COMMIT"
    git -C "$KSU_DIR" checkout -q "$KSU_COMMIT"
  fi
  KSU_UP_SHA="$(git -C "$KSU_DIR" rev-parse HEAD)"
  KSU_UP_SHORT="$(git -C "$KSU_DIR" rev-parse --short HEAD)"
  KSU_UP_DATE="$(git -C "$KSU_DIR" log -1 --format=%cd --date=short)"
  # ksuver = 30000 + commit count + 289 (the legacy branch offset, see its
  # Kbuild) - must be pinned because our vendored copy has no .git
  KSU_UP_COUNT="$(git -C "$KSU_DIR" rev-list --count HEAD)"
  KSU_UP_VER="$((30000 + KSU_UP_COUNT + 289))"
  echo "KernelSU-Next $KSU_NEXT_BRANCH: $KSU_UP_SHORT ($KSU_UP_DATE), ksuver $KSU_UP_VER"

  log "Replacing drivers/kernelsu with the upstream '$KSU_NEXT_BRANCH' branch"
  rm -rf drivers/kernelsu
  mkdir -p drivers/kernelsu
  cp -a "$KSU_DIR/kernel/." drivers/kernelsu/
  # kernel/include/uapi is a symlink to the repo-root uapi/ dir - vendor it
  # as a real directory so the copied tree is self-contained
  rm -f drivers/kernelsu/include/uapi
  cp -a "$KSU_DIR/uapi" drivers/kernelsu/include/uapi
  # 4.14-CAF compat: this tree already has __poll_t backported in
  # include/uapi/linux/types.h, while event_queue.h defines it when
  # LINUX_VERSION_CODE < 4.16 -> typedef clash. Drop ours when the kernel
  # already provides it.
  if grep -qs "typedef.*__poll_t" include/uapi/linux/types.h include/linux/types.h; then
    sed -i '/^typedef unsigned int __poll_t;$/d' drivers/kernelsu/infra/event_queue.h
  fi
  # pin the reported version (the Kbuild would fall back to version 1 without
  # a .git dir; KSU_VERSION_OVERRIDE/KSU_VERSION_TAG_OVERRIDE are its official
  # integrator hooks)
  {
    echo "# Vendored snapshot pin - added by ksu-ci build.sh"
    echo "KSU_VERSION_OVERRIDE := $KSU_UP_VER"
    echo "KSU_VERSION_TAG_OVERRIDE := $KSU_NEXT_BRANCH-$KSU_UP_SHORT"
    echo ""
    cat drivers/kernelsu/Kbuild
  } > /tmp/ksu-kbuild.tmp
  mv /tmp/ksu-kbuild.tmp drivers/kernelsu/Kbuild
  KSU_DESC="KernelSU-Next $KSU_NEXT_BRANCH @ $KSU_UP_SHORT (ksuver $KSU_UP_VER)"
fi

# Commit so the kernel release string stays clean (4.14.357-perf-g<sha>
# instead of ...-dirty), exactly like the official builds.
git add -A
git -c user.name="vayu-ksu-ci" -c user.email="ci@localhost" \
  commit -q -m "Re-integrate KernelSU-Next + susfs

KernelSU-Next: $KSU_DESC
Co-authored-by: crDroid sm8150 16.0-ksu ($KSU_SHA)"

# ---------------------------------------------------------------------------
# Which susfs variants to build
if [ "$KSU_SOURCE" = "latest" ] && [ "$KSU_SUSFS_MODE" != "without" ]; then
  log "WARNING: KSU_SOURCE=latest has no susfs integration;"
  log "         requested '$KSU_SUSFS_MODE' is downgraded to 'without'."
  log "         (upstream dropped the KSU-side susfs code from the legacy"
  log "          branch; use KSU_SOURCE=vendored for susfs builds)"
  KSU_SUSFS_MODE="without"
fi
case "$KSU_SUSFS_MODE" in
  with)    VARIANTS="susfs" ;;
  without) VARIANTS="nosusfs" ;;
  both)    VARIANTS="susfs nosusfs" ;;
esac
log "Building variant(s): $VARIANTS (KSU: $KSU_DESC)"

mkdir -p artifacts
rm -f artifacts/Image-* artifacts/AnyKernel3-*.zip artifacts/build-info.txt
touch artifacts/build-info.txt

for VARIANT in $VARIANTS; do
  OUT="out-$VARIANT"
  # =========================================================================
  log "[$VARIANT] Configuring kernel ($DEFCONFIG + fragments)"
  rm -rf "$OUT"
  kmake "$OUT" "$DEFCONFIG"
  ./scripts/kconfig/merge_config.sh -m -O "$OUT" "$OUT/.config" "${FRAGMENTS[@]}"
  kmake "$OUT" olddefconfig

  if [ "$VARIANT" = "nosusfs" ]; then
    log "[$VARIANT] Disabling CONFIG_KSU_SUSFS (plain KernelSU-Next build)"
    ./scripts/config --file "$OUT/.config" -d KSU_SUSFS
    kmake "$OUT" olddefconfig
  fi

  case "${KSU_LTO:-full}" in
    full)
      # stock crDroid config: CONFIG_LTO_CLANG=y, CONFIG_THINLTO not set
      ;;
    thin)
      log "[$VARIANT] KSU_LTO=thin -> enabling CONFIG_THINLTO (lighter LTO link)"
      ./scripts/config --file "$OUT/.config" -e THINLTO
      kmake "$OUT" olddefconfig
      grep -q '^CONFIG_THINLTO=y' "$OUT/.config" \
        || { echo "FATAL: CONFIG_THINLTO could not be enabled"; exit 1; }
      ;;
    none)
      log "[$VARIANT] KSU_LTO=none -> disabling LTO completely"
      ./scripts/config --file "$OUT/.config" -d LTO_CLANG -e LTO_NONE
      kmake "$OUT" olddefconfig
      ;;
    *)
      echo "KSU_LTO must be 'full', 'thin' or 'none' (got: $KSU_LTO)"; exit 1 ;;
  esac

  log "[$VARIANT] Verifying KSU config"
  grep -q "^CONFIG_KSU=y" "$OUT/.config"
  grep -q "^CONFIG_KSU_MANUAL_HOOK=y" "$OUT/.config"
  if [ "$VARIANT" = "susfs" ]; then
    grep -q "^CONFIG_KSU_SUSFS=y" "$OUT/.config" \
      || { echo "FATAL: CONFIG_KSU_SUSFS is not set for the susfs variant"; exit 1; }
  else
    ! grep -q "^CONFIG_KSU_SUSFS=y" "$OUT/.config" \
      || { echo "FATAL: CONFIG_KSU_SUSFS is still set for the nosusfs variant"; exit 1; }
  fi
  echo "[$VARIANT] CONFIG_KSU / manual hooks / susfs state: OK"

  if [ "${KSU_SKIP_BUILD:-}" = "1" ]; then
    log "[$VARIANT] KSU_SKIP_BUILD=1 -> skipping compilation/packaging for this variant"
    continue
  fi

  # =========================================================================
  log "[$VARIANT] Building Image (this takes ~30-60 min per variant on a GitHub runner)"
  kmake "$OUT" -j"$JOBS" Image

  KRELEASE="$(cat "$OUT/include/config/kernel.release")"
  IMAGE="$OUT/arch/arm64/boot/Image"
  test -s "$IMAGE"
  log "[$VARIANT] Built: $KRELEASE"

  # =========================================================================
  log "[$VARIANT] Packaging AnyKernel3 zip"
  rm -rf /tmp/anykernel3
  git clone --depth=1 "$AK3_REPO" /tmp/anykernel3
  rm -rf /tmp/anykernel3/.git /tmp/anykernel3/.github /tmp/anykernel3/README.md
  cp "$CI_DIR/anykernel.sh" /tmp/anykernel3/anykernel.sh
  cp "$IMAGE" /tmp/anykernel3/
  ( cd /tmp/anykernel3 && zip -qr9 "$OLDPWD/artifacts/AnyKernel3-$KRELEASE-$VARIANT.zip" . -x "*.git*" )

  cp "$IMAGE" "artifacts/Image-$VARIANT"

  {
    echo "=== variant: $VARIANT ==="
    echo "kernel release : $KRELEASE"
    echo "susfs          : $([ "$VARIANT" = susfs ] && echo "enabled (CONFIG_KSU_SUSFS=y)" || echo "disabled")"
    echo "lto            : ${KSU_LTO:-full}"
  } >> artifacts/build-info.txt
done

KSU_GITVER="$(grep -oP 'KSU_GIT_VERSION := \K[0-9]+' drivers/kernelsu/Makefile 2>/dev/null || true)"
if [ -n "$KSU_GITVER" ]; then
  KSU_REPORTED="$((30000 + KSU_GITVER + 150))"
else
  KSU_REPORTED="$(grep -oP 'KSU_VERSION_OVERRIDE := \K[0-9]+' drivers/kernelsu/Kbuild 2>/dev/null || echo "?")"
fi

{
  echo "kernel repo    : $(git remote get-url origin) @ $(git rev-parse HEAD)"
  echo "ksu            : $KSU_DESC"
  echo "ksu version    : $KSU_REPORTED (reported to the manager as ksuver)"
  echo "susfs mode     : $KSU_SUSFS_MODE -> built: $VARIANTS"
  echo "built with     : $(clang --version | head -1)"
  echo "built on       : $(date -u)"
} > /tmp/build-info-main.txt
cat artifacts/build-info.txt /tmp/build-info-main.txt > /tmp/build-info-all.txt
mv /tmp/build-info-all.txt artifacts/build-info.txt

log "Artifacts:"
ls -la artifacts/