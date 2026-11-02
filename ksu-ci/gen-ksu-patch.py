#!/usr/bin/env python3
"""gen-ksu-patch.py - generate the curated KernelSU-Next + susfs patch.

Usage: gen-ksu-patch.py <ksu_ref_sha>   (run from the kernel repo root)

Diffs the current HEAD (crDroid 17.0, clean) against <ksu_ref_sha>
(crDroid 16.0-ksu, which contains the KernelSU-Next legacy + susfs
integration) and keeps ONLY the KSU/susfs-related hunks, skipping the
files that are taken wholesale from 16.0-ksu by build.sh.

Everything here was verified to compile and boot-image-build on
crdroidandroid/android_kernel_xiaomi_sm8150 branch 17.0 (commit
a6f18ebee, kernel 4.14.357) with KSU ref f5fa5e32e (16.0-ksu tip).

The output (stdout) is a unified diff, appliable with `git apply`.
"""
import re
import subprocess
import sys

# ---------------------------------------------------------------------------
# Files taken WHOLESALE from the 16.0-ksu ref by build.sh - never patch these
# (either brand new files, or files whose susfs code depends on the newer
#  upstream base that the 16.0-ksu branch carries):
#   fs/proc/task_mmu.c, fs/proc/base.c, fs/seq_file.c  -> susfs sus_map /
#       map_files code depends on the newer smaps/seq_file base
#   include/linux/seq_file.h, include/linux/pkeys.h    -> their dependencies
WHOLE_TAKE = [
    "drivers/kernelsu",          # whole directory
    "fs/susfs.c",
    "include/linux/susfs.h",
    "include/linux/susfs_def.h",
    "fs/proc/task_mmu.c",
    "fs/proc/base.c",
    "fs/seq_file.c",
    "include/linux/seq_file.h",
    "include/linux/pkeys.h",
]

# Files whose diff must be kept in FULL (backports KSU needs, whose hunks
# carry no ksu/susfs text):
FORCE_FILES = [
    "include/linux/seccomp.h",   # filter_count backport (KSU seccomp cache)
    "include/linux/cred.h",      # get_cred_rcu backport
    "kernel/cred.c",
    "fs/internal.h",             # path_umount declaration
    "fs/namespace.c",            # path_umount + ida modernization (must stay consistent)
]

# Hunks are kept when any changed line matches one of these markers.
MARKER = re.compile(
    r"ksu|kernelsu|susfs|sus_|__sus|path_umount|can_umount|path_mounted",
    re.IGNORECASE,
)


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True,
                          check=True).stdout


def skip(path):
    for w in WHOLE_TAKE:
        if path == w or path.startswith(w.rstrip("/") + "/"):
            return True
    return False


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: gen-ksu-patch.py <ksu_ref_sha>")
    to = sys.argv[1]
    head = git("rev-parse", "HEAD").strip()

    files = git("diff", "--name-only", head, to).splitlines()
    kept_patch = []
    stats = []
    for f in files:
        if skip(f):
            continue
        diff = git("diff", head, to, "--", f)
        if not diff.strip():
            continue
        header, hunks, cur = [], [], None
        for line in diff.splitlines():
            if line.startswith(("diff --git", "index ", "--- ", "+++ ")):
                cur = None
                header.append(line)
            elif line.startswith("@@"):
                cur = [line]
                hunks.append(cur)
            elif cur is not None:
                cur.append(line)
        kept = [h for h in hunks
                if f in FORCE_FILES
                or any(MARKER.search(l) for l in h[1:] if l and l[0] in "+-")]
        dropped = len(hunks) - len(kept)
        if kept:
            kept_patch.append("\n".join(header))
            for h in kept:
                kept_patch.append("\n".join(h))
            kept_patch.append("")
        stats.append((f, len(kept), dropped))

    out = "\n".join(kept_patch)
    n_hunks = out.count("\n@@") + (1 if out.startswith("@@") else 0)
    if n_hunks < 50:
        sys.exit("FATAL: only %d hunks generated - the trees have probably "
                 "changed in an unexpected way. Bailing out instead of "
                 "building a broken kernel." % n_hunks)
    sys.stdout.write(out + "\n")
    print("kept %d hunks across %d files" % (n_hunks, len([s for s in stats if s[1]])),
          file=sys.stderr)


if __name__ == "__main__":
    main()
