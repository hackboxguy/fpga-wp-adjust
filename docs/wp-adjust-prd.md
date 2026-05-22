# PRD: FPGA White-Point Adjustment and Pi4 Calibration Flow

Version: 0.1  
Date: 2026-05-22  
Target display: 12.3-nq1v1 local-dimming display  
Primary goal: bring measured peak white closer to D65 with a simple, reliable FPGA datapath that can be extended later.

## 1. Summary

The display currently measures outside the allowed D65 white-point tolerance. The first implementation shall add a small `wp_adjust` block in the FPGA after pixel compensation and before the LVDS transmitter. The FPGA shall perform only the real-time pixel operation needed for white-point correction: per-channel RGB gain, with optional small signed offsets reserved for later use.

The Raspberry Pi 4 shall own calibration, persistence, and boot-time loading. Calibration data shall be stored on the Pi4 filesystem and uploaded to the FPGA over I2C after every reboot. The FPGA shall not persist calibration data across power cycles.

This PRD intentionally avoids a full LUT-based color pipeline in v1. LUTs, grayscale tracking, thermal compensation, and 3x3 color correction are treated as staged extensions after the gain-only solution is measured on hardware.

Authoritative v1 contract:

1. `docs/wp-adjust-prd.md`, `docs/register-map.md`, and `rtl/wp_adjust.v` define the v1 scalar implementation.
2. V1 uses scalar RGB gain/optional offset, 8-bit register subaddresses, 16-bit register data, Q4.12 gain format, and frame-boundary commit.
3. Host tools must target the v1 contract unless a later PRD revision explicitly replaces it.

Repository layout:

```text
rtl/wp_adjust.v             FPGA scalar white-point adjustment block
tb/tb_wp_adjust.v           Self-checking Verilog testbench
host/                       Pi4 calibration, JSON, and calibration upload tools
docs/wp-adjust-prd.md       This PRD
docs/register-map.md        Logical register interface
```

## 2. Background

Video path:

```text
Pi4 HDMI
  -> HDMI-to-DP converter
  -> TI DS90UB983 serializer
  -> FPD-Link
  -> TI DS90UB988 deserializer with LVDS output
  -> FPGA
  -> LVDS transmitter
  -> TDDI / panel
```

The FPGA already sits in the correct place to apply display-specific pixel correction. The Pi4 is the right place to run calibration because it has access to test-pattern control, measurement tools, filesystems, scripts, and boot services.

In the original target system, the existing display-test-framework provided most of the Pi4 measurement plumbing v1 needed:

| Existing component | Reuse in v1 |
|---|---|
| `measure-display.sh` | Take sensor readings and optionally drive disp-tester patterns |
| `lib/spotread-api.sh` | Existing i1DisplayPro/spotread wrapper and chromaticity parsing |
| `lib/pattern-api.sh` | Start/control pattern-generator through `launcher-client` |
| `lib/backends/fpga-i2c.sh` | Existing FPGA I2C, brightness, and als-dimmer integration |
| `tests/02-validation/test-color-gamut.sh` | Reference for full-brightness RGBCMYW measurement and backlight temperature capture |
| `tests/02-validation/test-gamma-curve.sh` | Reference for gray-ramp measurement if v2 LUT work is needed |
| `config/12.3-nq1-lattice-ecp5.json` | Existing display-specific runtime defaults and thresholds |

The `host/` tools should reuse these entry points where practical rather than duplicating pattern control, spotread retry handling, or brightness plumbing.

Standalone repo note: those measurement tools and display-specific config files are external integration-environment dependencies, not files provided by this repository. The RTL block, register map, schema, example calibration JSON, and Verilog tests can be used without that original measurement framework.

## 3. Measurement Evidence

The original 12.3-nq1v1 report card showed the white point outside the D65 tolerance region. The underlying color-gamut measurement reported:

| Quantity | Value |
|---|---:|
| Measured white x | `0.310072` |
| Measured white y | `0.308795` |
| D65 x | `0.3127` |
| D65 y | `0.3290` |
| dx from D65 | `-0.002628` |
| dy from D65 | `-0.020205` |
| Euclidean xy distance | about `0.0204` |
| Report-card tolerance multiple | about `1.70x` |
| Measured white luminance | about `1211.3 nits` |

