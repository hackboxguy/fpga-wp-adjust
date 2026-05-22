# Integration Guide

## Placement

Insert `wp_adjust` after pixel compensation and before the LVDS transmitter:

```text
pixel-compensation -> wp_adjust -> lvds-tx
```

This keeps local dimming and pixel compensation upstream, while white-point trim is applied to the final RGB stream sent toward the panel interface.

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

`in_vsync` is expected to be active-high. Commit timing depends on the filtered rising edge of this signal.

## Reset

`rst_n` is asynchronous assert. Integrate reset deassertion according to the FPGA project's normal reset strategy.

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
5. Write `COMMIT = 16'hCA1B`.
6. Wait for `STATUS[1] == 1`, or wait at least one known-good frame after video is running.

Do not write new shadow values while `STATUS[0]` commit pending is set. `COMMIT` does not snapshot shadow registers at write time; it latches whatever shadow values are present at the next filtered active-high `in_vsync` edge.

If video is not yet running, `STATUS[0]` may remain set. A boot loader should report this as pending until video starts rather than as an immediate hard failure.

## DEFAULTS Behavior

Writing `DEFAULTS = 16'hD65D` restores pass-through immediately and cancels a pending commit. This is intended as a panic-to-safe path. If used during active video, it may create a partial-frame visual transition.

## Bring-Up Checklist

1. Run `make test`.
2. Run `make synth-check`.
3. Integrate `wp_adjust` between pixel compensation and LVDS TX.
4. Verify `out_de/out_hsync/out_vsync` timing after the 2-cycle latency.
5. Verify register readback for `ID`, `VERSION`, and `STATUS`.
6. Verify the CDC-safe register bridge if the control bus is not in the pixel clock domain.
7. Write exaggerated gains and confirm a visible color shift.
8. Write unity/defaults and confirm pass-through behavior.
9. Load measured calibration gains and confirm the white point moves toward D65.
