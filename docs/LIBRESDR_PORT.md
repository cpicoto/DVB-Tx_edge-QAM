# LibreSDR v1 DVB-T transmitter port

This is a **source implementation, not a hardware-validated firmware release**.
It uses the existing `src/hls/v1` coding/IFFT core without changing its modem
parameters. Fishball firmware and measurements are **not evidence for LibreSDR**.

## Current build status

The development environment is macOS and has no Vivado, Vitis HLS, XSCT or ARM
Linux cross-compiler. The non-Xilinx suite (`python3 tools/test-libresdr.py`,
10 tests including native profile checks and static checks of the LibreSDR
constraints, Zynq-7020 part and archive verification) passes on macOS.
The v1 HLS C simulation (`csim`), synthesis and implementation were **not run**
because Vitis HLS/Vivado are unavailable here.
No LibreSDR bitstream, FSBL, SD ZIP, timing
report, utilization report or artifact hash has been generated.

There is an additional **board wiring blocker**: the pinned Maia LibreSDR
`system_top.v` assigns `tx_amp_en` as an implicit net, but does not declare a
top-level output and its LibreSDR XDC does not assign an amplifier-enable pin.
That assignment cannot drive a physical amplifier. This port records the
omission rather than guessing a pin. Confirm the amplifier-enable circuit and
its connection on the actual LibreSDR revision against its schematic, implement
the verified routing/control, and review it before hardware/RF use. Thus this
milestone does **not yet satisfy physical TX amplifier-enable validation**.

## Architecture and data path

```text
MPEG-TS / UDP 1001
  -> Linux dvbt_tx (one input ring; missing packets become null TS)
  -> libiio cf-ad9361-dds-core-lpc / standard TX DMA
  -> dvbt_bridge TS asynchronous FIFO / 64-to-32-bit serializer
  -> dvbt_mod_v1 @ 100 MHz
     PRBS -> RS -> Forney -> FEC 7/8 -> interleavers -> 64-QAM
     -> pilots/TPS -> 2048-point IFFT -> 64-sample guard interval
  -> dvbt_bridge IQ asynchronous FIFO
  -> ADI DAC FIFO -> axi_ad9361 LVDS -> AD9361 TX1A
```

The dedicated project is `src/hdl/libre_edgeqam`, not the Fishball project.
It sources only Maia's pinned `boards/libre/{ps7,ports,vcxo_ctrl}.tcl`,
`common/xilinx_ad9361.tcl`, and `common/minimal.tcl`. RX FIFO/packing/DMA
remain for AD9361 driver compatibility and digital-interface calibration.
There is no Maia spectrum/recording fabric, TX FIR, correction NCO, other modem,
or receiver implementation. Linux's two Maia application nodes and its UIO node
are disabled in the generated device-tree source.

The upstream LibreSDR top-level and XDC are staged into `build/vivado`, never
overwritten in Maia. Staging repairs four undeclared external GPIOs, changes
the incorrectly padded 25-bit IOBUF to its actual 18-bit bus, and ties unused
GPIO inputs to their outputs. Six constraints for absent/aliased legacy ports
and one absent `manual_decim` timing exception are removed. **All active
LibreSDR pin assignments are retained**. A provenance JSON records upstream and
staged file hashes and the exact constraint removals. Ethernet reset stays
in the upstream PS7 MIO46 configuration; reference/PPS/DAC tuning and LVDS pins
come from LibreSDR, not Fishball.

| Interface | Tezuka address / interrupt |
|---|---|
| AD9361 ADC core | `0x79020000` |
| AD9361 DAC / GPIO registers | `0x79024000`; status `+0xB8`, control `+0xBC` |
| RX DMA | `0x7C400000`, PS interrupt 13 / device-tree SPI 57 |
| TX DMA | `0x7C420000`, PS interrupt 12 / device-tree SPI 56 |
| LibreSDR VCTCXO controller | `0x43C00000` |

These mappings are sourced unchanged from Tezuka/Maia. RX DMA uses HP1,
TX DMA uses HP2 as in Maia's minimal infrastructure. DDS is retained for the
AD9361 driver's digital tuning; transmitting selects the DMA path.

