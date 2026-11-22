#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SD-only packaging: no QSPI write/update images and no prebuilt upstream FSBL.
set -eu
BIN_DIR=$1
: "${EDGEQAM_ROOT:?}" "${LIBRE_BUILD_DIR:?}" "${HOST_DIR:?}"
BOOTGEN=bootgen
MKIMAGE="$HOST_DIR/bin/mkimage"
for file in "$LIBRE_BUILD_DIR/vivado/fsbl/Release/fsbl.elf" \
    "$BIN_DIR/u-boot" "$BIN_DIR/Image" "$BIN_DIR/rootfs.cpio.xz" \
    "$BIN_DIR/zynq-libre.dtb" "$LIBRE_BUILD_DIR/vivado/system_top.bin"; do
    [ -s "$file" ] || { echo "Missing build output: $file" >&2; exit 1; }
done
SD="$BIN_DIR/edgeqam-sd"
mkdir -p "$SD"
printf 'image: { [bootloader] %s %s }\n' \
    "$LIBRE_BUILD_DIR/vivado/fsbl/Release/fsbl.elf" "$BIN_DIR/u-boot" > "$BIN_DIR/edgeqam-boot.bif"
"$BOOTGEN" -arch zynq -image "$BIN_DIR/edgeqam-boot.bif" -w -o "$SD/BOOT.bin"
lzma -c "$BIN_DIR/Image" > "$BIN_DIR/edgeqam-Image.lzma"
"$MKIMAGE" -A arm -O linux -T kernel -C lzma -a 0x8000 -e 0x8000 \
    -n "LibreSDR edgeQAM Linux" -d "$BIN_DIR/edgeqam-Image.lzma" "$SD/uImage"
"$MKIMAGE" -A arm -T ramdisk -C none -d "$BIN_DIR/rootfs.cpio.xz" "$SD/uramdisk.image.xz"
cp "$BIN_DIR/zynq-libre.dtb" "$SD/devicetree.dtb"
cp "$LIBRE_BUILD_DIR/vivado/system_top.bin" "$SD/system_top.bin"
cp "$EDGEQAM_ROOT/src/rootfs/libresdr/boot/edgeqam.conf" "$SD/edgeqam.conf"
cp "$EDGEQAM_ROOT/src/rootfs/libresdr/boot/uEnv.txt" "$SD/uEnv.txt"
cp "$EDGEQAM_ROOT/LICENSE" "$SD/LICENSE"
