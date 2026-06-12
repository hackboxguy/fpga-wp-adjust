# Fable Review: fpga-wp-adjust

Date: 2026-06-12
Reviewed at: commit `64af0d2` (main)
Reviewer: Claude (Fable 5), design/concept review requested for the side-by-side
display white-point matching use case.

## Scope and Method

Reviewed: `rtl/wp_adjust.v`, `rtl/wp_adjust_cdc_bridge.v`, both testbenches,
`host/` (math, register adapter, loader, schema, tests), all docs, example
wrapper and seed JSON. Verified locally before review: `make test`,
`make synth-check`, `make host-test` (31 passed), and `make validate-json` all
pass.

The stated use case for this review: the block sits last in a display video
pipeline (before LVDS TX) and is tuned over I2C so that one display's white
point can be shifted to match a second display placed side-by-side.

## Verdict Summary

The architecture is sound and unusually well-disciplined for a block of this
size: shadow/active double buffering with frame-boundary commit, magic-guarded
COMMIT/DEFAULTS, pass-through reset defaults, saturating round-to-nearest math,
a clean toggle-handshake CDC bridge, and a host stack that mirrors the RTL
contract. No functional bug was found in the committed datapath for the
default `PIXEL_BITS=10 / FRAC_BITS=12` configuration.

The significant findings are conceptual and operational, not datapath bugs:

1. The calibration model is written for absolute D65 correction; the
   side-by-side *matching* workflow (relative target, luminance matching,
   tighter perceptual tolerance) is not covered and needs explicit treatment.
2. Several safety properties are enforced only by host discipline (shadow
   writes during pending commit, no gain sanity bounds in the boot loader, no
   write readback verification) — exactly the places where a noisy I2C link or
   a corrupt-but-schema-valid JSON can produce a visibly broken display.
3. The CDC bridge is logically correct but ships with no synthesis/timing
   constraint guidance, which is where real-world CDC designs actually fail.
4. Parameterization (`FRAC_BITS`, `PIXEL_BITS`) is fragile outside the default
   values and is untested at any other value.

## What Is Done Well

- **Atomic frame-boundary commit.** Shadow/active double buffering with the
  commit consumed on a glitch-filtered vsync edge eliminates partial-frame
  tint during live I2C tuning — the single most important property for the
  side-by-side tuning workflow, and it is tested.
- **Magic-number-guarded COMMIT (`0xCA1B`) / DEFAULTS (`0xD65D`).** Stray bus
  writes cannot accidentally commit or reset.
- **Pass-through by reset default** and exact pass-through in disabled mode
  (bypass mux, not unity-gain multiply), so insertion is zero-risk until
  enabled.
- **DEFAULTS as an immediate panic-to-safe path** that also cancels a pending
  commit, with the partial-frame caveat documented.
- **Correct fixed-point hygiene:** zero-extended operands into signed
  multiplies, adequate accumulator width (worst case product + shifted offset
  fits ACC_BITS with margin), round-half-up at the Q point, saturate high,
  clamp negative to zero. Tie-rounding and saturation are tested.
- **The CDC bridge handshake is textbook-correct:** toggle request/ack through
  2-flop synchronizers with payload held stable until the matching toggle
  returns; held-`bus_req` re-fire is explicitly tested.
- **Honest docs.** The PRD states the code-domain (not linear-light) gain
  limitation, the commit-arms-but-does-not-snapshot semantics, the
  pending-until-video boot case, and the reset coupling rules of the bridge.
  The implementation plan's hardware-free/hardware-gated track split is a
  genuinely good way to protect bench time.
- **Host/RTL contract symmetry:** the mock backend reproduces the RTL
  shadow/active/commit semantics, and loader tests exercise the same sequence
  rules the RTL docs require.

---

## 1. Concept-Level Findings (Side-by-Side Matching Use Case)

### C1. The calibration model targets absolute D65, not display-to-display matching — HIGH (for the stated use case)

