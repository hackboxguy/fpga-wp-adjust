# wp_adjust → pixelpipe-fpga Integration Guideline

Date: 2026-06-13
Author: Claude (Fable 5), based on a full read of both repos.
Audience: a fresh Claude Code session (or engineer) executing the integration.

## 0. Purpose

Integrate the `wp_adjust` white-point trim block (this repo, register-map
revision `0x0113`) as the **last pixel-processing stage before the LVDS
transmitter** in the `pixelpipe-fpga` display platform, for both validated
products:

- `autoone_12p3_xc7s50_linglong` — 12.3" 1920×720, 38×14 zones, scan backlight
- `autoone_14p6_xc7s50_linglong` — 14.6" 1920×1080, 42×24 zones, direct backlight

Both share the same FPGA (Spartan-7 `xc7s50csga324-1Q`), board
(`xc7s50_autoone_evb`), top (`top_xc7s50_autoone_fald`), app (`fald`), and
LVDS in/out — so **one integration covers both panels**; only the panel
profile differs, and it does not affect anything wp_adjust touches.

The host-side tooling that will drive this block already exists and is tested
against the register contract in simulate mode: the br-wrapper disp-tester
children (`new-white-point-profile-child.py`, `d65-calibration-child.py`,
`new-white-point-match-child.py`) and this repo's `host/wp_load.py` boot
loader.

> **Read `pixelpipe-fpga/CLAUDE.md` first.** It defines the build flow, the
> hardware-verification discipline (every bitstream change is HW-verified via
> a version bump + Pi4 I2C readback before commit), and several hard-won
> gotchas that apply directly here (GBK-encoded files, `ram_style`,
> surgical `use_dsp`, signoff residuals).

## 1. Executive Summary of the Integration

| Decision | Value | Why |
|---|---|---|
| Insertion point | `boards/xc7s50_autoone_evb/board_xc7s50_autoone_evb.v`, between the app's `i_vout_*` and the `lvds_tx TOP4X2_7TO1_SDR_TX_INST` instance | Board owns I2C + CDC; app and top stay untouched; one diff covers both panels |
| Video format | **PPC=2 dual-pixel, RGB888** → **two `wp_adjust` instances** with `PIXEL_BITS=8`, cfg writes broadcast, rdata from one | `vout_data[47:0]` = two pixels per clock (see §3) |
| Pixel clock | `local_clk` = **67 MHz** (clk_1 MMCM CLKOUT2) | The `i_vout_*` stream and the LVDS TX are in this domain |
| Control clock | `clk_tp` = **50 MHz** (clk_1 MMCM CLKOUT4) | The I2C slaves, OTA, and existing control CDC all live here |
| CDC | This repo's `rtl/wp_adjust_cdc_bridge.v` (`bus_clk=clk_tp`, `pix_clk=local_clk`) | Purpose-built req/ack bridge with verified TB; same MMCM → actually synchronous, but treat as async per repo convention (§7) |
| Host register access | New **page `0x03` on the `0x1E` I2C slave**, byte-addressed at **2 bytes per logical register, big-endian** (`byte_addr = logical<<1`) | Page ≥3 is explicitly reserved in `ipcreg_core.v`; the host scripts already default to `--wp-page 0x03` (one small host fix needed, §6.4) |
| Vsync | Active-high throughout the pipeline → `VSYNC_ACTIVE_HIGH=1` (default) | Confirmed by `video_convert.v` rising-edge detect, `spatial_filter.v` `~i_vsync` reset (§5); still ILA-verify the commit edge lands in blanking |
| Defaults | `GATE_BLANKING=0`, `PIXEL_BITS=8`, `FRAC_BITS=12` | Minimal behavioral change; reset state is exact pass-through |

## 2. pixelpipe-fpga Facts You Need

### 2.1 Architecture and the exact insertion point

The video chain (both panels):