`dvbt_bridge` still bypasses the modem when control bit 1 is clear. On this
project only, its `SINGLE_MUX=1` parameter synchronizes mute bit 8 into the DAC
clock domain and outputs zero IQ while continuing to consume samples. This
preserves `/set?disable=1` without needing the multi-multiplex HLS control
stream, and avoids sending TS words to the RF DAC as if they were IQ.

## Pins, tools and dependencies

`tools/libresdr-lock.json` is the source of truth:

| Dependency | Exact revision |
|---|---|
| `F5OEO/maia-sdr`, `refactor` | `ba62a78084d1d7f4465ddde25a23a75bcf8c6f2d` |
| `F5OEO/tezuka_fw` | `49403b9899903cd740a6e0286af5f82098d51023` |
| Maia's ADI HDL submodule | `cf81ab15cdb1376982b53827a9aa3db01297eecc` |
| Independent `TrusterBSW/DVB-Tx` C reference | `0f48e124f6c6870d9cf365a4f8b52c5efc9cb9e2` |
| Unchanged repository v1 regression baseline | `9e2a797a03fff36f1d8f5bc889258aaca0b6c01b` |

Target: **XC7Z020CLG400-2, AD9361 LVDS**. Use **Vivado, Vitis HLS and Vitis/XSCT
2023.1**, including its `bootgen`. The pinned ADI repository defaults to 2023.2;
the build explicitly selects 2023.1 rather than bypassing all version checks.
Compatibility of that pin with 2023.1 remains to be confirmed by actual builds.
The firmware wrapper pins Buildroot **2026.05.2** and verifies its release
tarball using `buildroot.version`. Kernel and U-Boot tarball revisions and
Bootlin ARM toolchain selection are inherited from the pinned LibreSDR
defconfig, not selected from upstream HEAD.

Use a Linux x86-64 build host supported by Xilinx 2023.1, Python **3.11+**, Bash,
Git, Make, `pkg-config`, FFTW3 single-precision development files, and the
standard Buildroot host prerequisites. Python/host-profile unit tests can also
run on macOS. Build paths must not contain whitespace.

## Building

After the wiring blocker above is resolved and the Xilinx tools are installed:

```bash
source /opt/Xilinx/Vivado/2023.1/settings64.sh
source /opt/Xilinx/Vitis/2023.1/settings64.sh
chmod +x tools/build-libresdr.sh tools/libresdr-post-*.sh
chmod +x src/rootfs/libresdr/etc/init.d/*
bash tools/build-libresdr.sh all
```

`all` downloads and checks exact dependency commits, runs non-Xilinx tests,
generates deterministic TS and an independent C reference, runs v1 C simulation,
exports the reusable HLS IP, builds ADI libraries and the dedicated Vivado
project, creates a **new LibreSDR FSBL from that project's XSA**, converts its
bitstream to `system_top.bin`, cross-compiles the daemon in Buildroot's
post-build hook, and builds a dedicated Tezuka ramdisk and SD archive.

For individual stages:

```bash
bash tools/build-libresdr.sh deps
bash tools/build-libresdr.sh check
bash tools/build-libresdr.sh csim
bash tools/build-libresdr.sh hls
bash tools/build-libresdr.sh hdl
bash tools/build-libresdr.sh firmware
```

`LIBRE_BUILD_DIR` defaults to this checkout's `build/`; `JOBS` defaults to 4.
Choose a fresh `LIBRE_BUILD_DIR` for a different source revision. Existing
dependency checkouts at different commits or with tracked modifications are
rejected, not reset. Do not substitute an upstream/prebuilt FSBL, XSA, BOOT.bin
or Fishball release ZIP. Buildroot downloads and builds the cross-toolchain;
there is no need to provide an unrelated ARM sysroot.

The v1 testbench's original floating-reference SNR check does **not** prove
bit-exact IQ. The new `csim` stage also simulates the pinned unchanged v1
baseline with the same TS/reference inputs and compares **every signed
16-bit I/Q component**, including startup, over 150 OFDM symbols (1,267,200
output bytes). It rejects any mismatch, missing/trailing baseline data, invalid
reference power, sync error, unexpected null packet or post-startup overflow.
The baseline and candidate IQ hashes are recorded in `csim/bit-exact.json`.
This proves port regression equality, not equality to a floating-point FFT;
the independent DVB-T reference check separately retains the existing
quantization-aware 40 dB SNR threshold.