The PRD, seed JSON, and acceptance criteria are all written around moving one
display to D65. Side-by-side matching is a *relative* problem:

- The target chromaticity should be the **reference display's measured white**
  (or a common achievable point), not D65. `solve_linear_gains()` already
  accepts an arbitrary `target_xy`, so the math supports this — but no doc,
  schema field, or workflow describes it. The schema's `target_white` only has
  `name/x/y`; there is no way to record "target = serial-XYZ measured at
  condition C", which matters for field debugging of a matched pair.
- **Which display to correct is a real decision.** With the headroom-preserving
  `[0.5, 1.0]` gain policy, each display can only be pulled *toward* a white
  reachable by attenuation. For a pair, the robust strategy is to compute a
  common target both panels can reach with ≤ unity gains (typically the
  "worse" panel's white, or an intermediate point) and correct **both**
  displays toward it. Correcting only one display toward the other works only
  if the reference happens to be inside the corrected display's attenuation
  cone.

**Recommendation:** add a short "pair matching" section to the PRD/integration
guide: measure both panels under the identical warm condition, choose the
common target, calibrate both, and record the pair linkage (target source,
peer serial) in the JSON (`target_white.name` is free-form today and can carry
this, but an explicit optional field is better).

### C2. Chromaticity matching without luminance matching will not look matched — HIGH

Gain-only attenuation reduces peak luminance of the corrected display. Two
adjacent displays matched in xy but differing by even 5–10% in luminance are
visibly different — side-by-side luminance discrimination is on the order of
1–2%. The PRD records luminance loss (acceptance #9, 20% review gate) but for
a *single* display against D65. For pairs, the procedure must co-manage:

- backlight/brightness command matching (the existing brightness path), and
- the luminance cost of the chromaticity gains,

iterating both together. This is a host-procedure gap, not an RTL gap, but it
is the difference between "calibrated" and "looks matched."

### C3. Side-by-side viewing demands much tighter tolerance than the report-card target — MEDIUM

The PRD's convergence target (xy distance < 0.005, Δu′v′ < 0.004) is reasonable
for a single display against a spec. Two displays sharing a bezel are a
direct simultaneous comparison; just-noticeable white differences in that
configuration are commonly quoted around Δu′v′ ≈ 0.002 or below. A pair can
each pass the single-display target and still show a visible seam tint
(worst-case pair distance ≈ 2× the individual tolerance radius).

**Recommendation:** for pair matching, define the acceptance metric as the
*distance between the two displays* (e.g., Δu′v′ between panels < 0.002–0.003),
not each panel's distance to an absolute target.

### C4. 100%-white matching does not guarantee gray matching between two different panels — MEDIUM

One subtle point in the design's favor: on an *ideal* power-law panel,
a code-domain scalar gain `g` produces a constant linear-light scale
`g^γ` at **every** gray level, so white-point correction would track perfectly
down the grayscale. The PRD's gamma-compensated seed math exploits this. But
between two real panels:

- the two panels' transfer functions differ (different γ, different near-black
  deviation), so equal-at-white does not imply equal-at-25%-gray;
- local dimming makes the effective transfer content-dependent and per-panel;
- offsets, if ever enabled, deliberately break the power-law invariance.

This is exactly the V2A (output LUT) trigger the PRD already defines. For the
side-by-side use case, add a **gray-ramp pair comparison** (e.g., 25/50/75%
patches on both displays) to the v1 acceptance/decision-gate data, since
adjacent gray mismatch is more noticeable than absolute gray error.

### C5. Differential thermal drift will un-match a matched pair — MEDIUM

The PRD's own data shows ~0.008 xy drift over ~20 °C on one panel. Two
side-by-side panels generally run at different temperatures (airflow, position,
content) and drift differently, so a pair matched cold can be visibly
mismatched warm. V2D (temperature-banded profiles) covers this, but the v1
pair-matching procedure should at minimum: calibrate both panels at the same
stabilized warm condition representative of deployment, and record both
panels' backlight temperatures (the JSON already has the field — make it
required practice for pairs).

