# Implementation Plan

This plan stages `wp_adjust` from a verified standalone RTL block to measured display calibration. Each stage should land at a stable checkpoint with a clear rollback boundary.

## Hardware-Free Coverage

Many stages can be implemented and partially tested without the actual display hardware or final FPGA top-level:

| Area | Can test without hardware? | Notes |
|---|---|---|
| RTL pixel math | Yes | Covered by `make test`; can be extended with randomized co-sim. |
| RTL synthesis sanity | Yes | Covered by `make synth-check`; final timing still needs target FPGA tools/top-level. |
| Register-map behavior | Mostly | Can use a bus-functional testbench or mock register bridge. |
| Host JSON/schema handling | Yes | Covered by `make validate-json`; host tools can use mock backends. |
| Host register-write sequence | Yes | Dry-run and mock backend can verify exact logical writes. |
| Calibration math | Mostly | Can run against recorded/synthetic measurements. Real convergence still needs optical measurement. |
| FPGA top-level insertion | Partially | Wrapper/elaboration can compile; true timing, reset, CDC, and video integrity need the actual design. |
| I2C/CDC integration | Partially | CDC logic can be simulated; electrical/protocol behavior needs hardware. |
| D65 acceptance | No | Requires panel, backlight/local dimming behavior, sensor, and controlled measurement conditions. |

The plan therefore separates "software/RTL correctness" from "hardware bring-up acceptance." Do not treat a hardware-free pass as proof of optical calibration.

## Checkpoint Tags

Suggested checkpoints:

```text
v0.1.0-rtl-baseline
v0.2.0-fpga-pass-through-integrated
v0.3.0-register-control-integrated
v0.4.0-host-loader
v0.5.0-first-measured-calibration
v1.0.0-bench-accepted
```

Use tags after the exit criteria pass. If a regression appears later, return to the most recent checkpoint and re-apply only the next layer.

## Stage 0: Standalone Baseline

Goal: keep the reusable repo in a known-good state before integration starts.

Entry criteria:

1. Repo clone is clean.
2. Verilog tools are installed.
3. Python `jsonschema` is available.

Tasks:

1. Run directed RTL simulation.
2. Run synthesis/elaboration sanity check.
3. Validate calibration JSON examples.
4. Confirm docs and register map match RTL.

Commands:

```sh
make validate-json
make test
make synth-check
```

Exit criteria:

1. All commands pass.
2. `rtl/wp_adjust.v` remains pass-through after reset.
3. `tb/tb_wp_adjust.v` passes without warnings.

Rollback boundary:

Return to tag `v0.1.0-rtl-baseline`.

Hardware required: no.

## Stage 1: FPGA Top-Level Pass-Through Insertion

Goal: instantiate `wp_adjust` between pixel compensation and LVDS TX without enabling correction.

Target placement:

```text
pixel-compensation -> wp_adjust -> lvds-tx
```

Tasks:

1. Instantiate `rtl/wp_adjust.v` in the FPGA top-level.
2. Set `PIXEL_BITS` to the real internal pixel width.
3. Connect RGB, `de`, `hsync`, and active-high synchronous `vsync`.
4. Tie or connect the config interface so the block powers up in pass-through mode.
5. Account for the 2-cycle RGB/control latency before LVDS TX.

Exit criteria:

1. FPGA project builds.
2. Timing closes or timing issues are understood.
3. With defaults, output video is visually unchanged.
4. Existing local-dimming/pixel-compensation behavior remains stable.

Rollback boundary:

Remove or bypass only the `wp_adjust` insertion.

Hardware required: yes for true video integrity; no for compile/elaboration only.

## Stage 2: Register Bank And CDC Integration

Goal: expose the logical `wp_adjust` register map through the board's control path.

Tasks:

1. Map board-specific I2C/register addresses to the logical subaddresses in `docs/register-map.md`.
2. Ensure `cfg_wr_en`, `cfg_addr`, and `cfg_wdata` are synchronous to pixel `clk` before entering `wp_adjust`.
3. If the external bus is asynchronous, add a CDC-safe register bridge outside `wp_adjust`.
4. Expose readback for `ID`, `VERSION`, `STATUS`, shadow registers, and active registers.
5. Verify `COMMIT` and `DEFAULTS` magic writes.

Exit criteria:

1. Host can read `ID = 0x57A1`.
2. Host can read `VERSION = 0x0112`.
3. Host can read `STATUS[15:8] = 12` for the default Q4.12 build.
4. Shadow writes do not affect active registers before `COMMIT`.
5. `COMMIT` is consumed only at filtered active-high `in_vsync`.
6. `DEFAULTS` restores pass-through immediately.

Rollback boundary:

Keep `wp_adjust` instantiated but disable the register bridge or hold defaults.

Hardware required: partially. Register-map logic can be simulated, but final I2C/CDC behavior needs hardware.

## Stage 3: Manual Gain Injection

Goal: prove the live video path responds to controlled register writes.

Tasks:

1. Write identity gains and verify no visible tint.
2. Write exaggerated gains such as red `0x0800`, green `0x1000`, blue `0x1800`.
3. Commit and verify visible color shift.
4. Write `DEFAULTS` and verify pass-through returns.
5. Verify no partial-frame tint during normal committed updates.

Exit criteria:

1. Manual writes create expected visual direction.
2. Defaults recover the image.
3. Commit/status behavior is observable and repeatable.

Rollback boundary:

Use `DEFAULTS`, then disable host writes.