```text
LVDS in → lvds_rx (XAPP585, pixel_clk recovered)
        → app_fald: v_process (tone map, pixel_clk)
                  → pixel_compensation (FALD: blu_init/diffuser/spatial_filter/
                    pixel_apply; internal 156.25 MHz domain; output re-timed)
        → [vout_* : local_clk domain, 48-bit dual-pixel]   ← INSERT wp_adjust HERE
        → lvds_tx (platform/xilinx/lvds_tx.v → top4x2_7to1_sdr_tx, XAPP585 7:1 SDR)
        → panel
```

In `board_xc7s50_autoone_evb.v` the app's output enters the board as ports
`i_vout_vsync/i_vout_hsync/i_vout_de/i_vout_data[47:0]` and is wired
**directly** into the `lvds_tx` instance (`.video_in(i_vout_data)`,
`.de_in(i_vout_de)`, `.hs_in(i_vout_hsync)`, `.vs_in(i_vout_vsync)`, around
line 231). The integration replaces those four connections with the
wp_adjust-processed versions. Nothing else in the video path changes.

Do **not** insert inside `app_fald`: the app speaks only the standard
streams + two control bits (per `docs/component-interfaces.md`), and adding a
register bus to the board↔app seam is a contract change. The board already
owns I2C, OTA, and all control CDC — wp_adjust's cfg port belongs next to
them.

### 2.2 Clocks (from `ip/xilinx/xc7s50/clk_1/clk_1.xci` + `platform/xilinx/clk_gen.v`)

| Clock | Freq | Role |
|---|---:|---|
| `clk_200m` | 200 MHz | IDELAY reference |
| `local_clk` (CLKOUT2) | **67 MHz** | Output/video-out domain — `i_vout_*`, `lvds_tx`, **wp_adjust `clk`** |
| `linglong_clk` (CLKOUT3) | 100 MHz | Backlight driver |
| `clk_tp` (CLKOUT4) | **50 MHz** | I2C slaves, OTA, control CDC — **wp_adjust bridge `bus_clk`** |
| `clk_156p25` | 156.25 MHz | pixel_compensation internals — **not involved here**; it is the timing-critical domain (~-0.2 ns accepted floor), stay out of it |

All four clk_1 outputs come from one MMCM (same-MMCM clocks are grouped in
the XDC), so clk_tp↔local_clk is technically synchronous — but the repo
treats control crossings with explicit CDC + `set_max_delay -datapath_only`
bounds anyway (see the `*_cdc` wildcard constraint in the XDC). Follow that
convention with the wp_adjust bridge.

### 2.3 Build, verification, and discipline

```bash
make CONFIG=autoone_12p3_xc7s50_linglong VERSION=0x4? bitstream
make CONFIG=autoone_14p6_xc7s50_linglong VERSION=0x1? bitstream
make sim-all          # 19 leaf sims — keep green
make report-check     # signoff health; know docs/signoff_residuals.md before judging
```

- 12.3" uses VERSION `0x4x`, 14.6" uses `0x1x` — keep the ranges.
- **Every bitstream change is HW-verified before commit**: bump VERSION,
  build, user flashes, Pi4 reads the version register + checks
  brightness/patterns/dimming, only then commit. Plan the integration as
  multiple small HW-verified steps (§8), not one big drop.
- The timing floor is `WNS ≈ -0.15..-0.3 ns` in the 156.25 MHz domain
  (rotating small paths in `pixel_apply`/`hsv2rgb`). wp_adjust must not make
  this worse — it lives entirely in the 67 MHz domain, so any new 156 MHz
  path after integration is a wiring mistake.
- **GBK-encoded comments**: `blu_init.v` and `pixel_compensation.v` (likely
  others in `rtl/dimming/`) contain non-UTF8 bytes. This integration should
  not need to touch them — if you ever must, follow the byte-safe edit
  procedure in CLAUDE.md.

## 3. Video Format: Dual-Pixel RGB888 → Two wp_adjust Instances

