# Side-by-Side Display Pair Matching

This guide covers using `wp_adjust` to match the white points of two displays
mounted side by side, both of which are individually calibrated near D65.
Pair matching is a *relative* problem and differs from the absolute-D65
calibration flow in the PRD in target selection, tolerance, and acceptance.

The quantitative claims below are grounded in the measured legacy profile
dataset (i1Display Pro on Pi4, 12.3-class panel, 2026-06-11) reviewed in
`docs/fable-review.md` Appendix A.

## Why The Legacy wpx/wpy/wpz Approach Was Insufficient

The previous FPGA exposed three white-point registers with a 1/256 gain step.
Measured on hardware, one LSB of the coarsest register moved the white point
by ~0.0031 in xy — larger than the 0.002 matching tolerance, so the
quantization floor (~±0.0015) prevented a reliable match. Corrections were
also reduction-only with no headroom policy, so the matched display always
lost brightness (measured up to ~8% for ten counts on the green-dominant
register), and brightness was never re-matched.

`wp_adjust` Q4.12 gains step at 1/4096 (16x finer): the equivalent per-LSB
white-point motion is ~0.0002 in xy, comfortably below any practical pair
tolerance, and the headroom-preserving policy keeps the strongest channel at
exactly unity so the luminance cost of a chromaticity match is the minimum
achievable for gain-only correction (typically under ~2% for two near-D65
displays).

## Target Selection

1. Do not target absolute D65 for pair matching. Measure both displays under
   the identical condition and pick a **common target chromaticity both
   panels can reach with gains at or below unity** — in practice the measured
   white of the "worse" panel, or an intermediate point between the two
   whites.
2. Correct **both** displays toward the common target when needed. Correcting
   only one display works only if the reference white happens to be reachable
   by attenuation from the other panel's primaries.
3. Record the pair linkage in each calibration JSON: set
   `target_white.name` to something traceable (for example
   `pair:<peer-serial>:measured-white`) and add a note with the peer serial
   and the measurement timestamp. This is what makes a field-returned pair
   debuggable.

## Measurement Condition

1. Calibrate both panels at the **same stabilized warm condition**
   representative of deployment. The measured thermal drift on this panel
   class is ~0.008 xy over ~20 C — far larger than the matching tolerance —
   and two adjacent panels generally run and drift differently.
2. Record `backlight_temp_c` in both calibration JSONs. Treat a pair match
   without recorded temperatures as unverifiable.
3. Use the same pattern (full-field 100% white), brightness command, and
   local-dimming state on both panels.

## Luminance Co-Matching

A chromaticity match alone will not look matched: adjacent displays differing
by even a few percent in luminance are visibly different (side-by-side
discrimination is on the order of 1-2%). The procedure must co-manage:

1. Brightness/backlight command matching between the two units, and
2. the small luminance cost of the chromaticity gains on each unit,

iterating both until *both* chromaticity and luminance deltas are inside
tolerance. Record the final luminance of both panels in the calibration
JSONs (`verification.final_xyY.Y`).

## Acceptance Metric

For a shared-bezel pair, use the **distance between the two displays**, not
each display's distance to an absolute target:

1. Primary: delta u'v' between the two measured whites <= 0.002-0.003.
2. Luminance: |Y1 - Y2| / max(Y1, Y2) <= ~2%.
3. Each panel individually still inside its absolute report-card tolerance.

Two panels can each pass a 0.005 absolute target and still show a visible
seam tint (worst-case pair distance is twice the individual radius), so the
pair metric is the binding one.

## Gray-Ramp Pair Check

Matching at 100% white does not guarantee matching at gray, because the two
panels' transfer functions differ (gamma, near-black behavior, local-dimming
response). After the white match, measure both panels at 25/50/75% gray
patches and record the pair delta u'v' at each level. If gray tracking
between the panels is visibly worse than the white match, that is the V2A
(output LUT) trigger in the PRD — collect this data before deciding any V2
work.

## Quantization Note

At pair-matching trim levels (gains ~0.96-1.0) code-collapse from sub-unity
gains is small; see "Quantization And Banding" in
`docs/integration-guide.md` for the gradient-check guidance at larger trims.

## Follow-Up: Port The Legacy disp-tester Procedure Logic (br-wrapper repo)

**TODO — scheduled for after the new RTL is integrated on hardware and
bench-tested (Track B2/B3 of `docs/implementation-plan.md`).**

The legacy color-matching stack in the `br-wrapper` repo
(`package/disp-tester/src/white-point-profile-child.py` and
`white-point-match-child.py`) has proven operator-procedure logic that the
new matching tool should inherit rather than reinvent:

1. The operator-driven two-phase flow: reference measurement -> sensor move
   prompt -> target measurement, with overlay prompts and Start-button gating
   (`wait_for_start`, `ControlPipe`).
2. Slope-model seeding from a measured profile sweep (`load_profile_model`):
   re-run the profile sweep once against the new gain registers and use the
   measured slopes as the Jacobian seed for the damped iteration in the new
   solver.
3. Robust spotread handling: retry groups, per-point failure budgets, USB
   presence checks, placement check, and atomic JSON/CSV result recording.

What must change in the port:

1. Replace the `disptool --device=fpga --command=wpx/wpy/wpz` transport with
   a board backend implementing the `RegisterBackend.read16/write16`
   protocol from `host/wp_registers.py` (the planned B4 hardware backend),
   using the shadow/COMMIT/STATUS sequence — never direct live writes.
2. Replace the brute-force integer reduction search with the colorimetric
   solve + damped iteration from `host/wp_math.py`, with gains in Q4.12.
3. Write calibration results in the `wp-cal-v1` schema
   (`host/schema/wp-cal-v1.schema.json`) with the pair-linkage metadata
   described above, instead of the legacy
   `als-dimmer-white-point-calibration-v1` payload.
4. Add the luminance co-matching and gray-ramp pair checks from this guide
   to the procedure.

This work lives in the `br-wrapper` repository, not here; this section exists
so the dependency is not forgotten once the RTL side is ready.
