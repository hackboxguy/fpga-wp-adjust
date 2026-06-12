# Integration Guide

## Placement

Insert `wp_adjust` after pixel compensation and before the LVDS transmitter:

```text
pixel-compensation -> wp_adjust -> lvds-tx
```

This keeps local dimming and pixel compensation upstream, while white-point trim is applied to the final RGB stream sent toward the panel interface.

## Build Parameters

| Parameter | Default | Legal range / values | Purpose |
|---|---:|---|---|
| `PIXEL_BITS` | 10 | 4-15 | Pixel width per channel; set to the real pipeline width |
| `FRAC_BITS` | 12 | 2-15 | Gain fractional bits; `STATUS[15:8]` reports the built value |
| `VSYNC_ACTIVE_HIGH` | 1 | 0 or 1 | 0 commits on the filtered active edge of an active-low vsync |
| `GATE_BLANKING` | 0 | 0 or 1 | 1 forces `out_r/g/b` to zero when delayed DE is low |

Out-of-range `PIXEL_BITS`/`FRAC_BITS` fail at elaboration with a
self-describing error (`make guard-check` verifies this), so a
misparameterized build cannot silently produce broken defaults.
`VSYNC_ACTIVE_HIGH` affects commit timing only; `out_vsync` always carries
the input polarity. `make test` covers both option parameters and runs the
parameter-generic bench at 10/12, 8/10, and 12/14.

## Datapath Contract

- Streaming RGB, one pixel per `clk`.
- Parameterized pixel width, with `PIXEL_BITS=10` as the current baseline.
- Per-channel unsigned gain, default Q4.12.
- Optional signed output-code offsets.
- Saturating output clamp.
- No frame buffering.
- Pixel path latency is 2 `clk` cycles.
- `de`, `hsync`, and `vsync` are delayed to match RGB latency.

## Clocking And CDC

`wp_adjust` assumes these signals are synchronous to `clk`:

- `in_r`, `in_g`, `in_b`
- `in_de`, `in_hsync`, `in_vsync`
- `cfg_wr_en`, `cfg_addr`, `cfg_wdata`

If the board control path is I2C, SPI, AXI-Lite, or CPU-clocked, add a CDC-safe register bridge outside this block. Do not connect an asynchronous I2C slave directly to `cfg_*`.

This repo provides `rtl/wp_adjust_cdc_bridge.v` as a small reusable option for
that boundary. It accepts one logical register transaction at a time in a
board-local `bus_clk` domain and emits `cfg_wr_en`, `cfg_addr`, and `cfg_wdata`
in the pixel `clk` domain. It uses request/acknowledge toggles with stable held
payloads; it is not an I2C, SPI, or AXI-Lite slave by itself. The outer board
register bank should issue `bus_req` on a rising edge when `bus_busy` is low
and should consume read data when `bus_ack` pulses.

`in_vsync` is expected to be active-high by default; build with `VSYNC_ACTIVE_HIGH=0` for an active-low vsync (commit then consumes on the filtered falling edge, and `out_vsync` still carries the input polarity). During bring-up, verify with a scope or on-chip logic analyzer that the commit edge falls inside the vertical blanking interval for the actual video timing; an unexpected vsync polarity can silently move the commit point.

## CDC Timing Constraints

The synchronizer flops in `wp_adjust_cdc_bridge.v` carry `ASYNC_REG` (Vivado)
and `syn_preserve` (Synplify) attributes so they are kept adjacent and exempt
from retiming. For Lattice Diamond/LSE or other flows, apply the equivalent
preserve setting to:

```text
ack_toggle_bus_meta / ack_toggle_bus_sync   (bus_clk domain)
req_toggle_pix_meta / req_toggle_pix_sync   (pix_clk domain)
```

