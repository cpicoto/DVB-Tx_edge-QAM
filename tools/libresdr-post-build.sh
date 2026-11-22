#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
: "${EDGEQAM_ROOT:?}" "${HOST_DIR:?}" "${STAGING_DIR:?}" "${TARGET_DIR:?}"
CC="$HOST_DIR/bin/arm-linux-gcc"
[ -x "$CC" ] || { echo "Missing Buildroot ARM compiler: $CC" >&2; exit 1; }
mkdir -p "$TARGET_DIR/usr/sbin"
"$CC" --sysroot="$STAGING_DIR" -O2 -std=gnu11 -Wall -Wextra -Werror \
    -DLIBRESDR_V1 "$EDGEQAM_ROOT/src/sw/dvbt_tx.c" -o "$TARGET_DIR/usr/sbin/dvbt_tx" \
    -liio -lpthread -lm
chmod 0755 "$TARGET_DIR/etc/init.d/S99edgeqam"
chmod 0755 "$TARGET_DIR/etc/init.d/S20fat-mount"
mkdir -p "$TARGET_DIR/usr/share"
install -m 0644 "$EDGEQAM_ROOT/LICENSE" "$TARGET_DIR/usr/share/edgeqam-LICENSE"
# Infrastructure overlays are retained; do not start processes that touch DAC GPIO,
# DMA, RF configuration, or the absent Maia fabric.
for service in S60maia-httpd S61classifier S95tx-nco S55sdr_ip_gadget S95bgcript \
    S96networkcong S59bandplan S50mosquitto S22eco; do
    rm -f "$TARGET_DIR/etc/init.d/$service"
done