`vout_data[47:0]` carries **two pixels per `local_clk` cycle** (PPC=2 per the
panel profiles; both panels). The packing, decoded from
`top4x2_7to1_sdr_tx.v` (lines ~104-108):

```text
odd pixel  : R = vout_data[ 7: 0], G = vout_data[15: 8], B = vout_data[23:16]
even pixel : R = vout_data[31:24], G = vout_data[39:32], B = vout_data[47:40]
```

wp_adjust processes one pixel per clock, so instantiate it **twice** with
`PIXEL_BITS=8` (within the supported [4,15] guard range; `FRAC_BITS=12`
keeps Q4.12 and the host contract unchanged):

```verilog
wire [47:0] wp_vout_data;
wire        wp_vout_de, wp_vout_hs, wp_vout_vs;
wire        wp_de_nc, wp_hs_nc, wp_vs_nc;   // even instance sync outputs unused
wire [15:0] wp_cfg_rdata;

// odd pixel — also owns the sync delay path and the cfg readback
wp_adjust #(.PIXEL_BITS(8), .FRAC_BITS(12)) u_wp_adjust_odd (
    .clk(local_clk), .rst_n(rst_n),
    .in_r(i_vout_data[ 7: 0]), .in_g(i_vout_data[15: 8]), .in_b(i_vout_data[23:16]),
    .in_de(i_vout_de), .in_hsync(i_vout_hsync), .in_vsync(i_vout_vsync),
    .out_r(wp_vout_data[ 7: 0]), .out_g(wp_vout_data[15: 8]), .out_b(wp_vout_data[23:16]),
    .out_de(wp_vout_de), .out_hsync(wp_vout_hs), .out_vsync(wp_vout_vs),
    .cfg_wr_en(wp_cfg_wr_en), .cfg_addr(wp_cfg_addr),
    .cfg_wdata(wp_cfg_wdata), .cfg_rdata(wp_cfg_rdata)
);

// even pixel — identical cfg stream; rdata unconnected
wp_adjust #(.PIXEL_BITS(8), .FRAC_BITS(12)) u_wp_adjust_even (
    .clk(local_clk), .rst_n(rst_n),
    .in_r(i_vout_data[31:24]), .in_g(i_vout_data[39:32]), .in_b(i_vout_data[47:40]),
    .in_de(i_vout_de), .in_hsync(i_vout_hsync), .in_vsync(i_vout_vsync),
    .out_r(wp_vout_data[31:24]), .out_g(wp_vout_data[39:32]), .out_b(wp_vout_data[47:40]),
    .out_de(wp_de_nc), .out_hsync(wp_hs_nc), .out_vsync(wp_vs_nc),
    .cfg_wr_en(wp_cfg_wr_en), .cfg_addr(wp_cfg_addr),
    .cfg_wdata(wp_cfg_wdata), .cfg_rdata()
);
```

Then point the `lvds_tx` instance at `wp_vout_data / wp_vout_de / wp_vout_hs
/ wp_vout_vs` instead of `i_vout_*`.

**Why broadcast-cfg is coherent:** both instances share clk, reset, the
identical cfg write stream, and the identical `in_vsync` — so their
shadow/active registers and commit consumption are cycle-identical by
construction. STATUS/readback from the odd instance is authoritative for
both. (Do not "optimize" by sharing one register file between datapaths
unless you also restructure wp_adjust; two instances is ~tens of LUTs+FFs of
redundancy and zero new verification surface.)

Latency: the whole output frame (data + DE/HS/VS uniformly) shifts by 2
`local_clk` cycles. The LVDS TX serializes data+syncs together, so the output
stream stays self-consistent; the panel cannot observe the shift.

## 4. Where the Block Files Go

Vendor the two RTL files from this repo (fpga-wp-adjust) into pixelpipe-fpga
— do not submodule (the repo vendors all RTL):