### C6. Quantization: sub-unity gain on a 10-bit path loses codes; no dithering — LOW/MEDIUM

With gain ≈ 0.92, 1024 input codes map to ~944 output codes: ~80 input pairs
collapse to the same output value. For static imagery and small trims this is
usually invisible, but on shallow gradients it can produce mild contouring,
and this block is the *last* math before the panel, so nothing downstream can
hide it. Options, in increasing effort:

1. Document it as accepted for |gain − 1| ≤ ~0.15 (probably fine for trim).
2. Add optional LSB spatial/temporal dithering (or blue-noise-ish 2×2 ordered
   dither) on the rounding step — small LUT-free logic, big banding benefit.
3. Fold into the V2A LUT stage with higher internal precision.

Worth a sentence in the integration guide either way, since "is this block
allowed to introduce banding?" is the first question a display-pipeline owner
will ask.

### C7. Scalar global gain cannot address spatial nonuniformity at the seam — LOW (scope note)

Side-by-side matching is most visible at the adjacent edges. If the two panels
have opposing edge-tint/uniformity gradients, a global per-channel gain cannot
fix the seam even when center-screen whites match. Out of scope for v1 — but
state it as a known limitation so it isn't reported as a calibration failure.

---

## 2. RTL Findings (`rtl/wp_adjust.v`)

### R1. Parameter range is fragile and unchecked — MEDIUM