Vivado synthesis and implementation must finish and meet setup/hold timing.
The script saves `reports/{timing,utilization,cdc,clock_interaction,drc}.rpt`,
and only writes a timing-closure marker after querying timing paths. Packaging
requires this marker, nonempty timing/utilization reports and successful
bit-exact regression evidence. Inspect CDC and unconstrained paths yourself:
report generation is not hardware validation, and a report's existence does
not replace engineering review of its contents.

Expected outputs **only after a successful build**:

```text
build/dist/DVB-Tx_edge-QAM-libresdr-v1-sd.zip
build/dist/DVB-Tx_edge-QAM-libresdr-v1-sd.zip.sha256
build/dist/DVB-Tx_edge-QAM-libresdr-v1-build-manifest.json
build/vivado/reports/
build/logs/
```

The flat SD ZIP contains `BOOT.bin`, `uImage`, `devicetree.dtb`,
`system_top.bin`, `uramdisk.image.xz`, `edgeqam.conf`, `uEnv.txt`, `LICENSE`,
and `build-manifest.json`. The manifest includes dependency/source revisions,
the DVB-T profile, file hashes, board-source provenance and validation evidence.
ZIP entry ordering, timestamps and permissions are deterministic; a pinned
build recipe does not guarantee bit-for-bit Xilinx/Buildroot reproducibility
across different hosts. The SHA-256 file hashes the ZIP itself.

```bash
cd build/dist
sha256sum -c DVB-Tx_edge-QAM-libresdr-v1-sd.zip.sha256
python3 ../../tools/libresdr.py verify DVB-Tx_edge-QAM-libresdr-v1-sd.zip
```

Verification rejects missing/empty required files, unsafe or duplicate paths,
wrong dependency/part identity, corrupt ZIP data, and per-file hash mismatches.

## SD-card installation and rollback

1. Power down. Back up the **entire previous LibreSDR SD card** and its settings.
   Keep the old card intact for rollback. Do not use the Fishball image here.
2. Use a separate card with a FAT32 first partition. Verify the generated ZIP
   and extract its flat contents into the partition root.
3. Leave `ENABLE=0` and `ATT=89.75` for the first boot. Connect Ethernet and a
   serial console, select the board's SD boot mode, and power up.
4. Confirm Linux boots with the dedicated bitstream, AD9361 initializes and
   digital tuning succeeds. Check `dmesg`, IIO names and the 40 MHz reference.
   Resolve amplifier wiring and complete the checklist before enabling RF.
5. With the closed-coax setup ready, edit `/boot/edgeqam.conf` to `ENABLE=1`
   and start `/etc/init.d/S99edgeqam start`.

`BOOT.bin` contains only the newly built FSBL plus U-Boot. The dedicated
`uEnv.txt` loads **this** `system_top.bin` before Linux, forces AD9361/1R1T,
and loads the matching kernel, DTB and ramdisk. On load failure it refuses
fallback firmware. The rootfs mounts the FAT partition at `/boot`, where
settings and API saves persist. No QSPI update image is produced or written.

To roll back, stop the transmitter, power down and restore the old LibreSDR
card/complete card contents and SD boot selection. Do not mix kernel/DTB,
FSBL or bitstream files from different releases.

## Fixed profile, UDP and HTTP

Exactly **one** multiplex: DVB-T 2K, 8 MHz, 64-QAM, FEC 7/8, GI 1/32,
non-hierarchical, 1705 active carriers, 2048 IFFT samples plus 64 guard samples.
IQ rate is nominally **64/7 MS/s = 9,142,857.143 S/s** (integer radio request:
9,142,857); OFDM rate is approximately **4329.004 symbols/s**. TS rate is
**31,668,449.2 bit/s**, rounded to `31668449` for senders, subject to the
board reference oscillator. There is no 6 MHz/QPSK/1/2 WW7ATS profile.

Configuration defaults:

| Key | Value |
|---|---|
| `ENABLE` | `0`, deliberate safe commissioning default |
| `NMUX` | `1`, other values rejected |
| `FREQ` | `474000000` Hz, same multiplex and LO centre |
| `ATT` | `89.75` dB, maximum TX attenuation |
| `DISABLE` | `0`; `1` mutes this multiplex's IQ |
| `INPUT0` | `udp:1001` |
| `HTTP_PORT` | `8080` |

