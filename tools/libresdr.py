#!/usr/bin/env python3
"""GPL-3.0-or-later: pinned LibreSDR staging and verified SD packaging."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
LOCK = json.loads((ROOT / "tools/libresdr-lock.json").read_text())
FILES = ("BOOT.bin", "uImage", "devicetree.dtb", "system_top.bin",
         "uramdisk.image.xz", "edgeqam.conf", "uEnv.txt", "LICENSE")


def sha256(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"Pinned upstream layout changed: expected one {old!r}")
    return text.replace(old, new)


def prepare_hdl(maia, output):
    board = maia / "maia-hdl/projects/boards/libre"
    top = (board / "system_top.v").read_text()
    # Pinned top references four implicit GPIOs and pads an 18-bit bus to 25.
    top = replace_once(top, "  output          spi_csn,", """  inout           gpio_ext0,
  inout           gpio_ext1,
  inout           gpio_ext2,
  inout           gpio_ext3,
  output          spi_csn,""")
    top = replace_once(top, ".DATA_WIDTH(25)", ".DATA_WIDTH(18)")
    top = replace_once(top, "  assign eth_rst_n = 1'b1;",
                       "  // Ethernet reset is on PS7 MIO46 (upstream LibreSDR ps7.tcl).")
    top = replace_once(top, "  assign tx_amp_en = 1'b1;", """  // The pinned top's tx_amp_en was an implicit, unrouted net.
  // No amplifier package pin exists in the pinned LibreSDR constraints.
  // Do not invent a pin: amplifier routing needs board/schematic confirmation.""")
    top = replace_once(top, "  assign gpio_i[16:14] = gpio_o[16:14];",
                       """  assign gpio_i[16:14] = gpio_o[16:14];
  assign gpio_i[21:17] = gpio_o[21:17];
  assign gpio_i[63:26] = gpio_o[63:26];""")
    # Delete only obsolete, absent ports, not a single active LibreSDR pin.
    # The obsolete aliases also conflict with the external GPIO pins.
    stale_ports = {"iic_scl", "iic_sda", "clkout_in", "pl_spi_clk_o",
                   "pl_spi_miso", "pl_spi_mosi"}
    lines = []
    removed = []
    for line in (board / "system_constr.xdc").read_text().splitlines():
        port = re.search(r"\[get_ports (\w+)\]", line)
        if not line.lstrip().startswith("#") and (
                (port and port.group(1) in stale_ports) or
                "manual_decim/U0" in line):
            removed.append(line)
        else:
            lines.append(line)
    if len(removed) != 7:
        raise ValueError("Expected six stale port constraints and manual_decim exception")
    output.mkdir(parents=True, exist_ok=True)
    (output / "system_top.v").write_text(top)
    (output / "system_constr.xdc").write_text("\n".join(lines) + "\n")
    shutil.copyfile(ROOT / "src/hdl/libre_edgeqam/system_bd.tcl", output / "system_bd.tcl")
    provenance = {
        "board": "libre", "maia_commit": LOCK["maia"]["commit"],
        "part": LOCK["part"],
        "upstream_top_sha256": sha256(board / "system_top.v"),
        "upstream_constraints_sha256": sha256(board / "system_constr.xdc"),
        "staged_top_sha256": sha256(output / "system_top.v"),
        "staged_constraints_sha256": sha256(output / "system_constr.xdc"),
        "removed_stale_constraints": removed,
        "amplifier_enable": "unresolved: upstream tx_amp_en has no port or package pin"
    }
    (output / "board-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")


def set_config(text, values):
    keys = set(values)
    lines = [line for line in text.splitlines()
             if not any(line.startswith(key + "=") or line == f"# {key} is not set"
                        for key in keys)]
    lines.extend(f'{key}={value}' for key, value in values.items())
    return "\n".join(lines) + "\n"


def prepare_fw(firmware, output):
    text = (firmware / "configs/libre_maiasdr_defconfig").read_text()
    q = lambda value: json.dumps(str(value))
    values = {
        "BR2_TARGET_GENERIC_HOSTNAME": q("libre-edgeqam"),
        "BR2_SYSTEM_DHCP": q("eth0"),
        "BR2_ROOTFS_OVERLAY": q(ROOT / "src/rootfs/libresdr"),
        "BR2_ROOTFS_POST_BUILD_SCRIPT": q(ROOT / "tools/libresdr-post-build.sh"),
        "BR2_ROOTFS_POST_IMAGE_SCRIPT": q(ROOT / "tools/libresdr-post-image.sh"),
        "BR2_ROOTFS_POST_IMAGE_SCRIPT_ARGS": q(""),
        "BR2_LINUX_KERNEL_ZIMAGE": "n",
        "BR2_LINUX_KERNEL_IMAGE": "y",
        "BR2_LINUX_KERNEL_CUSTOM_DTS_PATH": q(
            f"{output / 'zynq-libre.dts'} "
            f"{firmware / 'board/tezuka/libre/dts/zynq-libre.dtsi'} "
            f"{firmware / 'board/tezuka/libre/dts/zynq-7000.dtsi'}"),
        "BR2_PACKAGE_MAIASDR_FW": "n",
        "BR2_PACKAGE_MAIA_KMOD": "n",
        "BR2_PACKAGE_MAIA_HTTPD": "n",
        "BR2_PACKAGE_MAIA_WASM": "n",
        "BR2_PACKAGE_TEZUKA_COMMON_TOOLS": "n",
        "BR2_PACKAGE_TEZUKA_COMMON_TOOLS_MINI": "n",
        "BR2_PACKAGE_DATV": "n",
        "BR2_PACKAGE_BOARD_FPGA": "n",
        "BR2_PACKAGE_HOST_BOOTGEN": "n",
        "BR2_TARGET_ROOTFS_CPIO_UIMAGE": "n",
        "BR2_PACKAGE_BUSYBOX_SHOW_OTHERS": "y"
    }
    output.mkdir(parents=True, exist_ok=True)
    (output / "libre_edgeqam_defconfig").write_text(set_config(text, values))
    # Keep radio/DMA addresses and interrupts unchanged; absent fabric must not bind.
    dts = (firmware / "board/tezuka/libre/dts/zynq-libre.dts").read_text()
    dts += """
/* Dedicated edgeQAM: these Maia registers do not exist in the FPGA. */
&maia_sdr { status = "disabled"; };
&maia_sdr_recording { status = "disabled"; };
&maia_sdr_spectrometer { status = "disabled"; };
/ {
    maia-sdr-recording { status = "disabled"; };
    maia-sdr-spectrometer { status = "disabled"; };
};
"""
    (output / "zynq-libre.dts").write_text(dts)