The dominant issue is low `y`, not low luminance. The display is already bright, with peak luminance around `1200 nits`.

Thermal measurement also matters. The thermal white-point profile starts near `x=0.311246, y=0.310395` at `34.5 C` and drifts toward roughly `x=0.3051, y=0.3027` near `53.8 C`. Therefore v1 calibration must define a repeatable measurement condition rather than chasing an unconstrained moving target.

## 4. Goals

1. Move measured 100% white closer to D65 using FPGA RGB gains.
2. Keep the FPGA datapath small, deterministic, and suitable for real-time video.
3. Keep calibration persistence on the Pi4, not in FPGA flash or registers.
4. Provide a boot-time loader so calibration is restored after every power cycle.
5. Define a calibration flow that can be repeated on the bench and later adapted for production.
6. Leave a clean path to add grayscale/LUT/thermal compensation after v1 data is collected.

## 5. Non-Goals For v1

1. No FPGA-side persistent storage.
2. No required input/output LUTs.
3. No required 3x3 color matrix.
4. No automatic temperature-dependent correction in the FPGA.
5. No dependency on undocumented TDDI I2C white-point registers.
6. No reliance on Pi4 GPU color management for the final correction.

## 6. V1 Architecture

```text
pixel compensation
  -> wp_adjust: RGB gain, optional offset, clamp/round
  -> LVDS transmitter
```

Pi4 responsibilities:

1. Display test patterns.
2. Read colorimeter/spectrometer measurements.
3. Compute RGB gains.
4. Store calibration JSON.
5. Upload calibration to FPGA over I2C during boot.
6. Re-upload or adjust during calibration sessions.

FPGA responsibilities:

1. Apply active RGB gains to every pixel at video rate.
2. Optionally apply small signed RGB offsets if enabled.
3. Clamp output to the valid pixel range.
4. Expose a simple register interface to the FPGA I2C register bank.
5. Apply register updates atomically, preferably on frame boundary.

## 7. Calibration Condition For v1

The v1 calibration target shall be measured at:

1. Full-field 100% white.
2. Full brightness command unless a product-specific calibration brightness is later chosen.
3. Local dimming enabled, because this matches the real display operating path for full-white operation.
4. A warmed and stable panel condition.
5. No vision-boost mode, since the current system does not have vision boost.

Recommended warm condition:

1. Run at 100% white or a defined warmup pattern until backlight temperature change is small enough to be repeatable.
2. Record backlight temperature in the calibration JSON.
3. Use the same condition for verification.

If later tests show local dimming introduces unstable white measurements, the calibration script may add a controlled calibration mode. For v1, calibrating with local dimming enabled is acceptable and preferable because it represents the deployed optical path.

## 8. FPGA Datapath Requirement

The v1 `wp_adjust` block shall support:

1. Parameterized pixel width, initially 10 bits per channel at the FPGA `wp_adjust` input.
2. Per-channel unsigned fixed-point gain.
3. Unity default after reset.
4. Optional signed offsets, disabled by default.
5. Saturating output clamp.
6. At least one registered output stage.
7. No frame buffering.
8. No dependence on the Pi4 once active registers are loaded.

If the upstream video source is 8-bit HDMI content, the integration shall document where and how it is expanded to the `wp_adjust` input width. If the actual FPGA pixel path is not 10-bit, set `PIXEL_BITS` to the real width and write the FPGA test vectors for that width.

The current `rtl/wp_adjust.v` is a suitable functional baseline. For production integration, two behaviors should be tightened:

1. Active gain/offset registers should update on a frame boundary, preferably `vsync`, to avoid visible partial-frame tint. The current RTL commits shadow registers after the next filtered rising edge of active-high `in_vsync` after a valid `COMMIT` write.
2. If the I2C/register bus is not in the pixel clock domain, the register bank must provide a CDC-safe write/commit handshake.

The block uses asynchronous reset assertion. Production integration shall provide reset deassertion timing/synchronization consistent with the rest of the FPGA clocking scheme.

The FPGA must power up in pass-through mode:

```text
R_GAIN = unity
G_GAIN = unity
B_GAIN = unity
offsets = 0
offset_enable = 0
wp_adjust_enable = 0 or active with unity gains
```

## 9. Register Interface