```text
pixelpipe-fpga/rtl/video_proc/wp_adjust/wp_adjust.v             (rev 0x0113)
pixelpipe-fpga/rtl/video_proc/wp_adjust/wp_adjust_cdc_bridge.v
pixelpipe-fpga/rtl/ctrl/i2c/source/wp_page3_adapter.v           (new, §6.2)
```

Add a provenance header noting the source repo + register-map revision, and
add the files to `boards/xc7s50_autoone_evb/sources.tcl` (`lappend rtl_files
...`) — the board fragment is shared by both configs, so both builds pick
them up.

Sims: wp_adjust's own self-checking benches live in fpga-wp-adjust
(`make test` there: directed + randomized co-sim + param sweep + CDC ratio
sweep — all iverilog). Optionally wire `tb_wp_adjust` into pixelpipe's
`sim/tb/` framework so `make sim-all` guards future local edits; at minimum,
record in the commit that the source-repo suite passed. wp_adjust is
vendor-neutral Verilog-2001 and can join `make yosys-lint`.

## 5. Vsync Polarity and the Commit Edge

Evidence that vsync is **active-high** at the insertion point:

- `rtl/video_proc/video_convert.v`: `vsync_rising = vsync_ff0 && !vsync_ff1`
  used as the frame event.
- `rtl/dimming/spatial_filter.v`: `.rst_n(~i_vsync)` — vsync high = reset
  pulse.
- `rtl/dimming/pixel_apply.v`: `else if (i_vsync)` counter resets.

So keep `VSYNC_ACTIVE_HIGH=1` (the default). **However**, one thing the RTL
reading cannot settle: where `vout_vsync`'s rising edge sits relative to
`vout_de` at the *output* of `pixel_compensation`. The Lattice PPC2 variant
documents "vout_vsync overlaps the first active vout_de pixel"
(`video_out_lvds6.v` header); if the xc7s50 variant behaves similarly, the
commit (filtered vsync rise + 1 cycle) lands at/just after frame start
instead of inside vertical blanking — meaning the first few pixels of the
commit frame carry old gains. Bring-up checklist item (§8 step 1):

- ILA `vout_vsync`/`vout_de` at the insertion point; confirm the vsync
  rising edge is inside the DE-quiet vertical blanking region.
- If it overlaps active video: either accept (≤1 line of mixed gains, once
  per update, at trim magnitudes this is invisible) or build with
  `VSYNC_ACTIVE_HIGH=0` so the commit fires on the *trailing* edge — but
  only if the ILA shows that edge is in blanking. Decide from the
  measurement, not from this doc.

wp_adjust's 2-cycle vsync glitch filter needs vsync high ≥2 `local_clk`
cycles — a real vsync is thousands of cycles, no concern.

## 6. Host Register Access: 0x1E Page 3

### 6.1 The seam

`i2c_slave_v2` (clk_tp domain) exposes a generic byte bus: `reg_page[7:0]`,
`reg_addr[7:0]`, `reg_we` (1-cycle strobe, data bytes only), `reg_wdata[7:0]`,
`reg_rdata[7:0]` (combinational read mux), with auto-increment of `reg_addr`
across a burst. `ipcreg_core.v` muxes pages:

- page 0 → legacy register map (same offsets as the `0x1D` slave)
- page 1 → OTA control/status + ALS snapshot block
- page 2 → OTA 256-byte data window
- **page ≥ 3 → reserved, reads `0xFF`** ← wp_adjust hooks here as page `0x03`

The host scripts in br-wrapper already default to `--wp-page 0x03`, slave
`0x1E`. Page `0x03` is also the first unallocated page in
`docs/i2c-register-map-new.md` (pages 0/1/2 = native map / OTA-ctrl+ALS /
OTA window). Note that doc's framing rule: a single-byte read pointer
defaults to page 0, so **all** page-3 accesses — reads included — must send
the explicit two-byte `{page, reg}` pointer, like the existing page-1 ALS
reads.