Hardware required: yes for visual confirmation; a simulation can still verify expected register sequencing.

## Stage 4: Host Register Adapter

Goal: create the host-side register abstraction without calibration logic.

Planned files:

```text
host/wp_registers.py
host/tests/
```

Tasks:

1. Implement logical register names from `docs/register-map.md`.
2. Add mock backend for unit tests.
3. Add hardware backend for the real board transport.
4. Support read/write logging.
5. Support dry-run mode that emits the exact logical transaction sequence.

Exit criteria:

1. Mock tests pass without hardware.
2. Dry-run produces expected writes for identity, seed gains, `COMMIT`, and `DEFAULTS`.
3. Hardware backend can probe `ID` and `VERSION` when connected.

Rollback boundary:

Keep manual I2C tools available; do not depend on host adapter until probe/readback passes.

Hardware required: no for mock and dry-run; yes for hardware backend acceptance.

## Stage 5: Boot-Time Loader

Goal: restore a known calibration profile after reboot.

Planned files:

```text
host/wp_load.py
host/schema/wp-cal-v1.schema.json
examples/calibration/*.json
```

Tasks:

1. Load calibration JSON.
2. Validate against `host/schema/wp-cal-v1.schema.json`.
3. Treat integer `gains` as authoritative.
4. Confirm `ID`, `VERSION`, and `STATUS[15:8]`.
5. Wait for no pending commit before writing shadow registers.
6. Write control/gains/offsets.
7. Write `COMMIT = 0xCA1B`.
8. Handle pending-until-video gracefully if `vsync` is not running yet.

Exit criteria:

1. `--dry-run` prints the expected register sequence.
2. Mock backend unit tests pass.
3. On hardware, reboot restores the same active gains.
4. Loader never writes shadow registers while commit pending is set.

Rollback boundary:

Disable the boot service and load `DEFAULTS` manually.

Hardware required: no for dry-run/mock; yes for reboot acceptance.

## Stage 6: Calibration Math

Goal: compute safe first-pass RGB gains and iterative updates.

Planned files:

```text
host/wp_math.py
host/tests/
```

Tasks:

1. Implement xyY/XYZ helpers.
2. Compute initial linear-light RGB correction from measured RGBW data.
3. Normalize so the strongest channel is at or below unity.
4. Convert to code-domain gain using measured/configured gamma.
5. Convert float gains to Q4.12 with round-to-nearest.
6. Enforce gain safety limits.
7. Add synthetic measurement tests.

Exit criteria:

1. Existing 12.3-nq1v1 seed reproduces `R=0x0F1D`, `G=0x1000`, `B=0x0EC6`.
2. Invalid measurements fail closed.
3. Gains outside safety limits are rejected unless an explicit override mode is used.

Rollback boundary:

Use the static example seed and manual measurement instead of iterative math.

Hardware required: no for math tests; yes for real convergence.

## Stage 7: Measurement-Driven Calibration Tool

Goal: perform bounded measurement/update iterations on the real display.

Planned files:

```text
host/wp_calibrate.py
```

Tasks:

1. Set full-field 100% white.
2. Use full brightness unless a product-specific calibration brightness is chosen.
3. Keep local dimming enabled for v1 calibration.
4. Measure white with the selected instrument.
5. Compute and upload damped gain updates.
6. Stop after convergence, safety failure, or iteration limit.
7. Write schema-valid calibration JSON with verification data.

Exit criteria:

1. White point moves toward D65.
2. Final white is inside report-card tolerance, or residual error is documented.
3. Luminance loss is within accepted limits.
4. No clipping, flashing, or unstable local-dimming behavior is observed.

Rollback boundary:

Restore previous known-good calibration JSON or write `DEFAULTS`.

Hardware required: yes.

## Stage 8: Bench Acceptance

Goal: declare v1 scalar calibration acceptable or decide that V2 is needed.

Tasks:

1. Archive before/after measurements.
2. Archive calibration JSON.
3. Verify calibration survives reboot.
4. Verify pass-through recovery through `DEFAULTS`.
5. Confirm no user-visible artifacts in normal content.
6. Record FPGA bitstream/register-map version.

Exit criteria:

1. V1 achieves D65 tolerance target under defined conditions.
2. Boot-time loader restores calibration.
3. Hardware CDC/commit handshake has been verified.
4. Known rollback path exists.

Rollback boundary:

Revert to previous checkpoint or disable `wp_adjust` through defaults.

Hardware required: yes.

## Stage 9: Future Extension Gate

Only start V2 work after v1 bench results show a real need.

Possible triggers:

1. 100% white reaches D65 but gray patches drift badly.
2. Gain-only correction causes unacceptable luminance loss.
3. Temperature or local-dimming state moves white point enough to need profiles.
4. Production panel variation requires per-panel or golden-profile decisions.

Candidate extensions:

1. Output LUT.
2. Degamma/linear-light pipeline.
3. 3x3 color correction matrix.
4. Temperature/profile switching.
5. Local-dimming or APL-aware correction.
6. TDDI white-point path if the protocol becomes known.

Each V2 feature should get its own PRD update, RTL tests, host tests, and rollback checkpoint.

## Minimum Next Actions

1. Tag the current repo as the RTL/schema baseline after checks pass.
2. Create a board-integration branch in the FPGA top-level repo.
3. Land Stage 1 with `wp_adjust` inactive/pass-through.
4. Add register bridge work only after pass-through video is stable.
5. Build host tools against mock backends before touching hardware.
