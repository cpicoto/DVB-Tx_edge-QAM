#!/usr/bin/env python3
"""GPL-3.0-or-later: non-Xilinx tests, never a substitute for C/RTL simulation."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("libresdr", ROOT / "tools/libresdr.py")
libre = importlib.util.module_from_spec(spec)
spec.loader.exec_module(libre)


def generate_ts(path):
    # Deterministic non-null PID, packet continuity, non-repeating PRBS payload.
    state = 0x13579BDF
    packets = bytearray()
    for n in range(4096):
        packets.extend((0x47, 0x01, 0x00, 0x10 | (n & 15)))
        for _ in range(184):
            state ^= (state << 13) & 0xFFFFFFFF
            state ^= state >> 17
            state ^= (state << 5) & 0xFFFFFFFF
            state &= 0xFFFFFFFF
            packets.append(state & 255)
    path.write_bytes(packets)


class PortTests(unittest.TestCase):
    def test_profile_native_both_targets(self):
        cc = os.environ.get("CC", "cc")
        with tempfile.TemporaryDirectory() as tmp:
            for flags in ([], ["-DLIBRESDR_V1"]):
                binary = Path(tmp) / "profile"
                subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", *flags,
                                str(ROOT / "tests/libresdr_profile.c"), "-o", str(binary)],
                               check=True)
                subprocess.run([str(binary)], check=True)

    def test_fixed_target_sources(self):
        project = (ROOT / "src/hdl/libre_edgeqam/system_project.tcl").read_text()
        bd = (ROOT / "src/hdl/libre_edgeqam/system_bd.tcl").read_text()
        hls = (ROOT / "src/hls/v1/run_hls.tcl").read_text()
        self.assertIn('set p_device "xc7z020clg400-2"', project)
        self.assertIn("set_part xc7z020clg400-2", hls)
        self.assertIn("adi_project libre_edgeqam", project)
        for source in ("ps7.tcl", "ports.tcl", "vcxo_ctrl.tcl"):
            self.assertIn(f"boards/libre/{source}", bd)
        self.assertIn("common/xilinx_ad9361.tcl", bd)
        self.assertIn("CONFIG.SINGLE_MUX 1", bd)
        self.assertIn("edgeqam:libre:dvbt_mod_v1:1.0", bd)
        self.assertIn("get_timing_paths -$kind", project)
        self.assertIn("reports/utilization.rpt", project)
        for forbidden in ("fishball", "/v3", "common/maia.tcl", "common/dvb.tcl"):
            self.assertNotIn(forbidden, project + bd + hls)

    def test_upstream_repairs_are_checked(self):
        # Unit fixture, not downloaded HDL or a generated FPGA artifact.
        self.assertEqual(libre.replace_once("a legacy b", "legacy", "fixed"), "a fixed b")
        for text in ("absent", "legacy legacy"):
            with self.assertRaises(ValueError):
                libre.replace_once(text, "legacy", "fixed")

    def test_prepare_board_fixture(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            board = tmp / "maia/maia-hdl/projects/boards/libre"
            board.mkdir(parents=True)
            (board / "system_top.v").write_text(
                "  output          spi_csn,\n.DATA_WIDTH(25)\n"
                "  assign eth_rst_n = 1'b1;\n  assign tx_amp_en = 1'b1;\n"
                "  assign gpio_i[16:14] = gpio_o[16:14];\n")
            stale = ("iic_scl", "iic_sda", "clkout_in", "pl_spi_clk_o",
                     "pl_spi_miso", "pl_spi_mosi")
            active = "set_property PACKAGE_PIN N20 [get_ports rx_clk_in_p]"
            (board / "system_constr.xdc").write_text(active + "\n" + "\n".join(
                f"set_property PACKAGE_PIN unused [get_ports {s}]" for s in stale) +
                "\nset_false_path -from [get_pins manual_decim/U0/fake]\n")
            output = tmp / "output"
            libre.prepare_hdl(tmp / "maia", output)
            self.assertEqual((output / "system_constr.xdc").read_text(), active + "\n")
            provenance = json.loads((output / "board-provenance.json").read_text())
            self.assertEqual(provenance["board"], "libre")
            self.assertIn("unresolved", provenance["amplifier_enable"])
            self.assertIn(".DATA_WIDTH(18)", (output / "system_top.v").read_text())

    def test_kconfig_override(self):
        result = libre.set_config('A="old"\n# B is not set\nC=y\n',
                                  {"A": '"new"', "B": "y"})
        self.assertEqual(result, 'C=y\nA="new"\nB=y\n')

    def test_missing_or_unsafe_archive_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "test-fixture.zip"
            for names in (["BOOT.bin"], ["../BOOT.bin"], ["/BOOT.bin"], ["sd/BOOT.bin"]):
                with zipfile.ZipFile(archive, "w") as z:
                    for name in names:
                        z.writestr(name, b"unit test fixture, not boot firmware")
                with self.assertRaises(ValueError):
                    libre.verify_archive(archive)

    def test_archive_hash_mismatch_rejected(self):
        manifest = {"part": libre.LOCK["part"], "board": "LibreSDR",
                    "dependencies": libre.LOCK, "files": {n: "bad" for n in libre.FILES},
                    "validation": {"hardware_rf": "not performed"}}
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "test-fixture.zip"
            with zipfile.ZipFile(archive, "w") as z:
                for name in libre.FILES:
                    z.writestr(name, b"unit test fixture, not boot firmware")
                z.writestr("build-manifest.json", json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, "Hash mismatch"):
                libre.verify_archive(archive)

    def test_packaging_refuses_missing_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            with self.assertRaisesRegex(ValueError, "Missing or empty"):
                libre.package(tmp, tmp, tmp / "dist", 0)
            self.assertFalse((tmp / "dist").exists())

    def test_overlay_defaults_and_shell_syntax(self):
        conf = (ROOT / "src/rootfs/libresdr/boot/edgeqam.conf").read_text()
        self.assertIn("NMUX=1\n", conf)
        self.assertIn("INPUT0=udp:1001\n", conf)
        self.assertIn("ATT=89.75\n", conf)
        scripts = [ROOT / "tools/build-libresdr.sh",
                   ROOT / "tools/libresdr-post-build.sh",
                   ROOT / "tools/libresdr-post-image.sh",
                   ROOT / "src/rootfs/libresdr/etc/init.d/S99edgeqam",
                   ROOT / "src/rootfs/libresdr/etc/init.d/S20fat-mount"]
        for script in scripts:
            subprocess.run(["bash" if script.name == "build-libresdr.sh" else "sh",
                            "-n", str(script)], check=True)
        service = scripts[-2].read_text()
        self.assertNotIn("eval", service)
        self.assertNotIn("killall", service)

    def test_deterministic_ts(self):
        with tempfile.TemporaryDirectory() as tmp:
            a, b = Path(tmp) / "a.ts", Path(tmp) / "b.ts"
            generate_ts(a)
            generate_ts(b)
            self.assertEqual(a.read_bytes(), b.read_bytes())
            packets = a.read_bytes()
            self.assertEqual(len(packets), 4096 * 188)
            self.assertTrue(all(packets[n] == 0x47 for n in range(0, len(packets), 188)))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generate-ts", type=Path)
    args = parser.parse_args()
    if args.generate_ts:
        generate_ts(args.generate_ts)
    else:
        unittest.main(argv=[__file__], verbosity=2)