The exact FPGA I2C slave address may be changed to fit the existing design. The v1 `wp_adjust` subaddress map is 8-bit address, 16-bit data. If an outer FPGA register bank is byte-addressed or uses a different I2C protocol, `wp_registers.py` shall adapt that outer protocol to the logical v1 fields below.

| Address | Field | Access | Purpose |
|---:|---|---|---|
| `0x00` | `CONTROL_SHADOW` | RW | Bit 0 master enable for the gain/offset datapath, bit 1 offset enable |
| `0x01` | `R_GAIN_SHADOW` | RW | Red gain, Q4.12 |
| `0x02` | `G_GAIN_SHADOW` | RW | Green gain, Q4.12 |
| `0x03` | `B_GAIN_SHADOW` | RW | Blue gain, Q4.12 |
| `0x04` | `R_OFFSET_SHADOW` | RW | Optional signed red output-code offset |
| `0x05` | `G_OFFSET_SHADOW` | RW | Optional signed green output-code offset |
| `0x06` | `B_OFFSET_SHADOW` | RW | Optional signed blue output-code offset |
| `0x20` | `CONTROL_ACTIVE` | RO | Active enable bits |
| `0x21` | `R_GAIN_ACTIVE` | RO | Active red gain |
| `0x22` | `G_GAIN_ACTIVE` | RO | Active green gain |
| `0x23` | `B_GAIN_ACTIVE` | RO | Active blue gain |
| `0x24` | `R_OFFSET_ACTIVE` | RO | Active red offset |
| `0x25` | `G_OFFSET_ACTIVE` | RO | Active green offset |
| `0x26` | `B_OFFSET_ACTIVE` | RO | Active blue offset |
| `0x70` | `ID` | RO | `0x57A1`, identifies the v1 white-point block |
| `0x71` | `VERSION` | RO | `0x0112`; bits 15:8 are register-map major version `0x01`, bits 7:0 are implementation revision `0x12` |
| `0x72` | `STATUS` | RO | Bit 0 commit pending, bit 1 commit consumed, bit 2 active gain enable, bit 3 active offset enable, bits 15:8 `FRAC_BITS` |
| `0x7E` | `COMMIT` | WO | Write `0xCA1B`; shadow values latch to active on the next filtered rising edge of active-high `in_vsync` |
| `0x7F` | `DEFAULTS` | WO | Write `0xD65D`; restore identity/pass-through defaults immediately |

The implementation may integrate these logical fields into a larger existing register file. Host tooling shall isolate transport details in `wp_registers.py` so outer I2C address changes do not affect calibration math.

`CONTROL` bit 1 has no pixel effect by itself. Offsets are applied only when both bit 0 and bit 1 are set; offset-only correction is done by enabling bit 0 with unity RGB gains and enabling bit 1.

Recommended v1 fixed-point format:

1. Use 16-bit unsigned gain.
2. Use Q4.12 with unity equal to `0x1000`.
3. Treat `STATUS[15:8]` as the authoritative fractional-bit count; the loader shall require `12` for v1 Q4.12 unless the register adapter explicitly supports conversion.
4. Prefer gains at or below unity during calibration to preserve highlight headroom.

Deferred commit contract:

1. `COMMIT` arms the pending update. It does not snapshot the shadow registers at write time.
2. The values latched on `in_vsync` are whatever shadow values are present at the filtered active-high frame edge.
3. Host software must not write new shadow values while `STATUS[0]` commit pending is set.
4. Host software shall wait for `STATUS[1]` commit consumed, or wait at least one known-good frame after video is running, before starting another update.
5. If video/vsync is not running, `STATUS[0]` may remain set indefinitely. The boot loader shall treat this as "pending until video starts," not as an immediate write failure.
6. `DEFAULTS` is intentionally immediate so it can act as a panic-to-safe path. If used during active video, it may cause a partial-frame visual seam.

## 10. Initial Gain Estimate From Existing Data

Using measured RGBW data from the original target system, a rough linear-light D65 correction that preserves headroom is:

| Channel | Gain |
|---|---:|
| R | about `0.881` |
| G | `1.000` |
| B | about `0.839` |

The v1 FPGA datapath applies gain directly to encoded pixel codes, not linear luminance. Therefore the initial upload seed should compensate for the measured gamma. With measured gamma about `2.184`, the code-domain seed is:

| Channel | Code-domain gain | Q4.12 |
|---|---:|---:|
| R | about `0.944` | `0x0F19` |
| G | `1.000` | `0x1000` |
| B | about `0.923` | `0x0EC3` |

These values should be rounded to nearest when converting to Q4.12. They are still only a starting point; the calibration script must measure after applying gains and iterate until the target is reached or convergence fails.

The more aggressive linear-light values would be appropriate for a future linearized datapath with input/output LUTs, not for v1's encoded-code multiplier.

Example v1 Q4.12 seed:

```text
R_GAIN = 0x0F19
G_GAIN = 0x1000
B_GAIN = 0x0EC3
```

## 11. Pi4 Calibration Tool

V1 host code shall live under `host/`. The initial host deliverables are:

| File | Purpose |
|---|---|
| `host/wp_calibrate.py` | Interactive/scripted white-point calibration loop |
| `host/wp_load.py` | Boot-time or manual calibration upload from JSON |
| `host/wp_math.py` | Small shared math helpers: xy/XYZ, gain normalization, fixed-point conversion |
| `host/wp_registers.py` | Register-map adapter; isolates actual I2C slave address/subaddresses |
| `host/schema/wp-cal-v1.schema.json` | Calibration JSON schema |
| `host/systemd/wp-calibration.service` | Optional boot-time loader unit |

Python is acceptable for v1 because calibration is measurement-bound, not performance-bound. If boot-time constraints or Buildroot packaging later favor C, `wp_load.py` can be replaced by a small C loader while preserving the JSON schema and register adapter behavior.

The Pi4 calibration tool shall:

1. Put the FPGA into identity/default state.
2. Show a full-field 100% white test pattern.
3. Measure white using the selected instrument.
4. Compare measured white against D65.
5. Compute RGB gain updates.
6. Normalize gains so the largest channel is at or below unity unless an explicit brightness-preserving mode is selected.
7. Upload gains to FPGA.
8. Wait for `STATUS[1]` commit consumed, or for a defined frame delay only when video/vsync is known to be running.
9. Repeat measurement and update for a bounded number of iterations.
10. Save final calibration and verification data to JSON.

Minimum v1 calibration algorithm:

1. Measure or load RGBW tristimulus values for the panel under the calibration condition.
2. Compute a linear-light RGB correction that would move measured white to the target D65 chromaticity at the measured luminance.
3. Normalize the correction so the largest channel gain is `1.0` unless brightness-preserving mode is explicitly selected.
4. Convert the first upload seed to code-domain gain using the measured or configured display gamma: `gain_code = gain_linear ** (1 / gamma)`.
5. Upload rounded Q4.12 gains and commit.
6. Re-measure white.
7. Apply damped multiplicative updates to the code-domain gains until the convergence target is met or the iteration limit is reached.

The damping factor should default to a conservative value such as `0.5-0.7` for early bench work. The tool shall detect convergence failure if the white-point error grows for two consecutive iterations, the iteration limit is exceeded, any gain would leave the allowed safety range, or the luminance-loss gate is exceeded.

Gain safety limits:

1. Default allowed range: `[0.5, 1.0]` for v1 headroom-preserving calibration.
2. Any mode that permits gains above unity must be explicit and must record that choice in JSON.
3. A failed or obviously invalid measurement must not be uploaded to the FPGA.

The tool should integrate with the existing display-test-framework in this order of preference:

1. Use `measure-display.sh --sensor-only=yes --quiet=yes --noheader=yes` for single white measurements when the pattern is already set.
2. Use `measure-display.sh --pattern-source=disp-tester --wfile=enable` or `pattern-api.sh`/`launcher-client` to display full-field white.
3. Use the existing brightness path from `display-api.sh` / `fpga-i2c.sh` so calibration brightness matches other validation tests.
4. Capture backlight temperature through the same `disptool-bltemp` path used by `test-color-gamut.sh` when available.

Suggested convergence target:

1. Primary target: inside the existing report-card D65 tolerance ellipse.
2. Preferred tighter target: `xy` distance to D65 below `0.005`, or `Delta u'v'` below `0.004`, if reachable without severe luminance loss or clipping.
3. Record both target result and actual measured residual.

