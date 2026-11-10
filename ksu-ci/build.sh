#!/usr/bin/env bash
# build.sh - build the crDroid sm8150 (vayu/bhima, Poco X3 Pro) kernel with
# a KernelSU-family root solution re-integrated, on top of your fork of
# crdroidandroid/android_kernel_xiaomi_sm8150.
#
# Run from the kernel repo root (where this ksu-ci/ dir lives).
# Requires: git, python3, make, clang + ld.lld + the llvm-* binutils on PATH,
#           bc bison flex cpio zip libssl-dev libelf-dev libncurses-dev
#
# Environment overrides:
#   KSU_SOURCE     "vendored" (default) = use the KernelSU-Next snapshot that
#                  crDroid ships in KSU_REF (v3.2.0-era, KSU version 33281,
#                  full susfs support).
#                  "latest" = replace drivers/kernelsu with the KernelSU-Next
#                  `legacy` branch (newer core, KSU version ~33320+; the
#                  legacy branch has no susfs integration).
#                  "baka" = Baka-SU (https://github.com/Baka-SU/BakaSU), main
#                  branch, integrated the official way (whole-repo clone at
#                  KernelSU/ + drivers/kernelsu symlink). Manual hooks with
#                  BakaSU's auto-LSM options for setuid/initrc/input; BakaSU's
#                  susfs is a separate hook-method choice, so baka builds are
#                  plain (no susfs). Version is computed from BakaSU's own
#                  git history (30000 + commits + 700).
#                  "sukisu" = SukiSU-Ultra (https://github.com/sukisu-ultra/
#                  sukisu-ultra), `builtin` branch (manual hooks + full
#                  CONFIG_KSU_SUSFS support), pinned by default to commit
#                  75179fc9 (the last classic-hook commit that matches
#                  ksu-ci/patches/sukisu/). susfs variants are supported.
#                  The driver's reported ksuver is pinned to 41150 so it
#                  matches the v4.3.0-r2 manager exactly (their Kbuild
#                  otherwise reports a count of upstream main that drifts
#                  every day and matches no released manager).
#   KSU_REF        ref on the upstream crDroid repo to take the hook patch
#                  base, the susfs kernel files and (in vendored mode) the
#                  KernelSU-Next snapshot from (default: 16.0-ksu).
#   KSU_COMMIT     when KSU_SOURCE=latest/baka/sukisu: pin the SU repo
#                  to a specific commit (empty = branch head for latest/baka,
#                  the verified 75179fc9 pin for sukisu).
#   KSU_SUSFS_MODE "with" | "without" | "both" (default: "with").
#                  Forced to "without" for latest (upstream dropped the
#                  KSU-side susfs code) and for baka (susfs is a separate
#                  hook-method choice there).
#   KSU_LTO        "full" (default) | "thin" | "none" - see below.
#
# Manager-feature note (verified 2026-11-11 against /proc/config.gz and the
# v4.3.0-r2 manager UI): every config the pinned SukiSU-Ultra driver defines
# is ON - all ten CONFIG_KSU_SUSFS_* sub-options plus KSU_FEATURE_ADBROOT -
# and locked by the assert in the per-variant verify block below. There is
# nothing left to enable at config level on this pin. Remaining "unsupported"
# items in the manager, and why:
#   KPM          - by design: needs 5.x APIs, deliberately compiled out on
#                  4.14 (see the sukisu case in the per-SU config knobs)
#   everything   - version skew: the features live in kernel/extension/ and
#   else (hide-    the selinux_hide / mount_hide rework, all of which
#   SELinux, AVC   postdate the 75179fc9 pin. Moving the pin requires
#   spoofing,      rewriting ksu-ci/patches/sukisu/ for the changed sucompat
#   shell-root     hook signatures (faccessat/stat take struct filename **
#   restriction,   under susfs since commit f2201c47) and re-verifying the
#   umount-path    python fixups below - see the SUKI_DEFAULT_PIN comment.
#   mgmt, CPU
#   spoofing,
#   dynamic
#   managers,
#   version
#   overrides,
#   SuSFS console)
#
# Outputs (artifacts/):
#   <SU>_vayu_crDroid17_clang<NN>_<susfs|no-susfs>_<yyyymmdd>.zip
#                  user-facing AnyKernel3 zip (SU = KernelSU-Next / BakaSU /
#                  SukiSU-Ultra) - toolchain and susfs state in the name.
#   Image-<variant>  raw kernel Image (input for the boot.img repack job)
#   build-info.txt   human-readable build summary
#   build-meta.env   machine-readable build facts (SU name, clang version,
#                    build date, file stems) consumed by the workflow's
#                    repack-boot and release jobs.
set -euo pipefail