- `FRAC_BITS = 1` makes `ROUND_Q`'s `{(FRAC_BITS-1){1'b0}}` a zero-width
  replication (illegal in Verilog-2001); `FRAC_BITS = 0` is a negative count.
- `FRAC_BITS = 16` makes `UNITY_GAIN = (1 << 16)` overflow the 16-bit
  `COEFF_BITS` localparam to 0 — reset defaults become gain 0 (black screen)
  with no elaboration error.
- `PIXEL_BITS ≥ 16` makes the signed 16-bit offsets narrower than the pixel
  range; offsets silently lose reach.

The legal envelope is effectively `2 ≤ FRAC_BITS ≤ 15`, `PIXEL_BITS ≤ ~14`.
Add elaboration-time guards (e.g., an `initial if (...) $error(...)` block or
a width-mismatch trick for tools without `$error`) and document the range in
the header. Cheap insurance against a silent black-screen misconfiguration.

### R2. Blanking-interval pixels are processed, not gated — LOW/MEDIUM

The header states it explicitly: gain/offset math is applied during blanking;
`de` only travels alongside. With a positive offset enabled, RGB during
blanking becomes nonzero. Most LVDS/FPD-Link transmitters qualify data with
DE so this is normally harmless, but some downstream logic (TCONs that snoop
blanking codes, CRC/test monitors, anything reusing blanking as a side
channel) will see changed values. Either:

- force outputs to zero when delayed-DE is low (one mux on the output stage), or
- keep the current behavior and add an explicit statement to the integration
  guide that blanking-interval pixel values are not preserved.

### R3. `in_vsync` polarity is assumed active-high with no parameter — LOW/MEDIUM

If the integration accidentally feeds active-low vsync, the "filtered rising
edge" becomes the sync *deassertion* edge — which usually still lands inside
vertical blanking, so the failure would be silent and probably benign, i.e.,
the worst kind to discover later. Suggest a `VSYNC_ACTIVE_HIGH` parameter (one
XOR) or at least a bring-up checklist item: "scope/ILA-verify that the commit
edge falls inside vertical blanking for your timing."

### R4. A pending commit can only be cancelled by destroying calibration — LOW/MEDIUM

The only way to clear `commit_pending` is `DEFAULTS`, which also wipes shadow
*and* active registers. If the host arms a commit and then decides the staged
values are wrong (and video is not running, so the commit may sit armed
indefinitely — the documented boot case), the recovery path discards the
active calibration too. Suggest a `COMMIT_CANCEL` magic write (clear pending,
leave shadow/active untouched) in the next register-map revision.

### R5. "Don't write shadow while pending" is host discipline only — LOW (documented)

`COMMIT` arms rather than snapshots, and the RTL accepts shadow writes while
pending; atomicity then depends on every host (including future debug scripts
and humans with an I2C poker) following the rule. Two cheap hardware options
for a future rev: snapshot shadow into the active-side staging at COMMIT-write
time, or reject shadow writes while pending and latch a sticky
"write-ignored" status bit so violations are at least detectable. The current
behavior is fine *because* it is documented in three places — keep it that
way if unchanged.

### R6. Read-data interface details worth documenting — LOW

`cfg_rdata` is a pure combinational mux on `cfg_addr` (zero-cycle read). That
is exactly what the CDC bridge expects, but an integrator wiring `cfg_*` into
an existing registered register file should be told. Related nit: for write
transactions through the bridge, `bus_rdata` returns the *pre-write* value of
whatever `cfg_addr` selects; harmless, but specify "rdata is undefined for
writes" in the bridge contract.

### R7. Datapath consistency through a commit — verified OK (no action)

Checked: scaled and offset terms are registered in the same stage from the
same active-register generation, so a commit landing mid-pipeline cannot mix
old gain with new offset on one pixel; the commit edge is in blanking anyway.
Same-edge collisions (DEFAULTS vs. vsync-commit, shadow-write vs. latch) all
resolve in a sane order due to last-assignment-wins. No issue.

---

## 3. CDC Bridge Findings (`rtl/wp_adjust_cdc_bridge.v`)

### B1. No timing-constraint guidance or attributes — MEDIUM (highest practical CDC risk)

The handshake logic is correct, but in synthesis nothing marks it as CDC:

- Synchronizer flops (`*_meta`/`*_sync`) carry no `ASYNC_REG` /
  `syn_preserve`-style attributes; optimization or retiming can merge or move
  them, silently degrading MTBF.
- The quasi-static payload buses (`req_we/addr/wdata_hold` crossing to
  pix, `pix_rdata_hold` crossing to bus) need `set_false_path` or, better,
  `set_max_delay -datapath_only` constraints so payload skew cannot exceed the
  toggle round-trip assumption.

This repo targets Lattice ECP5-class flows per the PRD. Recommend adding a
`constraints/` example (or a section in the integration guide) with the
required SDC/LPF lines and the attribute annotations in the RTL. This is the
most common way an "it simulated fine" bridge fails on hardware.

### B2. Single-domain reset deadlocks with no detection — LOW (documented)

If one domain resets while a transaction is in flight, the toggles disagree
forever and `bus_busy` sticks high. The docs forbid this, which is fine, but
there is no fault status or recovery short of resetting both domains. Worth
one line in the integration guide telling the outer transport to implement a
transaction timeout that escalates to a both-domain bridge reset, so a field
failure is recoverable rather than a permanent register-bus hang.

### B3. Throughput is one transaction per toggle round trip — OK (no action)

A few bus + pixel clock cycles per 16-bit register access is far faster than
I2C will ever ask for. A full calibration load is 9 writes; fine.

---

## 4. Host Software Findings (`host/`)

### H1. The boot loader applies no gain sanity bounds — MEDIUM

`wp_math.enforce_gain_limits()` exists, but `wp_load.apply_profile()` never
uses it, and the schema allows any gain in `[0, 65535]`. A schema-valid JSON
with `gains: {r:0, g:0, b:0}` (or `0xF000` ≈ 15×) loads cleanly at boot and
black-screens or blows out the display. Since this runs unattended from a
systemd unit, the loader should enforce a plausibility window by default
(e.g., code-domain `[0.25, 1.0]`, i.e., raw `[0x0400, 0x1000]` for Q4.12)
with an explicit `--allow-out-of-range` escape hatch, mirroring the PRD's
"any mode permitting gains above unity must be explicit" rule.

### H2. No readback verification of shadow writes before COMMIT — MEDIUM

`write_calibration()` writes 5 registers and immediately commits. Over a real
I2C link (FPD-Link sideband channels included), a corrupted or NAK'd write
that the transport layer mis-reports leads to committing garbage. The shadow
registers are readable — read them back and compare before issuing COMMIT
(and optionally read the active set after commit-consumed to confirm).
This is a ~10-line change in `wp_registers.write_calibration()` /
`wp_load.apply_profile()` and removes the largest silent-failure path in the
boot flow.

### H3. JSON `format: date-time` is not actually validated — LOW

`validate_profile()` uses `jsonschema.Draft7Validator` without a
`FormatChecker`; in draft-07 `format` is annotation-only by default, so
`"created_utc": "yesterday-ish"` validates. Pass
`format_checker=jsonschema.FormatChecker()` (and add the dependency extras if
needed) or drop the implied guarantee from the schema comment.

### H4. PRD deliverables not yet present: `wp_calibrate.py`, systemd unit, hardware backend — LOW (tracked, but reconcile docs)

PRD §11 lists `host/wp_calibrate.py` and `host/systemd/wp-calibration.service`
as "initial host deliverables," and §13 describes loader behavior (wait for
I2C path, journal logging) that the current dry-run/mock-only loader cannot
do. The implementation plan correctly defers these to B4/B5, but the PRD reads
as if they exist. Suggest a one-line status note in the PRD (or README) so a
new integrator doesn't go looking for the calibration tool.

### H5. Loader always sets `enable=1` — OK as documented (no action)

`apply_profile()` forcing `CONTROL.enable=1` is a deliberate, documented
choice ("v1 profiles are calibration profiles"). Fine; just preserve the
docstring if the loader grows a pass-through profile concept later.

---

## 5. Verification Gaps

### V1. Directed-only RTL testing; no reference-model co-simulation — MEDIUM

The directed bench covers the contract well (commit atomicity, glitch filter,
defaults, saturation, ties), but the arithmetic is checked at a handful of
points. A randomized sweep (random pixel × random gain/offset, compared
against a Python/golden model — `wp_math.fixed_to_gain` already defines the
semantics) would cover rounding/saturation corners cheaply: max gain
(`0xFFFF`), gain+offset saturating high, offset more negative than scaled
value at various magnitudes, all-zero/all-max pixels. The implementation plan
already lists this as optional A1 work; recommend promoting it to required
before B1, since the datapath is the part nobody will be able to scope on
hardware.

### V2. Parameterization is untested at any non-default value — MEDIUM (pairs with R1)

Both benches hardcode `PIXEL_BITS=10, FRAC_BITS=12`. Given the PRD explicitly
says "if the actual FPGA pixel path is not 10-bit, set PIXEL_BITS to the real
width," at least one alternate build (e.g., 8/12 and 12/12) should compile and
pass in CI — that would also have flagged R1's illegal-replication edges.

### V3. Sync-alignment latency is asserted in docs, not tested — LOW

The 2-cycle latency claim for `de/hsync/vsync` vs. RGB is implicitly relied on
(`drive_pixel_and_wait` waits 3 cycles and samples steady state) but never
checked edge-accurately. A small test driving a single-cycle DE pulse and
checking it emerges exactly 2 clocks later, aligned with its pixel, would
lock the contract the LVDS TX cares most about.

### V4. CDC bench uses one fixed clock pair — LOW

7 ns vs. 5 ns exercises the logic but only one phase relationship family.
Cheap improvements: run the bridge bench at 2–3 clock ratios (including
bus_clk faster than pix_clk, and a near-integer ratio), and/or add a few
hundred randomized back-to-back transactions. Formal (SymbiYosys) on the
toggle handshake would be the gold-plated option and the design is small
enough for it.

### V5. Negative tests for the register interface — LOW

Untested but implemented behaviors worth pinning: writes to RO/active
addresses are ignored, wrong COMMIT/DEFAULTS magic values are ignored,
unknown-address reads return 0. One short directed block covers all three.

---

## 6. Documentation / Process Nits

- **D1.** Register map says gain example `1.5 = 16'h1800` — valid for the
  format, but sits oddly next to the `[0.5, 1.0]` safety policy; a one-word
  "(outside v1 safety policy)" annotation would prevent someone treating it as
  an endorsed value.