The tool should log:

1. Initial measured `xyY`.
2. Each iteration's gains.
3. Each iteration's measured `xyY`.
4. Backlight temperature if available.
5. Final pass/fail reason.

Suggested CLI:

```text
wp_calibrate.py
  --panel-id 12-3-nq1v1
  --panel-serial <serial-or-dev-id>
  --output /etc/wp-cal/<panel-serial>.json
  --brightness 100
  --local-dimming enabled
  --target D65
  --max-iterations 5
  --framework-root <display-test-framework-root>
  --measure-display <display-test-framework-root>/measure-display.sh
  --dry-run
```

The script shall not hard-code the final I2C slave address or register subaddresses. Those belong in `wp_registers.py`, a small JSON/YAML map, or command-line options.

## 12. Calibration JSON

Calibration shall be stored on the Pi4, for example under `/etc/wp-cal/`.

The canonical v1 schema is `host/schema/wp-cal-v1.schema.json`. The seed profile in `examples/calibration/12-3-nq1v1-seed.json` is expected to validate against that schema. Host loaders shall treat the flat integer `gains` fields as authoritative; `gain_metadata` is explanatory and may be absent.

Required JSON fields:

```json
{
  "format_version": 1,
  "panel_id": "12-3-nq1v1",
  "panel_serial": "unknown-or-real-serial",
  "profile_name": "12-3-nq1v1-initial-code-domain-seed",
  "created_utc": "2026-05-22T00:00:00Z",
  "target_white": {"name": "D65", "x": 0.3127, "y": 0.3290},
  "calibration_condition": {
    "pattern": "100_percent_full_field_white",
    "brightness_percent": 100,
    "local_dimming": "enabled",
    "vision_boost": "not_present",
    "backlight_temp_c": null
  },
  "fpga": {
    "register_map": "wp_adjust_scalar_v1",
    "gain_format": "Q4.12",
    "frac_bits": 12,
    "unity_hex": "0x1000"
  },
  "gains": {
    "r": 3865,
    "g": 4096,
    "b": 3779
  },
  "gain_metadata": {
    "assumed_gamma": 2.184,
    "code_domain_float": {"r": 0.9437, "g": 1.0, "b": 0.9226},
    "q_format_hex": {"r": "0x0F19", "g": "0x1000", "b": "0x0EC3"}
  },
  "offsets": {
    "enabled": false,
    "r": 0,
    "g": 0,
    "b": 0
  },
  "verification": {
    "initial_xyY": {"x": 0.310072, "y": 0.308795, "Y": null},
    "final_xyY": null,
    "inside_report_card_tolerance": null,
    "xy_distance_to_d65": null,
    "converged": false
  },
  "notes": []
}
```

The `final_xyY` values above are placeholders in the template. The actual loader may use a smaller schema, but calibration artifacts should preserve enough metadata to debug field returns and thermal differences.

## 13. Pi4 Boot Loader

The boot loader shall live in `host/wp_load.py` for v1. It shall:

1. Wait for the FPD-Link/I2C path to become available.
2. Probe the FPGA register bank using `ID` and `VERSION`.
3. Load the selected calibration JSON.
4. Validate gain format and register-map version.
5. Write shadow gain/offset registers.
6. Commit the new values.
7. Verify status or read back active/shadow fields if available.
8. Log success/failure to systemd journal.

The loader shall not perform measurement or calibration. It only restores known calibration. It must not write new shadow values while `STATUS[0]` commit pending is set. During early boot, a pending commit with no consumed status is acceptable if video/vsync has not started yet; the loader should log "pending until video" rather than treating it as a hard failure.

Suggested CLI:

```text
wp_load.py
  --cal /etc/wp-cal/<panel-serial>.json
  --register-map /etc/wp-cal/wp-register-map.json
  --i2c-bus /dev/i2c-1
  --timeout-sec 10
  --dry-run
```

The register adapter may call an existing `disptool` command path if the production firmware exposes `wp_adjust` through disptool. If not, it may use Linux `i2c-dev` directly. The PRD requires the logical operation, not one fixed transport implementation.

Recommended failure behavior:

1. If no calibration file exists, leave FPGA in identity/pass-through mode and log a warning.
2. If FPGA is unavailable, retry for a bounded timeout.
3. If JSON is invalid, leave identity/pass-through mode and return non-zero.
4. If commit status is unavailable but writes succeeded, log a degraded success only if the hardware team explicitly allows it.

## 14. Acceptance Criteria

V1 is accepted when:

1. FPGA builds with scalar `wp_adjust` integrated in the video path.
2. Identity/default mode is visually and numerically pass-through within expected rounding.
3. Deliberate test gains visibly change white balance.
4. Pi4 can load calibration after reboot.
5. Calibration JSON survives FPGA reflash and power cycle because it lives on Pi4.
6. On the 12.3-nq1v1 test unit, calibrated 100% white moves from the measured out-of-tolerance point toward D65.
7. The calibrated result is inside the report-card D65 tolerance ellipse.
8. Preferred: calibrated `xy` distance to D65 is below `0.005`, or `Delta u'v'` is below `0.004`.
9. Peak luminance loss is recorded. Any loss greater than 20% must be reviewed before accepting the gain strategy.
10. A before/after report card or measurement log is archived.

## 15. Test Plan

FPGA tests:

1. Reset defaults produce identity output.
2. Unity gain produces identity output.
3. Known gains produce expected rounded/clamped pixel values.
4. Over-range pixels saturate rather than wrap.
5. Negative offsets clamp at zero.
6. Commit updates all channels atomically.
7. Register writes do not change active values before commit.
8. Deferred commit latches the latest shadow value present at the filtered active-high vsync edge.
9. A one-cycle `in_vsync` glitch does not consume a pending commit.
10. `DEFAULTS` restores pass-through immediately and cancels any pending commit.
11. Offset enable requires the master datapath enable bit.
12. Round-to-nearest behavior is checked at half-code ties.
13. New shadow writes are not issued by host-side tests while commit pending is set.
14. CDC/commit handshake is verified if register and pixel clocks differ.

The repository shall include a minimal self-checking testbench for the RTL under `tb/`. Run it with `make test`. If the local environment lacks a Verilog simulator, Yosys parse/elaboration is still required and simulation shall be run in the FPGA development environment before bench deployment.

Bench tests:

1. Read FPGA `ID` and `VERSION`.
2. Write identity calibration and verify no visible tint.
3. Write exaggerated gains and verify visible color shift.
4. Load rough initial gains and measure white.
5. Run iterative calibration and measure final white.
6. Reboot Pi4 and verify calibration is restored.
7. Generate a new report card and compare D65 white-point panel to the original report.

Host tests:

1. `wp_math.py` converts gains to the selected fixed-point format correctly.
2. Given the current measured white and RGBW primaries, the linear-light estimate is within `±0.005` of `R=0.881`, `G=1.000`, `B=0.839`, and the v1 encoded-code seed using gamma `2.184` is within `±0.005` of `R=0.944`, `G=1.000`, `B=0.923`.
3. JSON schema accepts a valid v1 calibration and rejects missing/invalid gains.
4. `wp_load.py --dry-run` produces the expected logical register-write sequence without touching hardware.
5. `wp_calibrate.py --dry-run` completes a synthetic convergence loop and writes schema-valid JSON.

## 16. Future Extensions

The extensions below are explicitly not required for v1. They should be added only when v1 measurements show a real gap that scalar RGB gain cannot close. Each extension must preserve the baseline architecture: the FPGA performs only real-time pixel math, while the Pi4 owns measurement, calibration computation, JSON persistence, and boot-time loading.

### 16.1 V2A: Output 1D LUTs For Grayscale Tracking

Trigger:

1. V1 brings 100% white inside tolerance, but gray patches from 10-90 IRE show unacceptable white-point drift.
2. The existing `test-gamma-curve.sh` or a new grayscale-white tracking sweep shows repeated, measurable per-level color error.

FPGA change:

1. Add optional per-channel output LUTs after gain/offset.
2. Use one LUT per channel.
3. Keep LUTs disabled or identity by default.
4. Do not require double-buffered LUTs in the first LUT implementation unless runtime updates are visible.

Pi4 change:

1. Extend `wp_calibrate.py` to measure a grayscale ramp.
2. Generate monotonic correction curves.
3. Store LUTs in calibration JSON.
4. Extend `wp_load.py` to upload LUT contents during boot.

Acceptance:

1. 100% white remains within v1 tolerance after LUTs are enabled.
2. Mean grayscale white-point error improves versus v1 gain-only.
3. The LUT path does not introduce visible banding, clipping, or non-monotonic grayscale behavior.

Notes:

Earlier LUT-oriented prototypes are useful as concept references, but their LUT write protocol and CDC behavior need cleanup before production use. V2A should be designed from the v1 register/commit model instead of adopting an advanced block wholesale.

### 16.2 V2B: Input Degamma And Linear-Light Processing

Trigger:

1. Output LUT correction is not enough because gain math in encoded RGB space causes measurable tone or saturation artifacts.
2. The team decides that linear-light correction is required for colorimetric accuracy.

FPGA change:

1. Add optional input LUTs before gain/offset.
2. Process internally at higher precision than the LVDS input width.
3. Add output LUTs to map internal linear values back to the panel input encoding.

Pi4 change:

1. Generate identity or standard transfer-function input LUTs.
2. Generate output LUTs paired with the chosen input transfer function.
3. Record transfer-function metadata in JSON.

Acceptance:

1. Grayscale tracking improves over V2A.
2. Peak white remains within tolerance.
3. Resource use and timing closure remain acceptable for the FPGA target.

### 16.3 V2C: 3x3 Color Matrix

Trigger:

1. The product requirement expands from white-point correction to primary/secondary color accuracy.
2. RGBCMY measurements show a correct white point but unacceptable gamut or hue errors.

FPGA change:

1. Add a 3x3 fixed-point matrix after optional input linearization and before output encoding.
2. Keep matrix disabled or identity by default.
3. Provide saturation and rounding rules that avoid wraparound.

Pi4 change:

1. Measure RGBCMYW patches.
2. Compute a panel-specific correction matrix.
3. Store matrix coefficients in calibration JSON.
4. Load matrix coefficients at boot.

Acceptance:

1. White point remains within the v1 target.
2. RGBCMY error improves against the selected color-space target.
3. Peak luminance and saturation loss are quantified and accepted.

### 16.4 V2D: Temperature-Aware Profiles

Trigger:

1. Thermal white-point drift remains large after v1 calibration.
2. Measurements show repeatable white-point changes as a function of backlight temperature.

FPGA change:

1. No automatic temperature logic is required in the first version.
2. The FPGA continues to expose one active profile at a time.
3. Optional future register support may expose multiple active-profile slots if profile switching latency becomes a concern.

Pi4 change:

1. Measure and store multiple profiles at defined temperature bands.
2. Read backlight temperature using the existing `disptool-bltemp` path.
3. Load the appropriate profile at boot and optionally reload when temperature crosses hysteresis thresholds.

Acceptance:

1. Warm and hot white-point measurements improve versus a single static profile.
2. Profile switching does not create visible tint flashes; use frame-boundary commit.
3. Hysteresis prevents rapid profile flapping.

Recommended first profile bands:

```text
cold/warm: 30-40 C
nominal:   40-50 C
hot:       50-60 C
```

The exact bands should be based on real thermal data, not fixed by this PRD.

### 16.5 V2E: Local-Dimming And APL-Specific Calibration

Trigger:

1. Full-field white calibrates well, but windowed or content-like patterns show materially different white points.
2. The existing local-dimming APL sweep shows chromaticity shifts that matter to the product requirement.

FPGA change:

1. Prefer no new FPGA logic at first.
2. If needed, support loading different scalar/LUT profiles selected by the Pi4 or existing local-dimming state.

Pi4 change:

1. Extend calibration to measure full-field and selected window/APL patterns.
2. Decide whether production calibration should target full-field, windowed, or a weighted compromise.
3. Store calibration condition metadata clearly.

Acceptance:

1. The chosen calibration condition is documented.
2. White-point improvement is visible in the use cases that matter.
3. Calibration does not degrade full-field behavior beyond accepted limits.

### 16.6 V2F: Factory Golden Calibration Versus Per-Panel Calibration

Trigger:

1. Multiple panels have been measured with v1.
2. Unit-to-unit variation is known.

Options:

1. Golden calibration: one calibration file for the model.
2. Per-panel calibration: one calibration file per panel serial.
3. Hybrid calibration: golden default plus per-panel override when available.

Decision criteria:

1. If a golden profile brings all sampled panels inside tolerance with adequate margin, use golden calibration for production simplicity.
2. If panels vary enough that some remain outside tolerance, use per-panel calibration.
3. If panel serial readout is unreliable, provide an operator-entered or manufacturing-assigned identifier.

Acceptance:

1. The chosen approach is documented in the production process.
2. Calibration JSON lookup at boot is deterministic.
3. Missing per-panel calibration falls back to a known safe identity or golden profile.

### 16.7 V2G: C Boot Loader For Production

Trigger:

1. Python is inconvenient in the target image.
2. Boot-time loader startup must be smaller, faster, or easier to supervise.
3. Buildroot packaging favors a static or small C utility.

Change:

1. Replace or supplement `host/wp_load.py` with `host/wp_load.c`.
2. Preserve the same calibration JSON schema and register-map abstraction.
3. Keep `wp_calibrate.py` in Python because calibration remains measurement-bound and development-facing.

Acceptance:

1. The C loader writes the same logical register sequence as the Python loader.
2. Existing dry-run/mock tests pass for both loaders or for the production-selected loader.
3. systemd behavior is unchanged from the user's perspective.

### 16.8 V2H: TDDI Native White-Point Registers

Trigger:

1. TDDI documentation or a known-good vendor init sequence becomes available.
2. The TDDI's native white-point/gamma controls are proven safe and deterministic.

Approach:

1. Treat TDDI correction as a separate backend, not as an assumption in v1.
2. Compare TDDI correction against FPGA correction using the same measurement procedure.
3. Prefer FPGA correction unless TDDI correction gives better grayscale behavior with lower FPGA cost.

Acceptance:

1. The TDDI register protocol is documented.
2. Power-on defaults and boot-time sequencing are deterministic.
3. Recovery behavior is defined if TDDI writes fail.

### 16.9 V2I: Pi4 GPU Color Management

Trigger:

1. The product needs an experiment-only path or a fast software prototype.
2. The Pi4 graphics stack exposes stable color-management controls in the deployed OS.

Approach:

1. Keep this as a diagnostic or development path.
2. Do not make it the product default unless the OS, compositor, KMS driver, and application path are all controlled.

Acceptance:

1. Reboot and application startup reproduce the same color state.
2. The correction applies to all relevant content paths.
3. It does not conflict with FPGA calibration.

## 17. Extension Decision Gates

Before starting any future extension, collect and archive:

1. A v1 before/after report card.
2. The v1 calibration JSON.
3. A 10-100 IRE grayscale sweep after v1 calibration.
4. A thermal white-point drift run after v1 calibration.
5. A local-dimming/APL sweep after v1 calibration if local-dimming behavior is suspected.

Decision rules:

1. If 100% white is still outside tolerance, fix v1 gain math, measurement conditions, or FPGA register behavior before adding LUTs.
2. If only grayscale tracking is poor, consider V2A before V2B.
3. If color primaries/secondaries are poor but grayscale is acceptable, consider V2C.
4. If drift is mostly temperature-correlated, consider V2D before adding more FPGA math.
5. If behavior changes mainly with local-dimming pattern/APL, consider V2E.
6. If v1 already meets visual and measured requirements, do not add more correction stages.

## 18. Open Decisions

1. Final I2C slave address.
2. Final mapping from the product's outer FPGA register bank to the v1 `wp_adjust` logical subaddresses, if the logical map is not exposed directly.
3. Exact instrument and command path used by the Pi4 calibration script.
4. Warmup/stability threshold for production calibration.
5. Whether acceptance is based on `xy`, `Delta u'v'`, report-card tolerance, or all three.

## 19. Recommended Implementation Order

1. Keep scalar RTL under `rtl/wp_adjust.v` and integrate it in FPGA with identity default.
2. Add register write/read and commit/status around the FPGA block.
3. Build `host/wp_registers.py` with a mock backend and a hardware backend.
4. Build `host/wp_load.py` to write static gains from JSON.
5. Verify rough gains on the current 12.3-nq1v1 unit.
6. Build `host/wp_calibrate.py` on top of existing display-test-framework measurement hooks.
7. Run iterative calibration and generate before/after report cards.
8. Decide whether LUT/grayscale work is justified by measured residuals.