KSU_REF="${KSU_REF:-16.0-ksu}"
KSU_SOURCE="${KSU_SOURCE:-vendored}"
KSU_SUSFS_MODE="${KSU_SUSFS_MODE:-with}"
KSU_COMMIT="${KSU_COMMIT:-}"
UPSTREAM_REPO="https://github.com/crdroidandroid/android_kernel_xiaomi_sm8150"
KSU_NEXT_REPO="https://github.com/KernelSU-Next/KernelSU-Next"
KSU_NEXT_BRANCH="legacy"
BAKA_REPO="https://github.com/Baka-SU/BakaSU"
BAKA_BRANCH="main"
SUKI_REPO="https://github.com/sukisu-ultra/sukisu-ultra"
SUKI_BRANCH="builtin"
# SukiSU version pin: the driver at SUKI_DEFAULT_PIN predates the
# KERNEL_SU_UAPI_VERSION ioctl, so its Kbuild reports 40000 + the count of
# *upstream main at build time* (and even prefers the GitHub API count) - a
# number that drifts daily and matches no released manager. Pin it instead
# to the ksuver of the manager release this kernel pairs with:
# v4.3.0-r2 = main@3965 -> 40000 + 3965 - 2815 = 41150 (the manager's own
# versionCode; verified against the tag in the cloned repo below).
SUKI_VER_TAG="v4.3.0-r2"
SUKI_VER_EXPECTED="41150"
# SukiSU-Ultra `builtin` pin: 75179fc9 (2026-05-29) is the last commit whose
# manual-hook entry points match ksu-ci/patches/sukisu/ (ksu_handle_execveat,
# ksu_handle_vfs_read, ksu_handle_sys_reboot, ksu_handle_input_handle_event,
# const char __user ** sucompat signatures on 4.14). Newer builtin commits
# renamed the hooks (ksu_handle_execveat_sucompat + struct filename **) and
# do not fit a 4.14 tree without rewriting the call sites.
SUKI_DEFAULT_PIN="75179fc9df5742e7ce0417f63cef4e434e9a3836"
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

# ---------------------------------------------------------------------------
# Build facts: these go into the artifact file names, the recovery
# kernel.string and the release notes, so users can tell builds apart.
CLANG_FULL="$(clang --version | head -n1)"
CLANG_MAJOR="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$CLANG_FULL" | head -n1 | cut -d. -f1 || true)"
[ -n "$CLANG_MAJOR" ] || CLANG_MAJOR="unknown"
BUILD_DATE="$(date -u +%Y%m%d)"
KRELEASE=""
META_STEMS=""

case "$KSU_SOURCE" in
  vendored|latest) SU_NAME="KernelSU-Next" ;;
  baka)            SU_NAME="BakaSU" ;;
  sukisu)          SU_NAME="SukiSU-Ultra" ;;
  *) echo "KSU_SOURCE must be 'vendored', 'latest', 'baka' or 'sukisu' (got: $KSU_SOURCE)"; exit 1 ;;
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
# (the susfs kernel files + fs/proc base files are used by every KSU_SOURCE;
#  drivers/kernelsu gets replaced below for latest/baka/sukisu)
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
# (Only for the KernelSU-Next driver layouts - the fork clones have their
#  own setuid_hook.c which must stay untouched.)
if [ "$KSU_SOURCE" = "vendored" ] || [ "$KSU_SOURCE" = "latest" ]; then
  sed -i 's/^do_umount:$/#ifdef CONFIG_KSU_SUSFS\ndo_umount:\n#endif/' \
    drivers/kernelsu/hook/setuid_hook.c
fi