The `0x1D` legacy slave has no page concept — wp_adjust is **0x1E-only**;
document the new page in `docs/i2c-register-map-new.md`. (If the legacy
matching app must keep working during the `0x1D` phase-out, `0x37/0x39/0x3B`
are free there and could host a compat shim — `gain = legacy_value << 4`
maps 256 → `0x1000` unity exactly — but this is recorded-only, not
recommended; see the SW guideline §1.1.)

### 6.2 The byte adapter (`wp_page3_adapter.v`, clk_tp domain — new RTL)

wp_adjust's logical map is 8-bit address / 16-bit data; the slave bus is
byte-wide with per-byte auto-increment. Canonical mapping — **2 bytes per
logical register, big-endian**:

```text
page-3 byte address = {logical_addr[6:0], byte_sel}   (byte_sel 0 = hi, 1 = lo)
logical 0x00..0x7F  → byte offsets 0x00..0xFF (fits one page exactly)
e.g. R_GAIN_SHADOW (0x01) = bytes 0x02 (hi) + 0x03 (lo)
     COMMIT       (0x7E) = bytes 0xFC + 0xFD;  write CA 1B
     ID           (0x70) = read bytes 0xE0/0xE1 → 57 A1
```

Adapter behavior (mirror the page-1 OTA/ALS patterns in `ipcreg_core.v`,
including masking strobes with `!senable`):

- **Write path**: on `reg_we` with `reg_page==3`: even offset → latch
  `wdata` as the hi byte and remember the offset; odd offset → if it is
  `remembered+1`, issue one bridge transaction `bus_we=1,
  bus_addr=offset>>1, bus_wdata={hi_latch, wdata}`. A lone hi or lo byte
  writes nothing (document: always write both bytes in one transaction).
- **Read path** (the slave's `reg_rdata` mux is combinational, the bridge
  round trip is not — prefetch): when the read pointer lands on a page-3
  address (pointer-set or auto-increment) whose `offset>>1` differs from the
  last fetched register, fire a bridge read of `offset>>1` into a 16-bit
  hold register. Serve hi at even offsets, lo at odd, from the hold
  register. Timing budget: the bridge round trip is well under 1 µs
  (50 MHz + 67 MHz domains); one I2C byte at 400 kHz is ~22 µs — the
  prefetch always wins. The ALS page-1 snapshot block uses the same
  pointer-triggered-latch idea.
- **Host contract** (keep it simple and matching the existing Python
  backend): one 16-bit register per I2C transaction —
  `w2@0x1E [0x03, 2N]` then `r2` for reads; `w4@0x1E [0x03, 2N, hi, lo]`
  for writes. Multi-register auto-increment bursts across page 3 are
  possible with the rolling prefetch but are NOT required; don't promise
  them in v1.
- Wire `bus_req/bus_ack/bus_busy` to this repo's `wp_adjust_cdc_bridge`
  (`bus_clk=clk_tp`, `bus_rst_n=rst_n`, `pix_clk=local_clk`,
  `pix_rst_n=rst_n`); the bridge's `cfg_*` connects to both wp_adjust
  instances (write broadcast, rdata from the odd instance). Back-to-back
  I2C bytes give ~1000 clk_tp cycles between transactions; `bus_busy` will
  never be observed high by a well-behaved host, but the adapter should
  still drop-and-ignore a request while busy rather than corrupt state.
- The bridge handles the read-mux timing of wp_adjust (`cfg_rdata` is a
  0-cycle combinational mux on `cfg_addr`) — that is exactly what it was
  built for.

Plumbing: `i2c_top.v` → `ipcreg.v` → `ipcreg_core.v` currently route OTA
page signals down the hierarchy as explicit port bundles; the smallest-diff
option is to instantiate `wp_page3_adapter` + bridge in
`board_xc7s50_autoone_evb.v` (next to `i2c_top` and `lvds_tx`, where both
clk_tp and local_clk exist) and export only the byte-bus taps
(`reg_page/reg_addr/reg_we/reg_wdata` out, page-3 `rdata` in) from
`i2c_top`/`ipcreg`/`ipcreg_core` — three small port additions plus one new
branch in the `reg_rdata_v2` page mux:

```verilog
assign reg_rdata_v2 = ( reg_page_v2 == 8'h00 ) ? ...
                    : ( reg_page_v2 == 8'h01 ) ? ota_rdata
                    : ( reg_page_v2 == 8'h02 ) ? OTA_WIN_RDATA
                    : ( reg_page_v2 == 8'h03 ) ? WP_PAGE3_RDATA   // new
                    : 8'hFF;
```

### 6.3 What the host sees (acceptance for bring-up step 2)

```bash
i2ctransfer -y 1 w2@0x1E 0x03 0xE0 r2   # ID      → 0x57 0xA1
i2ctransfer -y 1 w2@0x1E 0x03 0xE2 r2   # VERSION → 0x01 0x13
i2ctransfer -y 1 w2@0x1E 0x03 0xE4 r2   # STATUS  → 0x0C 0x00 (FRAC_BITS=12, idle)
```

### 6.4 Required host-side fix (br-wrapper, one line × 3 scripts)

`I2CDevWpAdjust` in the three disp-tester children currently frames
`[page, logical_addr, ...]`. Under the 2-bytes-per-register mapping it must
send the **byte** address:

```python
# read16: os.write(fd, bytes([page, (addr << 1) & 0xFF]))
# write16: bytes([page, (addr << 1) & 0xFF, hi, lo])
```

Same adjustment applies to any future `RegisterBackend` for
`fpga-wp-adjust/host/wp_load.py`. Make this change when flipping the
launcher buttons from `--backend simulate` to
`--backend i2cdev --wp-page 0x03`.

## 7. Constraints (XDC)

Follow the repo's existing CDC style (`evb_xa7s50_Autoone.xdc` already
bounds every `cdc_handshake_bus` with a wildcard `set_max_delay
-datapath_only`). For the wp_adjust bridge add the equivalent bounds — the
synchronizer flops already carry `ASYNC_REG`/`syn_preserve` attributes in
the RTL:

```tcl
# wp_adjust_cdc_bridge: toggle synchronizers + quasi-static payload buses.
set_max_delay -datapath_only \
  -from [get_cells -hier -filter {IS_SEQUENTIAL && NAME =~ *u_wp_bridge/req_*_hold*}] \
  -to   [get_clocks -of_objects [get_nets -hier local_clk]] 10.000
set_max_delay -datapath_only \
  -from [get_cells -hier -filter {IS_SEQUENTIAL && NAME =~ *u_wp_bridge/pix_rdata_hold*}] \
  -to   [get_clocks -of_objects [get_nets -hier clk_tp]] 10.000
set_max_delay -datapath_only \
  -from [get_cells -hier -filter {IS_SEQUENTIAL && NAME =~ *u_wp_bridge/req_toggle_bus*}] \
  -to   [get_pins -hier -filter {NAME =~ *u_wp_bridge/req_toggle_pix_meta*/D}] 10.000
set_max_delay -datapath_only \
  -from [get_cells -hier -filter {IS_SEQUENTIAL && NAME =~ *u_wp_bridge/ack_toggle_pix*}] \
  -to   [get_pins -hier -filter {NAME =~ *u_wp_bridge/ack_toggle_bus_meta*/D}] 10.000
```

(Adapt instance names/clock getters to the final hierarchy; verify with
`report-check` that `unmatched_constraints` stays 0. Since clk_tp and
local_clk share one MMCM the paths are also timed synchronously by default —
the bounds make the intent explicit and survive any future clock
restructuring.)

Note `clk_tp` is found hierarchically in the XDC
(`get_nets -hierarchical clk_tp`) — reuse that pattern.

## 8. Step-by-Step Plan (each step HW-verified per repo discipline)

