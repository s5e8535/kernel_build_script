#!/bin/bash

set -e

# Configs
OUTDIR="$(pwd)/out"
MODULES_OUTDIR="$(pwd)/modules_out"
TMPDIR="$(pwd)/kernel_build/tmp"

IN_PLATFORM="$(pwd)/kernel_build/vboot_platform/${DEVICE}"
IN_DLKM="$(pwd)/kernel_build/vboot_dlkm/${DEVICE}"
IN_DTB="$OUTDIR/arch/arm64/boot/dts/exynos/s5e8535.dtb"

PLATFORM_RAMDISK_DIR="$TMPDIR/ramdisk_platform"
DLKM_RAMDISK_DIR="$TMPDIR/ramdisk_dlkm"
PREBUILT_RAMDISK="$(pwd)/kernel_build/boot/ramdisk"
MODULES_DIR="$DLKM_RAMDISK_DIR/lib/modules"

MKBOOTIMG="$(pwd)/kernel_build/mkbootimg/mkbootimg.py"
MKDTBOIMG="$(pwd)/kernel_build/dtb/mkdtboimg.py"

OUT_KERNELZIP="$(pwd)/kernel_build/Exynos1330_${DEVICE}.zip"
OUT_KERNELTAR="$(pwd)/kernel_build/Exynos1330_${DEVICE}.tar"
OUT_KERNEL="$OUTDIR/arch/arm64/boot/Image"
OUT_BOOTIMG="$(pwd)/kernel_build/zip/boot.img"
OUT_VENDORBOOTIMG="$(pwd)/kernel_build/zip/vendor_boot.img"
OUT_DTBIMAGE="$TMPDIR/dtb.img"

# Kernel-side

kfinish() {
    rm -rf "$TMPDIR"
    rm -rf "$OUTDIR"
    rm -rf "$MODULES_OUTDIR"
}

kfinish

DIR="$(readlink -f .)"
PARENT_DIR="$(readlink -f ${DIR}/..)"

export CC="$PARENT_DIR/toolchain/clang/bin/clang"
export PATH="$PARENT_DIR/toolchain/build-tools/path/linux-x86:$PARENT_DIR/toolchain/clang/bin:$PATH"
export LLVM=1
export ARCH=arm64

if [ ! -d "$PARENT_DIR/toolchain/clang" ]; then
    wget https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r547379.tar.gz
    mkdir -p "$PARENT_DIR/toolchain/clang"
    tar -xvzf clang-r547379.tar.gz -C $PARENT_DIR/toolchain/clang
    rm -rf clang-r547379.tar.gz
fi

if [ ! -d "$PARENT_DIR/toolchain/build-tools" ]; then
    wget https://android.googlesource.com/platform/prebuilts/build-tools/+archive/refs/heads/main.tar.gz
    mkdir -p "$PARENT_DIR/toolchain/build-tools"
    tar -xvzf main.tar.gz -C $PARENT_DIR/toolchain/build-tools
    rm -rf main.tar.gz
fi

make -j$(nproc --all) -C $(pwd) O=out ${DEVICE}_defconfig
make -j$(nproc --all) -C $(pwd) O=out dtbs
make -j$(nproc --all) -C $(pwd) O=out
make -j$(nproc --all) -C $(pwd) O=out INSTALL_MOD_STRIP="--strip-debug --keep-section=.ARM.attributes" INSTALL_MOD_PATH="$MODULES_OUTDIR" modules_install

rm -rf "$TMPDIR"
rm -f "$OUT_BOOTIMG"
rm -f "$OUT_VENDORBOOTIMG"
mkdir "$TMPDIR"
mkdir -p "$MODULES_DIR/0.0"
mkdir "$PLATFORM_RAMDISK_DIR"