# ---------------------------------------------------------------------------
log "Generating + applying the curated hook patch (fs/*.c, kernel/*.c hooks)"
python3 "$CI_DIR/gen-ksu-patch.py" "$KSU_SHA" > /tmp/ksu-hooks.patch
# baka/sukisu carry their own manual-hook patches for these files (different
# hook names/signatures), so the KernelSU-Next hook hunks are excluded and
# only the infrastructure/backport hunks are taken (drivers/{Makefile,Kconfig}
# KSU entries, path_umount/cred/seccomp backports, susfs call sites in
# kallsyms/avc/namei/statfs/...).
if [ "$KSU_SOURCE" = "vendored" ] || [ "$KSU_SOURCE" = "latest" ]; then
  git apply /tmp/ksu-hooks.patch
else
  git apply \
    --exclude=fs/exec.c \
    --exclude=fs/open.c \
    --exclude=fs/stat.c \
    --exclude=fs/read_write.c \
    --exclude=kernel/sys.c \
    --exclude=kernel/reboot.c \
    --exclude=drivers/input/input.c \
    /tmp/ksu-hooks.patch
fi

log "Applying compatibility patches"
for p in "$CI_DIR"/patches/[0-9]*.patch; do
  echo "  applying $(basename "$p")"
  git apply "$p"
