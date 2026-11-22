#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Outputs never use the Fishball project, boot files, or prebuilt upstream XSA.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export EDGEQAM_ROOT="$ROOT"
export LIBRE_BUILD_DIR="${LIBRE_BUILD_DIR:-$ROOT/build}"
case "$ROOT:$LIBRE_BUILD_DIR" in *" "*|*$'\t'*|*$'\n'*)
    echo "Build paths must not contain whitespace (Xilinx/Buildroot)" >&2; exit 1 ;;
esac
mkdir -p "$LIBRE_BUILD_DIR/logs"
LIBRE_BUILD_DIR="$(cd "$LIBRE_BUILD_DIR" && pwd)"
export LIBRE_BUILD_DIR
MAIA="$LIBRE_BUILD_DIR/deps/maia-sdr"
FW="$LIBRE_BUILD_DIR/deps/tezuka_fw"
LOCK="$ROOT/tools/libresdr-lock.json"
pin() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); print(v[sys.argv[2]][sys.argv[3]])' "$LOCK" "$1" "$2"; }
need() { command -v "$1" >/dev/null || { echo "Required tool unavailable: $1" >&2; exit 1; }; }
checkout() {
    local name=$1 directory=$2 commit url
    commit=$(pin "$name" commit); url=$(pin "$name" url)
    if [ ! -d "$directory" ]; then
        mkdir -p "$directory"
        git -C "$directory" init --quiet
        git -C "$directory" remote add origin "$url"
        git -C "$directory" fetch --quiet --depth 1 origin "$commit"
        git -C "$directory" checkout --quiet --detach FETCH_HEAD
    fi
    [ "$(git -C "$directory" rev-parse HEAD)" = "$commit" ] || {
        echo "Wrong dependency revision in $directory; use a fresh LIBRE_BUILD_DIR" >&2; exit 1;
    }
    [ -z "$(git -C "$directory" status --porcelain --untracked-files=no)" ] || {
        echo "Modified pinned dependency: $directory" >&2; exit 1;
    }
}
deps() {
    checkout maia "$MAIA"
    checkout firmware "$FW"
    git -C "$MAIA" submodule update --init --depth 1 maia-hdl/adi-hdl
    local adi
    adi=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["adi_hdl"])' "$LOCK")
    [ "$(git -C "$MAIA/maia-hdl/adi-hdl" rev-parse HEAD)" = "$adi" ] || {
        echo "Wrong ADI submodule revision" >&2; exit 1;
    }
}
version_check() {
    need "$1"
    "$1" -version > "$LIBRE_BUILD_DIR/logs/$1-version.txt" 2>&1
    grep -q '2023\.1' "$LIBRE_BUILD_DIR/logs/$1-version.txt" || {
        echo "$1 must be 2023.1" >&2; exit 1;
    }
}
csim() {
    version_check vitis_hls
    need pkg-config
    checkout reference "$LIBRE_BUILD_DIR/deps/dvbtx-reference"
    local ref="$LIBRE_BUILD_DIR/deps/dvbtx-reference"
    local sim="$LIBRE_BUILD_DIR/csim"
    mkdir -p "$sim/baseline-src" "$sim/baseline" "$sim/candidate"
    python3 "$ROOT/tools/test-libresdr.py" --generate-ts "$sim/in.ts"
    # An independent float reference checks EN 300 744; the unchanged v1 baseline
    # additionally establishes exact integer IQ equality, including startup symbols.
    "${CC:-cc}" -O2 -I"$ref/engine/src" "$ref/tests/dvbt_ref.c" \
        "$ref/engine/src/dvbt.c" "$ref/engine/src/outer.c" \
        "$ref/engine/src/ofdm.c" "$ref/engine/src/util.c" \
        $(pkg-config --cflags --libs fftw3f) -lm -lpthread -o "$sim/dvbt_ref"
    "$sim/dvbt_ref" "$sim/in.ts" "$sim/ref.cf32" 2048 6 7 8 32 150 2>&1 |
        tee "$LIBRE_BUILD_DIR/logs/reference.log"
    local baseline
    baseline=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["v1_baseline"])' "$LOCK")
    for name in dvbt_mod.cpp dvbt_mod.h dvbt_tables.h; do
        git -C "$ROOT" show "$baseline:src/hls/v1/$name" > "$sim/baseline-src/$name"
    done
    cp "$ROOT/src/hls/v1/tb.cpp" "$sim/baseline-src/tb.cpp"
    export STEP=csim TS_INPUT="$sim/in.ts" REFERENCE_CF32="$sim/ref.cf32" NSYM=150
    unset REFERENCE_CS16
    (cd "$sim/baseline" && HLS_SOURCE_DIR="$sim/baseline-src" \
        vitis_hls -f "$ROOT/src/hls/v1/run_hls.tcl") 2>&1 |
        tee "$LIBRE_BUILD_DIR/logs/csim-baseline.log"
    export REFERENCE_CS16="$sim/baseline/dvbt_v1/sol1/csim/build/hls_out.cs16"
    (cd "$sim/candidate" && HLS_SOURCE_DIR="$ROOT/src/hls/v1" \
        vitis_hls -f "$ROOT/src/hls/v1/run_hls.tcl") 2>&1 |
        tee "$LIBRE_BUILD_DIR/logs/csim-candidate.log"
    local candidate="$sim/candidate/dvbt_v1/sol1/csim/build/hls_out.cs16"
    cmp "$REFERENCE_CS16" "$candidate"
    python3 - "$sim" "$REFERENCE_CS16" "$candidate" <<'PY'
