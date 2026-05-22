# Implementation Plan

This plan stages `wp_adjust` from a verified standalone RTL block to measured display calibration. Each stage should land at a stable checkpoint with a clear rollback boundary.

## Hardware-Free Coverage

Many stages can be implemented and partially tested without the actual display hardware or final FPGA top-level:

| Area | Can test without hardware? | Notes |
|---|---|---|
| RTL pixel math | Yes | Covered by `make test`; can be extended with randomized co-sim. |
| RTL synthesis sanity | Yes | Covered by `make synth-check`; final timing still needs target FPGA tools/top-level. |
| Register-map behavior | Mostly | Can use a bus-functional testbench or mock register bridge. |
| Host JSON/schema handling | Yes | Covered by `make validate-json` locally and in CI; host tools can use mock backends. |
| Host register-write sequence | Yes | Dry-run and mock backend can verify exact logical writes. |
| Calibration math | Mostly | Can run against recorded/synthetic measurements. Real convergence still needs optical measurement. |
| FPGA top-level insertion | Partially | Wrapper/elaboration can compile; true timing, reset, CDC, and video integrity need the actual design. |
| I2C/CDC integration | Partially | CDC logic can be simulated; electrical/protocol behavior needs hardware. |
| D65 acceptance | No | Requires panel, backlight/local dimming behavior, sensor, and controlled measurement conditions. |

The plan therefore separates "software/RTL correctness" from "hardware bring-up acceptance." Do not treat a hardware-free pass as proof of optical calibration.

## Execution Model

The implementation should not be treated as a single linear hardware-gated sequence. Use two tracks:

```text
Track A: hardware-free implementation and verification
  A0  Standalone baseline
  A1  RTL/register-contract verification
  A2  Calibration math
  A3  Host register adapter with mock/dry-run backend
  A4  Boot-time loader with mock/dry-run backend
  A5  CDC/register-bridge simulation

Hardware gate:
  board + FPGA top-level + register transport + measurement bench available

Track B: hardware-gated bring-up and acceptance
  B1  FPGA top-level pass-through insertion
  B2  Board register transport and CDC electrical bring-up
  B3  Manual gain injection
  B4  Host hardware-backend acceptance
  B5  Measurement-driven calibration
  B6  Bench acceptance
  B7  Future-extension gate
```

Track A should start immediately. It depends only on artifacts in this repo: RTL, register map, schema, example calibration JSON, and recorded/seed measurement data. Track B starts only when the real FPGA top-level and bench hardware are available.

## Checkpoint Tags

Suggested checkpoints:

```text
v0.1.0-rtl-baseline
v0.2.0-host-mock-stack
v0.3.0-cdc-sim-verified
v0.4.0-fpga-pass-through-integrated
v0.5.0-register-control-integrated
v0.5.1-manual-gain-confirmed
v0.6.0-host-loader-hardware-accepted
v0.7.0-first-measured-calibration
v1.0.0-bench-accepted
```

Use tags after the exit criteria pass. If a regression appears later, return to the most recent checkpoint and re-apply only the next layer.

## Track A: Hardware-Free Work

### A0: Standalone Baseline

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

### A1: RTL And Register-Contract Verification

Goal: keep the RTL behavior and logical register contract proven before board integration.

Already covered by the committed directed bench:

1. `ID = 0x57A1`.
2. `VERSION = 0x0112`.
3. Shadow writes do not affect active values before `COMMIT`.
4. `COMMIT` consumes only at filtered active-high `in_vsync`.
5. `DEFAULTS` restores pass-through immediately and cancels pending commit.
6. Negative offsets clamp at zero.
7. Over-range values saturate.
8. Round-to-nearest behavior is checked.

Tasks:

1. Keep `tb/tb_wp_adjust.v` passing.
2. Optionally add randomized reference-model co-sim before V2/LUT work.
3. Optionally add parameter sweeps for `PIXEL_BITS` and `FRAC_BITS`.
4. Add any future register-contract changes to both `docs/register-map.md` and the testbench.

Exit criteria:

1. `make test` passes.
2. `make synth-check` passes.
3. Any changed register behavior has a self-checking test.

Rollback boundary:

Return to the latest passing RTL/schema tag.

Hardware required: no.

### A2: Calibration Math

Goal: compute safe first-pass RGB gains and iterative updates.

This stage is independent of the host register adapter and boot loader. It can be implemented first or in parallel with A3/A4.

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
6. Enforce code-domain pixel-drive gain safety limits.
7. Add synthetic measurement tests.
8. Add host unit tests to CI once `host/tests/` exists.

Exit criteria:

1. Existing 12.3-nq1v1 seed reproduces `R=0x0F19`, `G=0x1000`, `B=0x0EC3`.
2. Invalid measurements fail closed.
3. Gains outside safety limits are rejected unless an explicit override mode is used.

Rollback boundary:

Use the static example seed and manual measurement instead of iterative math.

Hardware required: no for math tests; yes for real convergence.

### A3: Host Register Adapter

Goal: create the host-side register abstraction without calibration logic.

This stage has no dependency on FPGA top-level integration. Use a mock backend first.

Planned files:

```text
host/wp_registers.py
host/tests/
```

Tasks:

1. Implement logical register names from `docs/register-map.md`.
2. Add mock backend for unit tests.
3. Add hardware backend interface, but keep it inactive until Track B.
4. Support read/write logging.
5. Support dry-run mode that emits the exact logical transaction sequence.
6. Add host unit tests to CI once `host/tests/` exists.

Exit criteria:

1. Mock tests pass without hardware.
2. Dry-run produces expected writes for identity, seed gains, `COMMIT`, and `DEFAULTS`.
3. Hardware backend can be configured later without changing loader/calibration logic.

