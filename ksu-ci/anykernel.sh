### AnyKernel Ramdisk Mod Script
## osm0sis @ xda-developers

## KernelSU-Next (+ susfs) build of the crDroid sm8150 kernel
## for the Poco X3 Pro (vayu / bhima)

### AnyKernel setup
# global properties
properties() { '
kernel.string=crDroid 17.0 kernel + KernelSU-Next (legacy) + susfs
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=vayu
device.name2=bhima
device.name3=poco_x3_pro
device.name4=X3 Pro
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties


### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
} # end attributes

# boot shell variables
#
# --- slot resolution (OrangeFox / modern recovery fix) ---------------------
# AK3's own slot detection only knows `getprop ro.boot.slot_suffix` and
# `androidboot.slot_suffix=` on /proc/cmdline. Recoveries running kernels
# >= 5.10 (e.g. current OrangeFox builds for crDroid 13 / Android 17) pass
# their androidboot.* arguments through /proc/bootconfig instead, which made
# AK3 abort with "Unable to determine active slot. Aborting...".
# So: resolve the slot ourselves from four different sources, point BLOCK
# directly at the already-slotted partition, and keep IS_SLOT_DEVICE=auto
# so AK3 never aborts on slot detection by itself. (With an unslotted BLOCK
# AK3 would still append its own $SLOT when it manages to find one.)
AK_SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null);
[ -n "$AK_SLOT" ] || AK_SLOT=$(grep -o 'androidboot.slot_suffix=[^ ]*' /proc/cmdline 2>/dev/null | head -n 1 | cut -d= -f2);
[ -n "$AK_SLOT" ] || AK_SLOT=$(grep -Eo '(androidboot\.)?slot_suffix *= *"[^"]*"' /proc/bootconfig 2>/dev/null | head -n 1 | sed 's/.*"\(.*\)"/\1/');
[ -n "$AK_SLOT" ] || AK_SLOT=$(getprop ro.boot.slot 2>/dev/null);
[ -n "$AK_SLOT" ] || AK_SLOT=$(grep -o 'androidboot.slot=[^ ]*' /proc/cmdline 2>/dev/null | head -n 1 | cut -d= -f2);
case "$AK_SLOT" in
  _a|_b) ;;
  a|b) AK_SLOT="_$AK_SLOT" ;;
  *) unset AK_SLOT ;;
esac;
echo "AnyKernel: active slot resolved to: ${AK_SLOT:-unknown}" >&2;
BLOCK=auto;
IS_SLOT_DEVICE=auto;
if [ -n "$AK_SLOT" ]; then
  for AK_BYNAME in /dev/block/bootdevice/by-name /dev/block/by-name /dev/block/platform/*/by-name; do
    if [ -e "$AK_BYNAME/boot$AK_SLOT" ]; then
      BLOCK="$AK_BYNAME/boot$AK_SLOT";
      echo "AnyKernel: target block set to $BLOCK" >&2;
      break;
    fi;
  done;
fi;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install
dump_boot;
write_boot;
## end boot install