import hashlib, json, pathlib, sys
sim, baseline, candidate = map(pathlib.Path, sys.argv[1:])
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
assert baseline.stat().st_size == candidate.stat().st_size == 150 * 2112 * 4
result = {"mismatches": 0, "symbols": 150, "bytes": candidate.stat().st_size,
          "baseline_sha256": digest(baseline), "candidate_sha256": digest(candidate),
          "ts_sha256": digest(sim / "in.ts"), "reference_cf32_sha256": digest(sim / "ref.cf32")}
(sim / "bit-exact.json").write_text(json.dumps(result, indent=2) + "\n")
PY
}
hls() {
    version_check vitis_hls
    mkdir -p "$LIBRE_BUILD_DIR/hls"
    (cd "$LIBRE_BUILD_DIR/hls" && STEP=export HLS_SOURCE_DIR="$ROOT/src/hls/v1" \
        vitis_hls -f "$ROOT/src/hls/v1/run_hls.tcl") \
        2>&1 | tee "$LIBRE_BUILD_DIR/logs/hls-export.log"
}
hdl() {
    version_check vivado
    need xsct
    need bootgen
    export REQUIRED_VIVADO_VERSION=2023.1
    export MAIA_DIR="$MAIA"
    export HLS_IP_DIR="$LIBRE_BUILD_DIR/hls/dvbt_v1/sol1/impl/ip"
    [ -s "$HLS_IP_DIR/component.xml" ] || { echo "Export the v1 HLS IP first" >&2; exit 1; }
    for ip in xilinx/util_clkdiv axi_ad9361 util_rfifo util_wfifo axi_dmac \
        util_pack/util_cpack2 util_pack/util_upack2; do
        make -C "$MAIA/maia-hdl/adi-hdl/library/$ip" 2>&1 |
            tee "$LIBRE_BUILD_DIR/logs/adi-${ip//\//-}.log"
    done
    python3 "$ROOT/tools/libresdr.py" prepare-hdl "$MAIA" "$LIBRE_BUILD_DIR/vivado"
    (cd "$LIBRE_BUILD_DIR/vivado" && vivado -mode batch \
        -source "$ROOT/src/hdl/libre_edgeqam/system_project.tcl") 2>&1 |
        tee "$LIBRE_BUILD_DIR/logs/vivado.log"
    xsct "$ROOT/src/hdl/libre_edgeqam/create_fsbl.tcl" \
        "$LIBRE_BUILD_DIR/vivado/libre_edgeqam.xsa" "$LIBRE_BUILD_DIR/vivado" \
        2>&1 | tee "$LIBRE_BUILD_DIR/logs/fsbl.log"
    printf 'image: { %s }\n' "$LIBRE_BUILD_DIR/vivado/libre_edgeqam.runs/impl_1/system_top.bit" \
        > "$LIBRE_BUILD_DIR/vivado/system.bif"
    bootgen -arch zynq -image "$LIBRE_BUILD_DIR/vivado/system.bif" -process_bitstream bin \
        -w -o "$LIBRE_BUILD_DIR/vivado/system_top.bin"
}
firmware() {
    [ "$(uname -s)" = Linux ] || { echo "Tezuka/Buildroot firmware build requires Linux" >&2; exit 1; }
    [ -s "$LIBRE_BUILD_DIR/vivado/system_top.bin" ] || { echo "Build HDL first" >&2; exit 1; }
    need wget
    python3 "$ROOT/tools/libresdr.py" prepare-fw "$FW" "$LIBRE_BUILD_DIR/fw-config"
    (cd "$FW" && ./getbuildroot.sh)
    # getbuildroot.sh verifies its release tarball against buildroot.version.
    export BR2_EXTERNAL="$FW"
    export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" show -s --format=%ct HEAD)}"
    local output="$LIBRE_BUILD_DIR/rootfs"
    make -C "$FW/buildroot" O="$output" \
        BR2_DEFCONFIG="$LIBRE_BUILD_DIR/fw-config/libre_edgeqam_defconfig" defconfig
    make -C "$FW/buildroot" O="$output" -j"${JOBS:-4}" 2>&1 |
        tee "$LIBRE_BUILD_DIR/logs/firmware.log"
    python3 "$ROOT/tools/libresdr.py" package "$output/images/edgeqam-sd" \
        "$LIBRE_BUILD_DIR" "$LIBRE_BUILD_DIR/dist" --epoch "$SOURCE_DATE_EPOCH"
}
case "${1:-all}" in
    deps) deps ;;
    check) python3 "$ROOT/tools/test-libresdr.py" ;;
    csim) deps; csim ;;
    hls) hls ;;
    hdl) deps; hdl ;;
    firmware) deps; firmware ;;
    all)
        [ -z "$(git -C "$ROOT" status --porcelain)" ] || {
            echo "Build a committed clean source tree for a reproducible manifest" >&2; exit 1;
        }
        deps; python3 "$ROOT/tools/test-libresdr.py"; csim; hls; hdl; firmware ;;
    *) echo "usage: $0 [deps|check|csim|hls|hdl|firmware|all]" >&2; exit 1 ;;
esac