The handshake guarantees the multi-bit payloads are stable when sampled, but
the payload nets still cross domains and must be exempted from synchronous
timing analysis. Example SDC (adapt cell/net names to the flow's mangling):

```sdc
# Toggle synchronizer inputs: cut the cross-domain path, bound the latency.
set_max_delay -datapath_only -from [get_clocks bus_clk] \
    -to [get_pins -hier *req_toggle_pix_meta*/D] 5.0
set_max_delay -datapath_only -from [get_clocks pix_clk] \
    -to [get_pins -hier *ack_toggle_bus_meta*/D] 5.0

# Quasi-static payload buses, held stable across the toggle round trip.
set_max_delay -datapath_only -from [get_cells -hier *req_we_hold*]    -to [get_clocks pix_clk] 10.0
set_max_delay -datapath_only -from [get_cells -hier *req_addr_hold*]  -to [get_clocks pix_clk] 10.0
set_max_delay -datapath_only -from [get_cells -hier *req_wdata_hold*] -to [get_clocks pix_clk] 10.0
set_max_delay -datapath_only -from [get_cells -hier *pix_rdata_hold*] -to [get_clocks bus_clk] 10.0
```

`set_false_path` on the payload buses is acceptable when both clocks are slow
relative to routing delays; `set_max_delay -datapath_only` is the safer
default because it still bounds payload skew against the toggle round trip.
Do not leave these paths unconstrained: a default cross-domain analysis will
either fail timing spuriously or, worse, let the tool retime the synchronizer
flops apart.

## Blanking-Interval Behavior

Gain/offset math is applied to every cycle, including blanking; `de`,
`hsync`, and `vsync` are delayed to match latency but do not gate the pixel
math. Consequences:

- Blanking-interval RGB values are not preserved: with gains active they are
  scaled, and with positive offsets enabled they become nonzero.
- This is harmless when the downstream LVDS/FPD-Link transmitter qualifies
  pixel data with DE (the normal case).
- If the downstream path snoops blanking-interval data (CRC monitors,
  blanking-embedded side channels, TCONs sensitive to blanking codes), build
  with `GATE_BLANKING=1` to force `out_r/g/b` to zero whenever the delayed DE
  is low, or gate externally with `out_de`.

## Quantization And Banding

A sub-unity gain maps the input code range onto fewer output codes (for
example, gain 0.92 on a 10-bit path collapses ~80 of 1024 codes), and the
block performs round-to-nearest without dithering. For the intended trim
range of white-point matching between near-D65 displays (gains roughly
0.96-1.0) the collapse is small and not normally visible. If hardware
bring-up shows contouring on shallow gradients at larger trims, options are
output dithering (a V2 RTL extension) or moving the correction into a
higher-precision LUT stage (V2A/V2B in the PRD). Until then, treat gains
below ~0.85 as needing a visual gradient check.

## Reset

`rst_n` is asynchronous assert. Integrate reset deassertion according to the FPGA project's normal reset strategy.

For `wp_adjust_cdc_bridge`, assert `bus_rst_n` and `pix_rst_n` together during
initialization and hold the bridge in reset until both clocks are running. Do
not reset only one bridge clock domain while a transaction may be in flight; if
a board-level partial reset is required, quiesce the outer register master
first and reset both bridge domains together.

After reset, the block is pass-through:

```text
enable = 0
offset_enable = 0
R/G/B gains = unity
R/G/B offsets = 0
```

## Register Update Flow

Host software should use this sequence:

1. Read `ID`, `VERSION`, and `STATUS`.
2. Confirm `STATUS[15:8]` matches the expected gain fractional bits.
3. Wait until `STATUS[0] == 0`, meaning no commit is pending.
4. Write shadow control/gain/offset registers.
5. Read the shadow registers back and compare before committing, so a lost
   or corrupted transport write is caught before it reaches the active
   datapath. The v1 host tools (`wp_registers.write_calibration`) do this by
   default.
6. Write `COMMIT = 16'hCA1B`.
7. Wait for `STATUS[1] == 1`, or wait at least one known-good frame after video is running.

Do not write new shadow values while `STATUS[0]` commit pending is set. `COMMIT` does not snapshot shadow registers at write time; it latches whatever shadow values are present at the next filtered active-high `in_vsync` edge.

To abandon staged values without losing the active calibration, write the
cancel magic `16'hC0FF` to `COMMIT` (revision `0x13`+, or
`WpAdjustRegisters.cancel_commit()` on the host side). `DEFAULTS` remains the
panic path that resets everything. A cancel racing the commit vsync edge may
arrive after the update has latched; read the active registers afterwards to
confirm when that matters.

If video is not yet running, `STATUS[0]` may remain set. A boot loader should report this as pending until video starts rather than as an immediate hard failure.

## DEFAULTS Behavior

Writing `DEFAULTS = 16'hD65D` restores pass-through immediately and cancels a pending commit. This is intended as a panic-to-safe path. If used during active video, it may create a partial-frame visual transition.

## Bring-Up Checklist

1. Run `make test`.
2. Run `make synth-check`.
3. Integrate `wp_adjust` between pixel compensation and LVDS TX.
4. Verify `out_de/out_hsync/out_vsync` timing after the 2-cycle latency.
5. Verify register readback for `ID`, `VERSION`, and `STATUS`.
6. Verify `rtl/wp_adjust_cdc_bridge.v` or the board-specific CDC-safe register bridge if the control bus is not in the pixel clock domain.
7. Write exaggerated gains and confirm a visible color shift.
8. Write unity/defaults and confirm pass-through behavior.
9. Load measured calibration gains and confirm the white point moves toward D65.