def verify_archive(archive):
    with zipfile.ZipFile(archive) as z:
        names = z.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Duplicate archive entries")
        for name in names:
            path = Path(name)
            if path.is_absolute() or ".." in path.parts or "/" in name or "\\" in name:
                raise ValueError(f"Archive must have flat, safe SD paths: {name}")
        if z.testzip():
            raise ValueError("ZIP CRC failure")
        if not set(FILES + ("build-manifest.json",)).issubset(names):
            raise ValueError("Missing required boot/config/manifest file")
        for name in FILES:
            if not z.getinfo(name).file_size:
                raise ValueError(f"Empty {name}")
        manifest = json.loads(z.read("build-manifest.json"))
        if manifest["part"] != LOCK["part"] or manifest["board"] != "LibreSDR":
            raise ValueError("Wrong target board/part")
        if manifest["dependencies"] != LOCK:
            raise ValueError("Dependency pins differ from lock")
        for name in FILES:
            if hashlib.sha256(z.read(name)).hexdigest() != manifest["files"][name]:
                raise ValueError(f"Hash mismatch: {name}")
        if manifest["validation"]["hardware_rf"] != "not performed":
            raise ValueError("This build script cannot certify hardware/RF validation")
        if manifest["validation"].get("timing") != "closed" or \
                manifest["validation"].get("csim", {}).get("mismatches") != 0:
            raise ValueError("Missing timing closure or bit-exact C simulation evidence")
        return manifest


def package(sd, build, destination, epoch):
    for name in FILES:
        if not (sd / name).is_file() or not (sd / name).stat().st_size:
            raise ValueError(f"Missing or empty {name}; refusing partial firmware")
    reports = build / "vivado/reports"
    for name in ("timing-closed.txt", "timing.rpt", "utilization.rpt"):
        if not (reports / name).is_file() or not (reports / name).stat().st_size:
            raise ValueError(f"Missing timing/utilization evidence: {name}")
    csim = build / "csim/bit-exact.json"
    if not csim.is_file() or json.loads(csim.read_text())["mismatches"] != 0:
        raise ValueError("Missing successful bit-exact v1 regression")
    manifest = {
        "board": "LibreSDR", "part": LOCK["part"], "dependencies": LOCK,
        "source_commit": subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip(),
        "source_date_epoch": epoch,
        "profile": {"multiplexes": 1, "mode": "2k", "bandwidth_hz": 8000000,
                    "qam": 64, "fec": "7/8", "guard": "1/32", "hierarchy": "none",
                    "udp_port": 1001, "ts_rate_bps": 31668449.197860964},
        "validation": {"csim": json.loads(csim.read_text()), "timing": "closed",
                       "hardware_rf": "not performed"},
        "reports": {name: sha256(reports / name) for name in
                    ("timing-closed.txt", "timing.rpt", "utilization.rpt")},
        "files": {name: sha256(sd / name) for name in FILES},
        "board_provenance": json.loads((build / "vivado/board-provenance.json").read_text())
    }
    encoded = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / "DVB-Tx_edge-QAM-libresdr-v1-sd.zip"
    date = time.gmtime(max(epoch, 315532800))[:6]
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as z:
        for name in sorted(FILES + ("build-manifest.json",)):
            item = zipfile.ZipInfo(name, date_time=date)
            item.compress_type = zipfile.ZIP_DEFLATED
            item.external_attr = 0o100644 << 16
            z.writestr(item, encoded if name == "build-manifest.json" else (sd / name).read_bytes())
    verify_archive(archive)
    (destination / "DVB-Tx_edge-QAM-libresdr-v1-build-manifest.json").write_bytes(encoded)
    (destination / (archive.name + ".sha256")).write_text(f"{sha256(archive)}  {archive.name}\n")
    print(f"Verified {archive}")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    subs = p.add_subparsers(dest="command", required=True)
    for cmd in ("prepare-hdl", "prepare-fw"):
        s = subs.add_parser(cmd)
        s.add_argument("dependency", type=Path)
        s.add_argument("output", type=Path)
    s = subs.add_parser("package")
    for name in ("sd", "build", "destination"):
        s.add_argument(name, type=Path)
    s.add_argument("--epoch", type=int, required=True)
    s = subs.add_parser("verify")
    s.add_argument("archive", type=Path)
    args = p.parse_args()
    if args.command == "prepare-hdl":
        prepare_hdl(args.dependency, args.output)
    elif args.command == "prepare-fw":
        prepare_fw(args.dependency, args.output)
    elif args.command == "package":
        package(args.sd, args.build, args.destination, args.epoch)
    else:
        verify_archive(args.archive)
        print(f"Verified {args.archive}")


if __name__ == "__main__":
    main()