`dvbt_tx` is compiled with `-DLIBRESDR_V1`; other boards retain their existing
multi-mux build. The LibreSDR binary defaults to one input on UDP 1001 even
without positional arguments. It refuses additional inputs and `-n 2`/`-n 4`.
It retains file and multicast input syntax and the existing simple RTP support.
Send TS in whole 188-byte packets, normally 7 packets/1316 bytes per datagram.
The daemon does not multiplex elementary streams, repair PCRs or authenticate
HTTP requests. mDNS advertising is not included in this first dedicated image.

For an already muxed, constant-rate TS file:

```bash
tsp -I file --infinite channel.ts -P regulate -O ip 192.168.1.50:1001
curl http://192.168.1.50:8080/status
curl 'http://192.168.1.50:8080/set?freq=474000000&att=89.75&disable=0&save=1'
curl 'http://192.168.1.50:8080/set?disable=1'
```

`/status` preserves the existing JSON status/input/counter API (including the
legacy `temp_ad9363_c` key). `/set` preserves frequency, attenuation, single-mux
disable and configuration persistence. Configure only over a trusted isolated
wired network; this API has no authentication. Daemon startup first sets maximum
attenuation, configures and reads back the radio, then enables TX; shutdown
restores maximum attenuation. The service reports a failed start instead of
running an unbounded silent restart loop.

## Safe closed-coax test and hardware checklist

**Never attach a transmit antenna.** Use an isolated, terminated 50-ohm coax
path with rated fixed attenuation between TX1A and a suitably protected DVB-T
receiver/analyzer. Check the receiver's maximum input rating and the board's
worst-case TX/amplifier power; size attenuators and termination accordingly.
Start with maximum software attenuation plus sufficient fixed attenuation.
If board/amplifier power or the wiring is unknown, **do not enable transmission**.
Change level gradually while measuring the actual receiver input; do not
assume an attenuation setting establishes a safe RF power.

- [ ] Confirm exact board revision, XC7Z020CLG400-2, AD9361 and amplifier wiring.
- [ ] Review generated top/XDC provenance and all repaired GPIO mappings.
- [ ] Build in 2023.1; pass 150-symbol reference and integer-baseline C simulation.
- [ ] Inspect HLS performance: sustain 2112 samples per approximately 23,100 CPU
      clock cycles at 100 MHz; inspect FIFOs and initiation interval.
- [ ] Close setup/hold timing; review utilization, unconstrained paths, CDC and DRC.
- [ ] Verify hashes, flat SD contents and matching FSBL/bitstream/DTB.
- [ ] Boot from SD without touching QSPI; demonstrate rollback with the old card.
- [ ] Confirm 40 MHz reference, AD9361 LVDS digital tuning and RX DMA compatibility.
- [ ] Verify 1R1T sample format/rate, TX DMA backpressure and correct amplifier control.
- [ ] With safe attenuation, send UDP 1001 at the fixed TS rate; monitor FIFO
      counters, symbols/s, sync errors, overflows and sustained underflows.
- [ ] Check startup transient behavior, missing-input null filling, `/set`,
      mute/unmute, save, stop/restart and `ENABLE=0`.
- [ ] Measure spectrum/occupied bandwidth, output level, MER and TS continuity/BER
      over the coax; verify consumer receiver lock and sustained decoding.
- [ ] Record equipment, attenuation, board revision, hashes, temperatures and duration.

None of these hardware/RF checks has been performed for this port.

## Known limitations and attribution

The amplifier routing blocker, unrun tests and absent Xilinx builds above must
be resolved before treating this as a proven bootable transmitter. The upstream
board repairs, boot flow, lean Linux services, single-mux mute behavior and
Tezuka cross-compilation have not been exercised on a LibreSDR. There is no
automatic RF safety guarantee, network authentication, PCR/rate adaptation,
spectrum UI, multi-mux support, runtime-selectable modem profile, DVB-T2,
receiver logic or WW7ATS mode.

New repository code remains **GPL-3.0-or-later** under the existing `LICENSE`.
The v1 modem is the existing DVB-Tx port; the independent reference comes from
TrusterBSW/DVB-Tx. LibreSDR board/control infrastructure is reused from
F5OEO/Maia/Tezuka and Analog Devices with its upstream notices and licenses
retained in the dependency checkouts and staged top. Staging preserves the
upstream top's copyright/license header and records modifications; it does not
relicense the ADI dependencies.