done
if [ "$KSU_SOURCE" = "vendored" ] || [ "$KSU_SOURCE" = "latest" ]; then
  for p in "$CI_DIR"/patches/ksu-next/*.patch; do
    echo "  applying ksu-next/$(basename "$p")"
    git apply "$p"
  done
elif [ "$KSU_SOURCE" = "baka" ]; then
  for p in "$CI_DIR"/patches/baka/*.patch; do
    echo "  applying baka/$(basename "$p")"
    git apply "$p"
  done
elif [ "$KSU_SOURCE" = "sukisu" ]; then
  for p in "$CI_DIR"/patches/sukisu/*.patch; do
    echo "  applying sukisu/$(basename "$p")"
    git apply "$p"
  done
fi

# ---------------------------------------------------------------------------
# KSU_SOURCE=latest: swap the vendored KernelSU-Next snapshot for the
# KernelSU-Next `legacy` branch (same in-tree / manual-hook architecture,
# much newer code). The legacy branch carries no susfs integration, so the
# susfs config stays off in this mode (fs/susfs.c simply is not built).
KSU_DESC="vendored KernelSU-Next snapshot from crDroid ($KSU_REF)"
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
  KSU_DESC="KernelSU-Next $KSU_NEXT_BRANCH branch @ $KSU_UP_SHORT"
fi

# ---------------------------------------------------------------------------
# KSU_SOURCE=baka / sukisu: integrate the fork the official way - a full
# (blobless, complete history) clone at KernelSU/ plus a drivers/kernelsu
# symlink. Their Kbuild computes the version from the clone's git history,
# so no version pinning is needed here.
if [ "$KSU_SOURCE" = "baka" ] || [ "$KSU_SOURCE" = "sukisu" ]; then
  case "$KSU_SOURCE" in
    baka)    FORK_REPO="$BAKA_REPO"; FORK_BRANCH="$BAKA_BRANCH"; FORK_DEFAULT="main"
             FORK_PIN="${KSU_COMMIT:-}" ;;
    sukisu)  FORK_REPO="$SUKI_REPO"; FORK_BRANCH="$SUKI_BRANCH"; FORK_DEFAULT="main"
             FORK_PIN="${KSU_COMMIT:-$SUKI_DEFAULT_PIN}" ;;
  esac
  log "Fetching $SU_NAME ('$FORK_BRANCH' branch) into KernelSU/"
  rm -rf KernelSU
  git clone -q --filter=blob:none --no-checkout "$FORK_REPO" KernelSU
  # the clone only brings the repo's default branch; fetch the target branch
  # history too when it differs (sukisu's version number counts main, which
  # the clone has)
  if [ "$FORK_BRANCH" != "$FORK_DEFAULT" ]; then
    git -C KernelSU fetch -q --filter=blob:none origin "$FORK_BRANCH"
  fi
  git -C KernelSU sparse-checkout set --cone kernel uapi
  if [ -n "$FORK_PIN" ]; then
    # make sure the pin is available even if it is not on the fetched branch
    git -C KernelSU fetch -q --filter=blob:none origin "$FORK_PIN" || true
    git -C KernelSU checkout -q "$FORK_PIN"
    FORK_DESC="$SU_NAME $FORK_BRANCH @ $(git -C KernelSU rev-parse --short HEAD) (pinned)"
  else
    git -C KernelSU checkout -q "origin/$FORK_BRANCH"
    FORK_DESC="$SU_NAME $FORK_BRANCH @ $(git -C KernelSU rev-parse --short HEAD) (branch head)"
  fi
  # suki's Kbuild counts the *main* branch for its version number - make sure
  # the local 'main' ref exists (it does after the clone; this is just a guard)
  if [ "$KSU_SOURCE" = "sukisu" ]; then
    git -C KernelSU branch -f main origin/main >/dev/null 2>&1 || true
  fi
  echo "$FORK_DESC"

  log "Replacing drivers/kernelsu with a symlink to KernelSU/kernel"
  rm -rf drivers/kernelsu
  ln -s ../KernelSU/kernel drivers/kernelsu
  # sanity: the driver must be reachable through the link
  test -f drivers/kernelsu/Kconfig
  test -f drivers/kernelsu/Makefile || test -f drivers/kernelsu/Kbuild

  # SukiSU-Ultra @ SUKI_DEFAULT_PIN carries an upstream bug in
  # kernel/sulog/event.c: the USER_ARG_NULL compound literal is passed by
  # value, but with CONFIG_KSU_SUSFS the local ksu_sulog_capture() takes
  # 'struct user_arg_ptr *' (without susfs it takes the struct by value,
  # which is the form upstream wrote). Make the call site config-aware so
  # both variants compile; no-op if the pinned commit is changed to one
  # where upstream fixed it (and harmless for BakaSU, which does not ship
  # this file).
  if [ -f KernelSU/kernel/sulog/event.c ] && \
     grep -q "ksu_sulog_capture(KSU_SULOG_EVENT_IOCTL_GRANT_ROOT, NULL, USER_ARG_NULL, gfp);" \
          KernelSU/kernel/sulog/event.c; then
    log "Fixing SukiSU sulog/event.c USER_ARG_NULL call site (config-aware)"
    python3 - <<'PYEOF'
p = "KernelSU/kernel/sulog/event.c"
s = open(p).read()
broken = "    pending = ksu_sulog_capture(KSU_SULOG_EVENT_IOCTL_GRANT_ROOT, NULL, USER_ARG_NULL, gfp);"
fixed = ("#ifdef CONFIG_KSU_SUSFS\n"
         "    pending = ksu_sulog_capture(KSU_SULOG_EVENT_IOCTL_GRANT_ROOT, NULL, &USER_ARG_NULL, gfp);\n"
         "#else\n"
         + broken + "\n"
         "#endif")
assert broken in s, "sulog/event.c: expected buggy call site not found"
open(p, "w").write(s.replace(broken, fixed))
PYEOF
  fi

  # ------------------------------------------------------------------------
  # SukiSU manager-detection fix (ksu-ci):
  #
  # SukiSU installs the manager app's [ksu_driver] fd from the setresuid
  # hook in hook/lsm_hook.c. On susfs builds that is the *syscall* hook
  # (ksu_handle_setresuid, wired into kernel/sys.c by ksu-ci's manual-hooks
  # patch), whose very first check is susfs_is_sid_equal(current_cred(),
  # susfs_zygote_sid) - a cache populated in apply_kernelsu_rules() at the
  # exec of "/system/bin/init second_stage". When that check fails (stale
  # sid cache / fork from a different domain) the manager app is born
  # without its fd, keeps its seccomp filter, and the manager shows
  # "Unsupported - wrong kernel?" while root still works (preview mode).
  # The non-susfs build does not have this problem because it registers the
  # task_fix_setuid LSM hook (fired by commit_creds on every uid change,
  # incl. every zygote fork) - verified working on this device.
  #
  # Fix: also register a manager-only task_fix_setuid LSM hook on susfs
  # builds. If both the syscall hook and the LSM hook fire for the same
  # fork, disable_seccomp() is simply idempotent and the process ends up
  # with a spare fd - harmless. Umount handling stays exclusively in the
  # syscall hook, so it is not done twice.
  if [ "$KSU_SOURCE" = "sukisu" ] && [ -f KernelSU/kernel/hook/lsm_hook.c ]; then
    log "SukiSU: registering task_fix_setuid LSM hook on susfs builds (manager fd install)"
    python3 - <<'PYEOF'
p = "KernelSU/kernel/hook/lsm_hook.c"
s = open(p).read()

# 1. add a manager-only LSM hook body inside the CONFIG_KSU_SUSFS half
else_marker = "#else\nstatic int ksu_task_fix_setuid(struct cred *new, const struct cred *old, int flags)"
assert else_marker in s, "lsm_hook.c: expected '#else' + ksu_task_fix_setuid not found"
susi_hook = '''/*
 * ksu-ci: susfs builds normally install the manager fd from the setresuid
 * syscall hook (ksu_handle_setresuid above), which additionally depends on
 * the zygote sid cache populated in apply_kernelsu_rules(). When that cache
 * is empty the manager app is born without its [ksu_driver] fd and the
 * manager reports "Unsupported". Register this LSM hook (fires from
 * commit_creds on every uid change, i.e. every zygote fork) as a
 * manager-only fallback, mirroring the non-susfs build. Umount handling
 * intentionally stays in the syscall hook so it is not done twice.
 */