- **D2.** `STATUS[1]` ("commit consumed, sticky until next COMMIT/DEFAULTS")
  semantics are correct everywhere but subtle: after boot with no commit ever
  issued, it is 0, so "wait for STATUS[1]==1" only works per-transaction.
  The docs handle this; keep the loader's `commit_status_unknown` state.
- **D3.** Consider adding the CDC constraint examples (B1) and the
  blanking-behavior statement (R2) to `docs/integration-guide.md` — both are
  integration contract items, not RTL changes.
- **D4.** `CHANGELOG` "Unreleased" is accurate; tag `v0.2.0-host-mock-stack` /
  `v0.3.0-cdc-sim-verified` per the implementation plan's checkpoint scheme —
  the repo state appears to satisfy both exit criteria already.

---

## Prioritized Recommendations

| # | Finding | Severity | Effort |
|---|---------|----------|--------|
| 1 | H2: read-back verify shadow writes before COMMIT | Medium | Small |
| 2 | H1: gain plausibility bounds in the boot loader | Medium | Small |
| 3 | B1: CDC synthesis attributes + SDC/constraint examples | Medium | Small |
| 4 | C1–C3: document the pair-matching workflow (relative target, calibrate both, luminance co-matching, pair-delta acceptance metric) | High for the stated use case | Doc-only |
| 5 | R1 + V2: parameter guards and one alternate-parameter CI build | Medium | Small |
| 6 | V1: randomized co-sim vs. golden model before hardware bring-up | Medium | Medium |
| 7 | C4/C5: add gray-ramp pair comparison and same-warm-condition rule to acceptance data | Medium | Doc/procedure |
| 8 | R2/R3: blanking gating decision + vsync polarity parameter or checklist item | Low/Med | Small |
| 9 | R4: COMMIT_CANCEL magic in next register-map rev | Low/Med | Small RTL |
| 10 | C6: decide and document the dithering position | Low/Med | Doc or small RTL |
| 11 | H3: enable jsonschema FormatChecker | Low | Trivial |
| 12 | V3–V5, D1–D4 | Low | Small |

