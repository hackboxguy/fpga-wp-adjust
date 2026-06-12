# Changelog

## Unreleased

- Added the hardware I2C backend for the boot loader (`host/wp_i2cdev.py`, Track B4): `wp_load.py --backend i2cdev --i2c-dev /dev/i2c-1 --i2c-addr 0x1E --wp-page 0x03` talks to the FPGA new slave using the page transport (2 bytes per logical register, big-endian, `byte_addr = logical << 1`; explicit two-byte `{page, reg}` pointer on every access). Exit code 5 when the transport is unavailable. Covered by frame-level unit tests plus a full `apply_profile` end-to-end test over a fake i2c-dev device.
- Register-map implementation revision bumped to `0x13` (`VERSION = 0x0113`): writing `0xC0FF` to `COMMIT` now cancels an armed commit while preserving shadow and active registers (previously only `DEFAULTS` could clear a pending commit, destroying calibration). Host adds `WpAdjustRegisters.cancel_commit()`; mock backend and testbenches updated.
- Added elaboration-time parameter guards: `FRAC_BITS` outside [2,15] or `PIXEL_BITS` outside [4,15] now fail synthesis/elaboration with a self-describing error instead of producing silently broken hardware (e.g. `FRAC_BITS=16` overflowed unity gain to zero). `make guard-check` (part of `synth-check`) asserts the failures.
- Added opt-in integration parameters, both defaulting to existing behavior: `VSYNC_ACTIVE_HIGH=0` commits on the filtered active edge of an active-low vsync (`out_vsync` keeps input polarity); `GATE_BLANKING=1` forces RGB outputs to zero when delayed DE is low. Covered by the new `tb/tb_wp_adjust_options.v`.
- Added parameter-generic testbench `tb/tb_wp_adjust_params.v` (reference-model driven); `make test` now runs it at 10/12, 8/10, and 12/14 PIXEL_BITS/FRAC_BITS.
- Host calibration writes now read back shadow registers and compare before issuing `COMMIT`, so transport-corrupted writes fail closed (`write_calibration(verify=...)`); `DryRunBackend` echoes writes into subsequent reads to match.
- Boot loader enforces a boot-safe gain window of `[unity/4, unity]` by default; `--allow-out-of-range-gains` overrides explicitly. Out-of-window gains fail before any register write.
- Calibration JSON `created_utc` is now actually format-validated (`date-time`), with a built-in fallback checker when the optional rfc3339 validator package is absent.
- Added randomized datapath co-simulation against an in-testbench reference model (extreme and random gain/offset/enable configurations), an exact 2-cycle latency/alignment test, a `MAX_PIXEL+1` saturation corner test, and negative register-interface tests (RO writes, wrong magics, unknown addresses). Mutation-checked against rounding, saturation, and channel-swap faults.
- CDC bridge testbench now sweeps bus/pixel clock ratios (slower, faster, and integer-related) via `+bus_half=` plusarg; `make test` runs all three.
- Added `ASYNC_REG`/`syn_preserve` attributes to the CDC bridge synchronizer flops and documented the required SDC constraints in the integration guide.
- Integration guide additions: blanking-interval behavior contract, quantization/banding guidance, commit-edge polarity bring-up check, and shadow readback-verify step in the register update flow.
- Added `docs/pair-matching.md`: side-by-side display matching workflow (relative target selection, luminance co-matching, pair-delta acceptance, gray-ramp checks) and the planned port of the legacy br-wrapper disp-tester procedure logic.
- Added host-side calibration math helpers and unit tests for Q-format conversion, seed reproduction, xyY/XYZ conversion, gain normalization, and safety limits.
- Added host-side logical register adapter with mock and dry-run backends.
- Added host-side boot loader with schema validation, dry-run/mock backends, bounded commit polling, controlled failure handling, and pending-until-video handling.
- Added optional CDC-safe register bridge RTL and async-clock simulation for the `wp_adjust` logical register interface.
- Added `make host-test` and CI coverage for host unit tests.
- Regenerated the example 12.3-nq1v1 seed from the committed math pipeline.

## 0.1.0 - 2026-05-22

- Added scalar v1 `wp_adjust` RTL with RGB gain, optional signed offsets, saturating clamp, and frame-boundary commit.
- Added directed Verilog testbench and Makefile targets for simulation and synthesis sanity checks.
- Added integration guide, register map, PRD, example FPGA insertion wrapper, and v1 calibration JSON schema.
- Register-map version reported by RTL: `0x0112`.
