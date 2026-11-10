#!/usr/bin/env python3
"""ksu-ci: SukiSU uapi v6 report backport (manager v4.3.0-r2 module install fix).

ksud v4.3.0-r2 refuses module install / action / boot stages unless the
kernel reports exactly its own KERNEL_SU_UAPI_VERSION (6) through the
extended KSU_IOCTL_GET_INFO ("UAPI version mismatch: kernel=0, ksud=6").
The pinned driver (75179fc9, 2026-05-29) predates the whole scheme.

Backported surface (mirroring upstream's own dual-handler design):
  - struct ksu_get_info_cmd gains a trailing __u32 uapi_version (= 6)
  - KSU_IOCTL_GET_INFO becomes _IOR('K', 2, struct) (the 16-byte ioctl);
    the old size-0 number stays registered as KSU_IOCTL_GET_INFO_LEGACY
    with a 12-byte reply so legacy callers are not overrun
  - EVENT_SERVICES (uapi v5): returns 1 exactly once per boot so ksud's
    on_services() runs service.sh; reset on EVENT_POST_FS_DATA for the
    emulated soft reboot, exactly like upstream

Deliberately NOT backported (verified safe against ksud v4.3.0-r2):
  - KSU_IOCTL_LOOKUP_SYMBOLS (v6): only used by `ksud debug insmod`,
    falls back to /proc/kallsyms on error
  - KSU_GET_INFO_FLAG_PREINIT (v6): kernel has no preinit runner, so ksud
    keeps using its userspace runner (flag simply stays unset)
  - profile v4 flags (v2): appended __u64, v3 kernel reads the safe prefix;
    `su --ksu-no-new-privs` (non-default) errors out
  - KSU_IOCTL_SET_SPOOF_VERSION / DISABLE_ESCAPE_TO_ROOT: late-load / CLI
    paths only, warn-and-continue
"""
import os
import sys

OK = True
BASE = sys.argv[1] if len(sys.argv) > 1 else "."

def patch(path, edits, required=True):
    global OK
    path = os.path.join(BASE, path)
    try:
        with open(path) as f:
            s = f.read()
    except FileNotFoundError:
        if required:
            raise
        return
    for old, new in edits:
        if old not in s:
            print(f"FATAL: {path}: expected snippet not found:\n{old[:120]}...")
            OK = False
            continue
        if new in s and old != new:
            print(f"note: {path}: already patched")
            continue
        s = s.replace(old, new, 1)
    with open(path, "w") as f:
        f.write(s)

# ---------------------------------------------------------------- header --
p = "kernel/include/uapi/supercall.h"
patch(p, [
    # 1. EVENT_SERVICES (uapi v5)
    ("DECLARE(__u32, EVENT_MODULE_MOUNTED, 3);",
     "DECLARE(__u32, EVENT_MODULE_MOUNTED, 3);\n"
     "DECLARE(__u32, EVENT_SERVICES, 4);"),
    # 2. uapi version constant + extended struct + legacy struct
    ("""struct ksu_get_info_cmd {
    __u32 version; /* Output: KERNEL_SU_VERSION */
    __u32 flags; /* Output: KSU_GET_INFO_FLAG_* bits */
    __u32 features; /* Output: max feature ID supported */
};""",
     """/*
 * ksu-ci backport of the upstream uapi-version scheme (builtin branch,
 * 2026-06-15; value 6 as of manager v4.3.0-r2): ksud refuses to install
 * modules unless the kernel reports exactly its own version here.
 * Backported surface: extended KSU_IOCTL_GET_INFO + EVENT_SERVICES.
 * NOT backported: LOOKUP_SYMBOLS (ksud falls back to /proc/kallsyms),
 * FLAG_PREINIT (no kernel preinit runner; ksud's userspace runner is used),
 * profile-v4 flags (v3 allowlist reads the safe prefix).
 */
DECLARE(__u32, KERNEL_SU_UAPI_VERSION, 6);

struct ksu_get_info_cmd {
    __u32 version; /* Output: KERNEL_SU_VERSION */
    __u32 flags; /* Output: KSU_GET_INFO_FLAG_* bits */
    __u32 features; /* Output: max feature ID supported */
    __u32 uapi_version; /* Output: KERNEL_SU_UAPI_VERSION */
};

struct ksu_get_info_legacy_cmd {
    __u32 version; /* Output: KERNEL_SU_VERSION */
    __u32 flags; /* Output: KSU_GET_INFO_FLAG_* bits */
    __u32 features; /* Output: max feature ID supported */
};"""),
    # 3. ioctl numbers: 16-byte GET_INFO + keep the old number as LEGACY
    ("DECLARE(__u32, KSU_IOCTL_GET_INFO, _IOC(_IOC_READ, 'K', 2, 0));",
     "DECLARE(__u32, KSU_IOCTL_GET_INFO, _IOR('K', 2, struct ksu_get_info_cmd));\n"
     "/* the pre-uapi ioctl number; replies with the legacy 12-byte struct */\n"
     "DECLARE(__u32, KSU_IOCTL_GET_INFO_LEGACY, _IOC(_IOC_READ, 'K', 2, 0));"),
])