## Appendix A: Comparison Against the Legacy disp-tester Solution (added 2026-06-12)

Reviewed after the initial review: the legacy profiling/matching stack at
`tmp-folder/br-wrapper/package/disp-tester/src/white-point-profile-child.py`
and `white-point-match-child.py`, plus the measured profile dataset in
`tmp-folder/profile-data/` (i1Display Pro on Pi4, captured 2026-06-11,
31 points × 5 samples, all `ok`).

### A.1 What the legacy solution is

The legacy FPGA exposes three white-point registers `wpx/wpy/wpz` in
`[0, 256]` with `256` = unity, written one at a time through `disptool`
(immediate effect, no shadow/commit). The match tool measures a reference
display, measures the target, then does a brute-force search over integer
*reductions* from 256 (default `--max-reduction 10`) using a linear local
model (slopes seeded from the profile JSON or built-in defaults), applies the
best candidate, re-measures, and iterates up to 3 times against
`--tolerance-xy 0.002`.

### A.2 Quantified limitations, confirmed by the measured data

1. **Step size is larger than the matching tolerance.** From the measured
   sweep, one LSB moves the white point by approximately:

   | Register | Δx / step | Δy / step | xy magnitude / step |
   |---|---:|---:|---:|
   | `wpx` | +0.00155 | +0.00264 | ≈ 0.0031 |
   | `wpy` | +0.00004 | −0.00138 | ≈ 0.0014 |
   | `wpz` | −0.00070 | −0.00016 | ≈ 0.0007 |

   The coarsest axis moves ~1.5× the 0.002 tolerance per single count, so the
   quantization floor (~±0.0015 xy) is on the same order as the target. This
   is the mechanical reason the legacy match is "not granular enough" — no
   amount of iteration can land closer than half a step.