**Step 0 — prep (no bitstream).** Vendor the files (§4), add to
`sources.tcl`, run `make sim-all` + `make yosys-lint`; run `make test` in
fpga-wp-adjust to re-confirm the source suite. Optional: add a small
pass-through integration sim (drive both instances with a known dual-pixel
pattern, expect bit-exact output with cfg idle).

**Step 1 — datapath pass-through.** Insert both instances + rewire
`lvds_tx`; tie `cfg_wr_en=0`, `cfg_addr=0`, `cfg_wdata=0` (no bridge yet).
After reset wp_adjust is exact pass-through (bypass mux, not unity-multiply),
so video must be **visually identical**. Bump VERSION (both configs), build
both, flash, verify: video unchanged, brightness/dimming/patterns unchanged,
`report-check` at the documented floor. **ILA task while you're here:**
capture `vout_vsync` vs `vout_de` and record where the rising edge sits
(§5).

**Step 2 — register path.** Add `wp_page3_adapter` + `wp_adjust_cdc_bridge`
+ the page-3 rdata mux branch + XDC bounds. Acceptance: the three
`i2ctransfer` probes in §6.3 return ID/VERSION/STATUS, and page-0 regression
(version/brightness/LD/PC enables, ALS, OTA pages) is unchanged. Bump
VERSION, HW-verify.

**Step 3 — live gains (the B3 moment).** From the Pi:
write exaggerated shadow gains (e.g. R=0x0800, B=0x1800 — yes, 1.5 is
outside the calibration policy; this is a visibility test), COMMIT
(`CA 1B` → bytes 0xFC/0xFD), confirm a visible color shift with **no
partial-frame tint**; `DEFAULTS` (`D6 5D` → bytes 0xFE/0xFF) restores
instantly. Verify STATUS pending/consumed transitions and the readback-verify
path (read shadow after write). Also verify commit-cancel (`C0 FF`).

**Step 4 — host tools on hardware.** Apply the §6.4 byte-address fix in
br-wrapper, flip the "White Point Profiling New" button to
`--backend i2cdev --wp-page 0x03`, run a real profile sweep with the
i1Display Pro, and hand the JSON back for analysis (datapath linearity,
per-LSB response vs sensor noise, measured gamma). Then D65 calibration,
then pair matching — per `docs/pair-matching.md` and the disp-tester README.

