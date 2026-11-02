### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

## KernelSU-Next + susfs build of the crDroid sm8150 kernel
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
BLOCK=auto;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install
dump_boot;
write_boot;
## end boot install