2. **Brightness is sacrificed and never matched.** Corrections are
   reduction-only (`solve_candidate` searches downward from 256), the script
   explicitly does not match brightness, and the sweep shows the cost:
   `wpx` 256→247 (≈ −3.5% code) loses ~1.9% luminance (1050.9 → 1031.1 nits);
   `wpy` 256→246 loses ~8% (→ 966.1 nits). A matched target display always
   ends dimmer than it started, with no policy minimizing the loss.

3. **Immediate, per-register writes.** The three registers are written
   sequentially with live effect — transient mixed states are visible on
   screen during adjustment, unlike the shadow/COMMIT frame-boundary model.

4. **Measurement noise is not the limiter.** Sample stddev in the dataset is
   ~1–4 × 10⁻⁵ in xy — about 100× smaller than the legacy step size. The
   sensor and procedure are good; the actuator is coarse. This also means the
   new block's finer steps are fully exploitable with the existing i1Display
   Pro setup, and ~3 samples per point would suffice.

### A.3 How wp_adjust addresses this

| Property | Legacy wpx/wpy/wpz | wp_adjust v1 |
|---|---|---|
| Gain resolution | 1/256 (0.39%/LSB) | 1/4096 (0.024%/LSB), 16× finer |
| Per-LSB xy motion (worst axis, this panel) | ≈ 0.0031 | ≈ 0.0002 |
| Quantization floor vs 0.002 tolerance | ~±0.0015 (marginal) | ~±0.0001 (negligible) |
| Brightness policy | Unconstrained reductions | Strongest channel held at unity (`normalize_to_headroom`), minimum loss for gain-only |
| Update atomicity | Per-register, immediate | All-channel shadow + frame-boundary COMMIT |
| Solver | Linear local model + brute-force integer search | Exact colorimetric 3×3 solve + gamma conversion + damped iteration |

For two displays both already near D65, expected code-domain gains are
≈ 0.96–1.0, so worst-case luminance cost of the chromaticity match is roughly
≤ 2% — versus the legacy tool's uncontrolled loss. If even that matters, the
options are brightness-preserving mode (boost weak channels above unity,
trading highlight clipping headroom — supported by Q4.12 but gated by the
explicit-override policy) or backlight compensation on the brighter unit.

### A.4 Worth porting from the legacy stack

The legacy scripts contain genuinely good procedure logic that the future
`wp_calibrate.py` / match tool should inherit rather than reinvent:

- the operator-driven reference→target two-phase flow with overlay prompts
  and Start gating (`wait_for_start`, `ControlPipe`);
- slope-model seeding from a measured profile sweep (`load_profile_model`)
  — directly reusable as the Jacobian seed for the damped iteration, with the
  sweep re-run once against the new gain registers;
- robust spotread handling: retry groups, failure budgets, USB
  presence checks, placement check, atomic JSON/CSV recording.

Note the legacy `disptool --device=fpga --command=wpx` transport does not
speak the new register map; a thin backend implementing
`RegisterBackend.read16/write16` over the board's I2C path replaces it
(the planned B4 work).

## Appendix B: Fixability Assessment of the 12 Recommendations (added 2026-06-12)