cp -rf "$IN_PLATFORM"/* "$PLATFORM_RAMDISK_DIR/"
mkdir "$PLATFORM_RAMDISK_DIR/first_stage_ramdisk"
cp -f "$PLATFORM_RAMDISK_DIR/fstab.s5e8535" "$PLATFORM_RAMDISK_DIR/first_stage_ramdisk/fstab.s5e8535"

if ! find "$MODULES_OUTDIR/lib/modules" -mindepth 1 -type d | read; then
    echo "Unknown error!"
    exit 1
fi

missing_modules=""

for module in $(cat "$IN_DLKM/modules.load"); do
    i=$(find "$MODULES_OUTDIR/lib/modules" -name $module);
    if [ -f "$i" ]; then
        cp -f "$i" "$MODULES_DIR/0.0/$module"
    else
	missing_modules="$missing_modules $module"
    fi
done

if [ "$missing_modules" != "" ]; then
        echo "ERROR: the following modules were not found: $missing_modules"
	exit 1
fi

depmod 0.0 -b "$DLKM_RAMDISK_DIR"
sed -i 's/\([^ ]\+\)/\/lib\/modules\/\1/g' "$MODULES_DIR/0.0/modules.dep"
cd "$MODULES_DIR/0.0"
for i in $(find . -name "modules.*" -type f); do
    if [ $(basename "$i") != "modules.dep" ] && [ $(basename "$i") != "modules.softdep" ] && [ $(basename "$i") != "modules.alias" ]; then
        rm -f "$i"
    fi
done
cd "$DIR"

cp -f "$IN_DLKM/modules.load" "$MODULES_DIR/0.0/modules.load"
mv "$MODULES_DIR/0.0"/* "$MODULES_DIR/"
rm -rf "$MODULES_DIR/0.0"

echo "Building dtb image..."
python3 "$MKDTBOIMG" create "$OUT_DTBIMAGE" --custom0=0x00000000 --custom1=0xff000000 "$IN_DTB" || exit 1

echo "Building boot image..."

chmod +x $MKBOOTIMG

$MKBOOTIMG --header_version 4 \
    --kernel "$OUT_KERNEL" \
    --output "$OUT_BOOTIMG" \
    --os_version 15.0.0 \
    --os_patch_level 2025-03 || exit 1

echo "Done!"
echo "Building vendor_boot image..."

cd "$DLKM_RAMDISK_DIR"
find . | cpio --quiet -o -H newc -R root:root | lz4 -9cl > ../ramdisk_dlkm.lz4
cd ../ramdisk_platform
find . | cpio --quiet -o -H newc -R root:root | lz4 -9cl > ../ramdisk_platform.lz4
cd ..
echo "buildtime_bootconfig=enable" > bootconfig

$MKBOOTIMG --header_version 4 \
    --vendor_boot "$OUT_VENDORBOOTIMG" \
    --vendor_bootconfig "$(pwd)/bootconfig" \
    --dtb "$OUT_DTBIMAGE" \
    --vendor_ramdisk "$(pwd)/ramdisk_platform.lz4" \
    --ramdisk_type dlkm \
    --ramdisk_name dlkm \
    --vendor_ramdisk_fragment "$(pwd)/ramdisk_dlkm.lz4" \
    --os_version 15.0.0 \
    --os_patch_level 2025-03 || exit 1

cd "$DIR"

echo "Done!"

echo "Building zip..."
cd "$(pwd)/kernel_build/zip"
rm -f "$OUT_KERNELZIP"
brotli --quality=11 -c boot.img > boot.br
brotli --quality=11 -c vendor_boot.img > vendor_boot.br
zip -r9 -q "$OUT_KERNELZIP" META-INF boot.br vendor_boot.br
rm -f boot.br vendor_boot.br
cd "$DIR"
echo "Done! Output: $OUT_KERNELZIP"

echo "Building tar..."
cd "$(pwd)/kernel_build"
rm -f "$OUT_KERNELTAR"
lz4 -c -12 -B6 --content-size "$OUT_BOOTIMG" > boot.img.lz4
lz4 -c -12 -B6 --content-size "$OUT_VENDORBOOTIMG" > vendor_boot.img.lz4
tar -cf "$OUT_KERNELTAR" boot.img.lz4 vendor_boot.img.lz4
cd "$DIR"
rm -f boot.img.lz4 vendor_boot.img.lz4
echo "Done! Output: $OUT_KERNELTAR"

echo "Cleaning..."
rm -f "${OUT_VENDORBOOTIMG}" "${OUT_BOOTIMG}"
kfinish