static int ksu_task_fix_setuid(struct cred *new, const struct cred *old, int flags)
{
    if (new && unlikely(is_uid_manager(new->uid.val))) {
        disable_seccomp();
        pr_info("install fd for manager (lsm): %d\\n", new->uid.val);
        ksu_install_fd();
    }
    return 0;
}
'''
s = s.replace(else_marker, susi_hook + else_marker, 1)

# 2. register it on susfs builds too (drop the #ifndef CONFIG_KSU_SUSFS gate)
old_gate = "#ifndef CONFIG_KSU_SUSFS\n    LSM_HOOK_INIT(task_fix_setuid, ksu_task_fix_setuid),\n#endif"
assert old_gate in s, "lsm_hook.c: expected task_fix_setuid registration gate not found"
s = s.replace(old_gate, "    LSM_HOOK_INIT(task_fix_setuid, ksu_task_fix_setuid),", 1)

open(p, "w").write(s)
PYEOF
  fi

  # ------------------------------------------------------------------------
  # SukiSU version pin (ksu-ci): see the SUKI_VER_* comment at the top.
  # Verified live: v4.3.0-r2 -> main@3965 -> ksuver 41150 = manager versionCode.
  if [ "$KSU_SOURCE" = "sukisu" ] && [ -f KernelSU/kernel/Makefile ]; then
    log "SukiSU: pinning reported ksuver to $SUKI_VER_EXPECTED (manager $SUKI_VER_TAG)"
    git -C KernelSU fetch -q --filter=blob:none \
      origin "refs/tags/$SUKI_VER_TAG:refs/tags/$SUKI_VER_TAG"
    SUKI_TAG_COUNT="$(git -C KernelSU rev-list --count "$SUKI_VER_TAG")"
    SUKI_TAG_VER="$((40000 + SUKI_TAG_COUNT - 2815))"
    if [ "$SUKI_TAG_VER" != "$SUKI_VER_EXPECTED" ]; then
      echo "FATAL: $SUKI_VER_TAG now resolves to ksuver $SUKI_TAG_VER (count $SUKI_TAG_COUNT),"
      echo "       expected $SUKI_VER_EXPECTED. Upstream rebased its history - update"
      echo "       SUKI_VER_TAG/SUKI_VER_EXPECTED in ksu-ci/build.sh to the manager"
      echo "       release you pair with."
      exit 1
    fi
    python3 - "$SUKI_VER_EXPECTED" <<'PYEOF'
import sys
p = "KernelSU/kernel/Makefile"
s = open(p).read()
old_ver = "KSU_VERSION     := $(if $(LOCAL_COUNT),$(shell expr $(VERSION_BASE) + $(LOCAL_COUNT) - $(VERSION_OFFSET)),13000)"
new_ver = ("# ksu-ci: pinned so the driver reports the manager-era ksuver instead of\n"
           "# a daily-drifting count of upstream main (see ksu-ci/build.sh).\n"
           "KSU_VERSION     := " + sys.argv[1])
assert old_ver in s, "Makefile: KSU_VERSION assignment not found"
s = s.replace(old_ver, new_ver, 1)
old_full = "KSU_VERSION_FULL := $(if $(call git_short_sha),v$(VERSION_TAG)-$(call git_short_sha)@$(call git_branch),v$(VERSION_TAG)-$(REPO_NAME)-unknown@unknown)"
new_full = "KSU_VERSION_FULL := v4.3.0-r2-75179fc9@builtin"
assert old_full in s, "Makefile: KSU_VERSION_FULL assignment not found"
s = s.replace(old_full, new_full, 1)
open(p, "w").write(s)
PYEOF
  fi

  # ------------------------------------------------------------------------
  # SukiSU uapi v6 report backport (ksu-ci): ksud v4.3.0-r2 hard-refuses
  # module install / module actions / the post-fs-data, services and
  # boot-complete boot stages unless the kernel reports EXACTLY its own
  # KERNEL_SU_UAPI_VERSION (6) through the extended GET_INFO ioctl
  # ("UAPI version mismatch: kernel=0, ksud=6. Please update KernelSU!").
  # The pinned driver (2026-05-29) predates the whole scheme. Backported
  # (mirroring upstream's own dual-handler design):
  #   - struct ksu_get_info_cmd + trailing uapi_version (= 6); the 16-byte
  #     _IOR('K',2,...) ioctl the v4.3.0-r2 manager/ksud probe first
  #   - the old size-0 ioctl stays registered as GET_INFO_LEGACY with a
  #     12-byte reply, so older callers are not overrun
  #   - EVENT_SERVICES (uapi v5): returns 1 exactly once per boot so ksud's
  #     on_services() runs service.sh; reset on EVENT_POST_FS_DATA for the
  #     emulated soft reboot - identical to upstream
  # Deliberately NOT backported (verified safe against ksud v4.3.0-r2):
  #   - LOOKUP_SYMBOLS (v6): only `ksud debug insmod` uses it and it falls
  #     back to /proc/kallsyms when the ioctl is missing
  #   - FLAG_PREINIT (v6): this kernel has no preinit runner; the flag stays
  #     unset so ksud's userspace preinit runner keeps handling it
  #   - profile v4 flags (v2): appended field, the v3 allowlist reads the
  #     safe prefix (`su --ksu-no-new-privs`, non-default, errors out)
  #   - SET_SPOOF_VERSION / DISABLE_ESCAPE_TO_ROOT: late-load/CLI paths,
  #     warn-and-continue
  if [ "$KSU_SOURCE" = "sukisu" ] && [ -f KernelSU/kernel/supercall/dispatch.c ]; then
    log "SukiSU: backporting uapi v6 report (extended GET_INFO + EVENT_SERVICES) for the v4.3.0-r2 manager"
    python3 "$CI_DIR/suki-uapi6-backport.py" KernelSU
  fi

  KSU_DESC="$FORK_DESC"
fi

# ---------------------------------------------------------------------------
# Commit so the kernel release string stays clean (4.14.357-perf-g<sha>
# instead of ...-dirty), exactly like the official builds. (KernelSU/ is
# added as an embedded repo/gitlink - its files stay on disk for kbuild.)
git add -A
git -c user.name="vayu-ksu-ci" -c user.email="ci@localhost" \
  commit -q -m "Re-integrate $SU_NAME + susfs

SU: $KSU_DESC
Co-authored-by: crDroid sm8150 16.0-ksu ($KSU_SHA)"

# ---------------------------------------------------------------------------
# Which susfs variants to build
if [ "$KSU_SOURCE" = "latest" ] && [ "$KSU_SUSFS_MODE" != "without" ]; then
  log "WARNING: KSU_SOURCE=latest has no susfs integration;"
  log "         requested '$KSU_SUSFS_MODE' is downgraded to 'without'."
  log "         (upstream dropped the KSU-side susfs code from the legacy"
  log "          branch; use KSU_SOURCE=vendored or sukisu for susfs builds)"
  KSU_SUSFS_MODE="without"
fi
if [ "$KSU_SOURCE" = "baka" ] && [ "$KSU_SUSFS_MODE" != "without" ]; then
  log "WARNING: KSU_SOURCE=baka builds use BakaSU's manual-hook mode;"
  log "         susfs is a separate hook-method choice in BakaSU and is not"
  log "         wired up here - requested '$KSU_SUSFS_MODE' is downgraded to"
  log "         'without'. (use KSU_SOURCE=vendored or sukisu for susfs)"
  KSU_SUSFS_MODE="without"
fi
case "$KSU_SUSFS_MODE" in
  with)    VARIANTS="susfs" ;;
  without) VARIANTS="nosusfs" ;;
  both)    VARIANTS="susfs nosusfs" ;;
esac
log "Building variant(s): $VARIANTS (SU: $KSU_DESC)"

mkdir -p artifacts
rm -f artifacts/Image-* artifacts/*.zip artifacts/build-info.txt artifacts/build-meta.env
touch artifacts/build-info.txt

for VARIANT in $VARIANTS; do
  OUT="out-$VARIANT"
  # user-facing stem for this variant, e.g.
  #   KernelSU-Next_vayu_crDroid17_clang19_susfs_20261103
  #   BakaSU_vayu_crDroid17_clang19_no-susfs_20261103
  #   SukiSU-Ultra_vayu_crDroid17_clang19_susfs_20261103
  case "$VARIANT" in
    susfs)   VTOK="susfs" ;;
    nosusfs) VTOK="no-susfs" ;;
  esac
  ZIP_STEM="${SU_NAME}_vayu_crDroid17_clang${CLANG_MAJOR}_${VTOK}_${BUILD_DATE}"
  META_STEMS+="STEM_${VARIANT}=\"${ZIP_STEM}\""$'\n'
  # =========================================================================
  log "[$VARIANT] Configuring kernel ($DEFCONFIG + fragments)"
  rm -rf "$OUT"
  kmake "$OUT" "$DEFCONFIG"
  ./scripts/kconfig/merge_config.sh -m -O "$OUT" "$OUT/.config" "${FRAGMENTS[@]}"
  kmake "$OUT" olddefconfig

  if [ "$VARIANT" = "nosusfs" ]; then
    log "[$VARIANT] Disabling CONFIG_KSU_SUSFS (plain $SU_NAME build)"
    ./scripts/config --file "$OUT/.config" -d KSU_SUSFS
    kmake "$OUT" olddefconfig
  fi

  # per-SU extra config knobs
  case "$KSU_SOURCE" in
    baka)
      # manual-hook mode + BakaSU's auto hooks (LSM for setuid/initrc,
      # input_handler for input) - no kernel patches needed for those three.
      log "[$VARIANT] Enabling BakaSU manual hooks + auto-LSM hooks"
      ./scripts/config --file "$OUT/.config" \
        -e KSU_MANUAL_HOOK \
        -e KSU_MANUAL_HOOK_AUTO_SETUID_HOOK \
        -e KSU_MANUAL_HOOK_AUTO_INITRC_HOOK \
        -e KSU_MANUAL_HOOK_AUTO_INPUT_HOOK
      kmake "$OUT" olddefconfig
      ;;
    sukisu)
      # KPM needs 5.x APIs - keep it off on 4.14 (matches the reference
      # SukiSU sm8150 integration). The manager therefore keeps showing
      # "KPM: unsupported" - expected and deliberate, not a missing config.
      ./scripts/config --file "$OUT/.config" -d KPM
      # ADB Root (manager Settings -> "ADB Root"): default y in the driver
      # Kconfig - force it so a future re-pin cannot silently drop it
      ./scripts/config --file "$OUT/.config" -e KSU_FEATURE_ADBROOT
      kmake "$OUT" olddefconfig
      ;;
  esac

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
  # ksu-ci feature lock (sukisu only; every line verified =y / not set on the
  # running 2026-11-10 build via zcat /proc/config.gz): a defconfig fragment
  # edit, an upstream Kconfig change or a driver re-pin must never silently
  # weaken the root-hiding stack or flip KPM back on.
  if [ "$KSU_SOURCE" = "sukisu" ]; then
    grep -q "^CONFIG_KSU_FEATURE_ADBROOT=y" "$OUT/.config" \
      || { echo "FATAL: CONFIG_KSU_FEATURE_ADBROOT is not set (manager 'ADB Root')"; exit 1; }
    ! grep -q "^CONFIG_KPM=y" "$OUT/.config" \
      || { echo "FATAL: CONFIG_KPM must stay off on 4.14 (needs 5.x APIs)"; exit 1; }
    if [ "$VARIANT" = "susfs" ]; then
      for opt in SUS_PATH SUS_MOUNT SUS_KSTAT SPOOF_UNAME ENABLE_LOG \
                 HIDE_KSU_SUSFS_SYMBOLS SPOOF_CMDLINE_OR_BOOTCONFIG \
                 OPEN_REDIRECT SUS_MAP; do
        grep -q "^CONFIG_KSU_SUSFS_${opt}=y" "$OUT/.config" \
          || { echo "FATAL: CONFIG_KSU_SUSFS_${opt} is not set for the susfs variant"; exit 1; }
      done
    fi
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
  # show exactly what is being flashed in the recovery UI/log
  sed -i "s|^kernel.string=.*|kernel.string=crDroid 17.0 kernel + ${SU_NAME} (${VTOK}, clang ${CLANG_MAJOR}, ${BUILD_DATE})|" \
    /tmp/anykernel3/anykernel.sh
  cp "$IMAGE" /tmp/anykernel3/
  ( cd /tmp/anykernel3 && zip -qr9 "$OLDPWD/artifacts/${ZIP_STEM}.zip" . -x "*.git*" )

  cp "$IMAGE" "artifacts/Image-$VARIANT"

  {
    echo "=== variant: $VARIANT ==="
    echo "kernel release : $KRELEASE"
    echo "artifact       : ${ZIP_STEM}.zip"
    echo "susfs          : $([ "$VARIANT" = susfs ] && echo "enabled (CONFIG_KSU_SUSFS=y)" || echo "disabled")"
    echo "lto            : ${KSU_LTO:-full}"
  } >> artifacts/build-info.txt
done

# ksuver the driver reports to its manager
case "$KSU_SOURCE" in
  vendored)
    KSU_GITVER="$(grep -oP 'KSU_GIT_VERSION := \K[0-9]+' drivers/kernelsu/Makefile 2>/dev/null || true)"
    if [ -n "$KSU_GITVER" ]; then
      KSU_REPORTED="$((30000 + KSU_GITVER + 150))"
    else
      KSU_REPORTED="?"
    fi
    ;;
  latest)
    KSU_REPORTED="$(grep -oP 'KSU_VERSION_OVERRIDE := \K[0-9]+' drivers/kernelsu/Kbuild 2>/dev/null || echo "?")"
    ;;
  baka)
    KSU_REPORTED="$((30000 + $(git -C KernelSU rev-list --count HEAD) + 700))"
    ;;
  sukisu)
    # pinned (see the SUKI_VER_* block above): 40000 + count(v4.3.0-r2) - 2815
    # = 41150 = the manager release this kernel pairs with
    KSU_REPORTED="$((40000 + $(git -C KernelSU rev-list --count "$SUKI_VER_TAG") - 2815))"
    ;;
esac

{
  echo "kernel repo    : $(git remote get-url origin) @ $(git rev-parse HEAD)"
  echo "su solution    : $SU_NAME ($KSU_SOURCE)"
  echo "ksu            : $KSU_DESC"
  echo "ksu version    : $KSU_REPORTED (reported to the manager as ksuver)"
  echo "susfs mode     : $KSU_SUSFS_MODE -> built: $VARIANTS"
  echo "built with     : $(clang --version | head -1)"
  echo "built on       : $(date -u)"
} > /tmp/build-info-main.txt
cat artifacts/build-info.txt /tmp/build-info-main.txt > /tmp/build-info-all.txt
mv /tmp/build-info-all.txt artifacts/build-info.txt

# machine-readable build facts for the workflow's repack-boot + release jobs
{
  echo "SU_NAME=\"$SU_NAME\""
  echo "KSU_SOURCE=\"$KSU_SOURCE\""
  echo "CLANG_MAJOR=\"$CLANG_MAJOR\""
  echo "CLANG_FULL=\"$CLANG_FULL\""
  echo "BUILD_DATE=\"$BUILD_DATE\""
  echo "KSU_DESC=\"$KSU_DESC\""
  echo "KSU_REPORTED=\"$KSU_REPORTED\""
  echo "KRELEASE=\"$KRELEASE\""
  echo "LTO_MODE=\"${KSU_LTO:-full}\""
  echo "SUSFS_MODE=\"$KSU_SUSFS_MODE\""
  printf '%s' "$META_STEMS"
} > artifacts/build-meta.env

log "Artifacts:"
ls -la artifacts/