> Status update (2026-06-12): all 12 items have been implemented — see
> CHANGELOG "Unreleased". Batch 1 covered the nine zero-risk items (1, 2, 3,
> 4, 6, 7, 10, 11, 12); batch 2 added the parameter guards + alternate-param
> CI builds (5), the opt-in `GATE_BLANKING`/`VSYNC_ACTIVE_HIGH` parameters
> (8), and COMMIT cancel `0xC0FF` with the register-map revision bump to
> `0x0113` (9). The br-wrapper legacy-procedure port remains a gated
> follow-up recorded in `docs/pair-matching.md` and implementation-plan B5.

Assessment of which items can be fixed without regression risk, given the
goal: fine-grained trim around D65 plus matching a second near-D65 display.

**All 12 are addressable. Nine are unconditionally safe** (host-, doc-, or
test-only; the proven RTL datapath is untouched). **Three touch RTL or the
register map and are still safe if done conservatively** (defaults preserve
current behavior; every change is covered by the existing simulation/CI
harness before merge).

| # | Item | Risk class | Safe approach |
|---|---|---|---|
| 1 | H2 write-readback verify | Host only | Verify shadow regs before COMMIT; teach `DryRunBackend` to echo writes so dry-run still passes |
| 2 | H1 loader gain bounds | Host only | Default window e.g. `[0x0400, 0x1000]` + explicit override flag; seed profile (0x0EC3–0x1000) stays valid |
| 3 | B1 CDC attributes + SDC | RTL-annotation only | Verilog attributes are inert to simulation and unknown tools; constraints shipped as docs/examples |
| 4 | C1–C3 pair-matching workflow docs | Doc only | Now quantifiable from the legacy profile data (Appendix A) |
| 5 | R1+V2 param guards + alt-param CI build | RTL elaboration-time only | Guard block rejects illegal params at elaboration; verify `make test`/`synth-check` unchanged at defaults; add 8/12-bit compile+unity-passthrough CI leg |
| 6 | V1 randomized co-sim | Test only | Reference model computed in-TB; only adds coverage |
| 7 | C4/C5 gray-ramp + warm-condition acceptance | Doc/procedure only | — |
| 8 | R2 blanking / R3 vsync polarity | RTL behavior | Do NOT change defaults: add opt-in `VSYNC_ACTIVE_HIGH`-style parameters defaulting to today's behavior, plus integration-guide statements |
| 9 | R4 COMMIT_CANCEL | Register map addition | New magic on 0x7E (currently ignored value → backward compatible); bump VERSION minor; update map/mock/TB together |
| 10 | C6 dithering | Decision | Resolve as documentation: at gains ≥ 0.96 (the near-D65 matching case) code-collapse is ≤ ~40 of 1024 codes; defer RTL dither unless gradients show banding on hardware |
| 11 | H3 FormatChecker | Host only | One-line enable; degrades gracefully if rfc3339 validator absent |
| 12 | V3–V5 negative/latency/CDC tests, D1–D4 doc nits | Test/doc only | — |

Recommended batching: land 1–7 and 10–12 as one pass (no behavioral RTL
change at all); land 5, 8, 9 as a second pass with the register-map version
bump, since 9 changes the documented map and 8 adds parameters. For the
stated side-by-side goal specifically, items 1, 2, 4, and 7 carry the most
practical value, and Appendix A's granularity/brightness analysis confirms
the core design already solves the two legacy complaints without further RTL
change.

## Closing Assessment

For its intended v1 role — a safe, atomic, host-tunable RGB trim at the end of
the pipeline — this design is in good shape, and the engineering discipline
(double buffering, magic guards, pass-through defaults, honest docs, staged
plan) is above average for a block of this size. The work needed before
trusting it for *side-by-side matching* specifically is mostly procedural:
define the relative-target workflow, co-manage luminance, tighten the pair
tolerance, and close the unattended-boot safety holes (H1/H2). The RTL items
(R1–R4, B1) are all small and best done before first hardware integration,
when they are cheap.