Rollback boundary:

Keep manual I2C tools available; do not depend on host adapter until probe/readback passes in Track B.

Hardware required: no for mock and dry-run; yes for hardware backend acceptance.

### A4: Boot-Time Loader

Goal: restore a known calibration profile after reboot.

This stage depends on A3's register adapter and the committed schema, not on FPGA hardware. Build dry-run and mock-backend behavior first.

Planned files:

```text
host/wp_load.py
host/tests/
```

Existing inputs:

```text
host/schema/wp-cal-v1.schema.json
examples/calibration/*.json
```

Tasks:

1. Load calibration JSON.
2. Validate against `host/schema/wp-cal-v1.schema.json`.
3. Treat integer `gains` as authoritative.
4. Confirm `ID`, `VERSION`, and `STATUS[15:8]` through the backend.
5. Wait for no pending commit before writing shadow registers.
6. Write control/gains/offsets.
7. Write `COMMIT = 0xCA1B`.
8. Handle pending-until-video gracefully if `vsync` is not running yet.
9. Add host unit tests to CI once `host/tests/` exists.

Exit criteria:

1. `--dry-run` prints the expected register sequence.
2. Mock backend unit tests pass.
3. Loader never writes shadow registers while commit pending is set.
4. Schema-invalid calibration files are rejected before any write.

Rollback boundary:

Disable the boot service and load `DEFAULTS` manually.

Hardware required: no for dry-run/mock; yes for reboot acceptance.

### A5: CDC/Register-Bridge Simulation

Goal: de-risk the largest FPGA integration issue before board time: crossing from an asynchronous control bus into the pixel clock domain.

Planned files:

```text
rtl/ or examples/fpga/ register-bridge prototype, if this repo owns one
tb/tb_wp_adjust_cdc_bridge.v, if the bridge is generic enough to keep here
```

Tasks:

1. Decide whether the CDC bridge RTL belongs in this reusable repo or the board FPGA repo.
2. Complete CDC simulation before Track B starts, regardless of which repo owns the bridge RTL.
3. Simulate config writes from a bus clock unrelated to pixel `clk`.
4. Synchronize write strobes/address/data into pixel `clk`.
5. Verify shadow writes are complete and stable before `COMMIT`.
6. Verify commit/status handshakes cannot double-fire or lose a write.
7. Verify `DEFAULTS` cancels pending commit across the bridge.
8. Add the CDC test to CI if the bridge is kept in this repo.

Exit criteria:

1. CDC simulation passes with asynchronous bus/pixel clocks.
2. Atomic shadow-to-active update is preserved.
3. No direct asynchronous bus signal enters `wp_adjust.cfg_*`.
4. Remaining hardware-only CDC risks are documented in the board integration plan.

Rollback boundary:

Bypass the bridge and hold `wp_adjust` at defaults until the CDC design is fixed.

Hardware required: no for simulation; yes for electrical/protocol acceptance.

## Hardware Gate

Do not spend scarce bench time debugging software and simple register-sequence bugs. Before Track B starts, aim to have:

1. Track A0 complete.
2. Track A2/A3/A4 implemented against mock data/backends.
3. A5 CDC simulation completed, either in this repo or in the board FPGA repo that owns the bridge RTL.
4. A known-good calibration seed available.
5. A clear rollback command/path: `DEFAULTS`, disable boot loader, or bypass `wp_adjust`.

## Track B: Hardware-Gated Bring-Up

### B1: FPGA Top-Level Pass-Through Insertion

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

### B2: Board Register Transport And CDC Electrical Bring-Up

Goal: connect the board's real control path to the already-defined logical register map.

Tasks:

1. Map board-specific I2C/register addresses to logical subaddresses in `docs/register-map.md`.
2. Integrate the CDC-safe register bridge chosen or simulated in A5.
3. Expose readback for `ID`, `VERSION`, `STATUS`, shadow registers, and active registers.
4. Probe the hardware path from host.
5. Verify `COMMIT` and `DEFAULTS` magic writes on hardware.

Exit criteria:

1. Host can read `ID = 0x57A1`.
2. Host can read `VERSION = 0x0112`.
3. Host can read `STATUS[15:8] = 12` for the default Q4.12 build.
4. Shadow writes do not affect active registers before `COMMIT`.
5. `COMMIT` is consumed only at filtered active-high `in_vsync`.
6. `DEFAULTS` restores pass-through immediately.

Rollback boundary:

Keep `wp_adjust` instantiated but disable the register bridge or hold defaults.

Hardware required: yes.

### B3: Manual Gain Injection

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

Hardware required: yes.

### B4: Host Hardware-Backend Acceptance

Goal: move the A3/A4 host stack from mock backend to the real board transport.

Tasks:

1. Configure the real hardware backend.
2. Probe `ID`, `VERSION`, and `STATUS`.
3. Run loader dry-run against the live backend without writes, if supported.
4. Load the static seed profile.
5. Reboot and confirm calibration is restored.

Exit criteria:

1. Hardware backend can probe `ID` and `VERSION`.
2. Boot loader restores active gains after reboot.
3. Loader handles pending-until-video without false failure.
4. Loader never writes shadow registers while commit pending is set.

Rollback boundary:

Disable the boot service and write `DEFAULTS`.

Hardware required: yes.

### B5: Measurement-Driven Calibration Tool

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

### B6: Bench Acceptance

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

### B7: Future Extension Gate

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
2. Start Track A host/mock work before hardware is available: A2, A3, and A4.
3. Decide where the CDC/register bridge belongs and add A5 simulation there.
4. Create a board-integration branch in the FPGA top-level repo.
5. Land B1 with `wp_adjust` inactive/pass-through.
6. Add hardware register transport only after pass-through video is stable.