# -------------------------------------------------------------- dispatch --
p = "kernel/supercall/dispatch.c"
patch(p, [
    # 1. dual get_info handlers
    ("""static int do_get_info(void __user *arg)
{
    struct ksu_get_info_cmd cmd = { .version = KERNEL_SU_VERSION, .flags = 0 };

    if (is_manager()) {
        cmd.flags |= KSU_GET_INFO_FLAG_MANAGER;
    }

    cmd.features = KSU_FEATURE_MAX;

    if (copy_to_user(arg, &cmd, sizeof(cmd))) {
        pr_err("get_version: copy_to_user failed\\n");
        return -EFAULT;
    }

    return 0;
}""",
     """/* ksu-ci: extended GET_INFO (uapi v2+) - reports KERNEL_SU_UAPI_VERSION
 * so v4.3.0-r2-era managers/ksud pass ensure_uapi_version_matched(). */
static int do_get_info(void __user *arg)
{
    struct ksu_get_info_cmd cmd = { .version = KERNEL_SU_VERSION, .flags = 0 };

    if (is_manager()) {
        cmd.flags |= KSU_GET_INFO_FLAG_MANAGER;
    }

    cmd.features = KSU_FEATURE_MAX;
    cmd.uapi_version = KERNEL_SU_UAPI_VERSION;

    if (copy_to_user(arg, &cmd, sizeof(cmd))) {
        pr_err("get_version: copy_to_user failed\\n");
        return -EFAULT;
    }

    return 0;
}

/* ksu-ci: the pre-uapi 12-byte reply for the old ioctl number, so callers
 * passing a legacy-sized buffer are not overrun. */
static int do_get_info_legacy(void __user *arg)
{
    struct ksu_get_info_legacy_cmd cmd = { .version = KERNEL_SU_VERSION, .flags = 0 };

    if (is_manager()) {
        cmd.flags |= KSU_GET_INFO_FLAG_MANAGER;
    }

    cmd.features = KSU_FEATURE_MAX;

    if (copy_to_user(arg, &cmd, sizeof(cmd))) {
        pr_err("get_version: copy_to_user failed\\n");
        return -EFAULT;
    }

    return 0;
}"""),
    # 2. dispatch table: register the legacy number next to the new one
    ("""    {
        .cmd = KSU_IOCTL_GET_INFO,
        .name = "GET_INFO",
        .handler = do_get_info,
        .perm_check = always_allow
    },""",
     """    {
        .cmd = KSU_IOCTL_GET_INFO,
        .name = "GET_INFO",
        .handler = do_get_info,
        .perm_check = always_allow
    },
    {
        .cmd = KSU_IOCTL_GET_INFO_LEGACY,
        .name = "GET_INFO_LEGACY",
        .handler = do_get_info_legacy,
        .perm_check = always_allow
    },"""),
    # 3. do_report_event: track + reset services_started (uapi v5)
    ("""static int do_report_event(void __user *arg)
{
    struct ksu_report_event_cmd cmd;

    if (copy_from_user(&cmd, arg, sizeof(cmd))) {
        return -EFAULT;
    }

    switch (cmd.event) {
    case EVENT_POST_FS_DATA: {
        static bool post_fs_data_lock = false;
        if (!post_fs_data_lock) {""",
     """static int do_report_event(void __user *arg)
{
    static bool services_started = false;
    struct ksu_report_event_cmd cmd;

    if (copy_from_user(&cmd, arg, sizeof(cmd))) {
        return -EFAULT;
    }

    switch (cmd.event) {
    case EVENT_POST_FS_DATA: {
        static bool post_fs_data_lock = false;

        /* Reset for emulated soft reboot (ksu-ci, uapi v5 backport) */
        services_started = false;
        if (!post_fs_data_lock) {"""),
    # 4. EVENT_SERVICES case: 1 exactly once per boot, 0 afterwards
    ("""    case EVENT_MODULE_MOUNTED: {
        pr_info("module mounted!\\n");
        on_module_mounted();
        break;
    }
    default:
        break;
    }

    return 0;
}""",
     """    case EVENT_MODULE_MOUNTED: {
        pr_info("module mounted!\\n");
        on_module_mounted();
        break;
    }
    case EVENT_SERVICES: {
        /* ksu-ci, uapi v5 backport: ksud's on_services() only runs the
         * service.sh stage when this returns 1 the first time after boot
         * (0 = "already started, skip"). */
        if (services_started) {
            pr_info("services already started, skipping\\n");
            return 0;
        }
        services_started = true;
        pr_info("services triggered\\n");
        return 1;
    }
    default:
        break;
    }

    return 0;
}"""),
])

if not OK:
    sys.exit(1)
print("uapi v6 report backport: OK")