**Step 5 — docs + housekeeping.** Update
`pixelpipe-fpga/docs/i2c-register-map-new.md` with the page-3 section
(this doc's §6 tables), add wp_adjust to `docs/block_catalog.md`, note the
new latency in any timing-sensitive doc, and record the HW results in the
commit messages per convention.

## 9. Resources and Timing Expectations

- Two instances × 3 multipliers = six 9×17-bit signed multiplies at 67 MHz.
  Trivially met on Spartan-7 (the design's hard domain is 156.25 MHz, which
  wp_adjust never touches). Expect Vivado to infer DSP48s; if it picks
  fabric, that is also fine at 67 MHz — remember the repo's lesson to be
  **surgical with `use_dsp`** (don't force it globally).
- Registers/LUTs: ~2×(shadow+active register file + datapath regs) — a few
  hundred FFs; negligible on xc7s50.
- The 2-cycle latency adds zero BRAM and no line buffering.
- `report-check` after each step; judge against `docs/signoff_residuals.md`
  (e.g. `no_clock` latches are pre-existing and load-bearing — do not
  "fix").

## 10. Risks, Open Items, and Things That Will Bite

1. **Vsync edge position vs blanking** (§5) — measure, don't assume. The
   wp_adjust contract is "commit at filtered vsync rise"; where that lands
   in the frame is integration-dependent.
2. **Byte-addressing mismatch** — the simulate-mode host scripts were written
   with logical addressing; the 2N byte mapping (§6.2) requires the §6.4
   host fix. Symptom if forgotten: ID reads return wrong/shifted bytes
   (e.g. reading byte 0x70 = logical 0x38 = zero).
3. **Two-instance divergence** is impossible by construction *only if* both
   instances see literally the same cfg/vsync/reset/clk nets — resist any
   refactor that gives them separate enables or resets.
4. **Blanking-interval data**: wp_adjust (default `GATE_BLANKING=0`)
   processes blanking pixels; the XAPP585 TX serializes RGB bits during
   DE=0 (panel ignores them per DE). The pre-integration pipeline also
   emitted non-zero blanking data, so this is the same risk class as today.
   If the TDDI/panel is ever found to snoop blanking codes, rebuild with
   `GATE_BLANKING=1` (covered by `tb_wp_adjust_options`).
5. **OTA interaction**: page 3 must not respond during OTA stream mode —
   mask all adapter strobes with `!senable` exactly like the OTA page
   strobes.
6. **Don't touch `0x1D`**: the legacy slave keeps its 4-byte-prefix map;
   wp_adjust is deliberately 0x1E-only. The legacy `wpx/wpy/wpz` registers
   (0x37/0x39/0x3B, used by the old white-point flow) are a *different
   FPGA's* legacy map — they don't exist in pixelpipe-fpga's page 0; no
   collision, no migration needed.
7. **Boot persistence**: the FPGA does not persist gains (by design). The
   Pi must replay calibration after every power cycle —
   `fpga-wp-adjust/host/wp_load.py` consumes the wp-cal-v1 JSON written by
   the D65 app once it gets an i2cdev `RegisterBackend` (same §6.4 framing).
   That loader work is Track B4 in `fpga-wp-adjust/docs/implementation-plan.md`.
8. **Both-panel coverage**: the board file is shared — build + HW-verify
   **both** configs at each step (the repo treats them as separate golden
   bitstreams with separate VERSION ranges).
9. **clk frequency drift**: if `clk_1` is ever re-generated, re-check
   local_clk (67 MHz) and clk_tp (50 MHz) assumptions; nothing in wp_adjust
   depends on the exact values, but the XDC bounds and "prefetch always
   wins" argument (§6.2) assume this order of magnitude.

## 11. Reference: Where Everything Lives

| What | Where |
|---|---|
| Insertion point | `pixelpipe-fpga/boards/xc7s50_autoone_evb/board_xc7s50_autoone_evb.v` (~line 231, `lvds_tx` instance) |
| 48-bit packing proof | `pixelpipe-fpga/rtl/video_out/lvds_tx/top4x2_7to1_sdr_tx.v` lines ~104-129 |
| Page mux to extend | `pixelpipe-fpga/rtl/ctrl/i2c/source/ipcreg_core.v` (`reg_rdata_v2` assign; "page >= 3 reserved") |
| Byte-bus contract | `pixelpipe-fpga/rtl/ctrl/i2c/source/i2c_slave_v2.v` (reg_page/reg_addr/reg_we/reg_wdata/reg_rdata) |
| Host register-map doc to update | `pixelpipe-fpga/docs/i2c-register-map-new.md` |
| CDC constraint style to copy | `pixelpipe-fpga/boards/xc7s50_autoone_evb/evb_xa7s50_Autoone.xdc` (the `*_cdc` set_max_delay block) |
| wp_adjust RTL + benches (source of truth, rev 0x0113) | `fpga-wp-adjust/rtl/`, `fpga-wp-adjust/tb/`, `make test` |
| wp_adjust register contract | `fpga-wp-adjust/docs/register-map.md` |
| wp_adjust integration contract (generic) | `fpga-wp-adjust/docs/integration-guide.md` (CDC SDC examples, blanking, quantization) |
| Host tools to flip to hardware | `br-wrapper/package/disp-tester/src/new-white-point-{profile,match}-child.py`, `d65-calibration-child.py`; launcher JSON buttons (`--backend`/`--wp-page` args) |
| Pair-matching procedure | `fpga-wp-adjust/docs/pair-matching.md` |
| Boot loader for calibration replay | `fpga-wp-adjust/host/wp_load.py` (+ wp-cal-v1 schema) |
