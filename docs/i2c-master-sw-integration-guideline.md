# Pi4 I2C-Master SW Integration Guideline (wp_adjust)

Date: 2026-06-13
Author: Claude (Fable 5)
Scope: the remaining host/Pi4 software work in `br-wrapper` (disp-tester app,
launcher, boot services) and `fpga-wp-adjust/host/` needed for final
integration testing, once the RTL integration
(`docs/display-integration-guideline.md`) lands on hardware.

## 1. Decisions (answers to the open questions)

### 1.1 The legacy `0x1D` slave is NOT remapped — deliberately

- In **pixelpipe-fpga**, the `0x1D` writable register window is **`0x28`–`0x36`
  only** (`ctrl_regfile.v`, single source of truth; the pre-P1 BRAM "only ever
  had 0x28-0x36 written"). The legacy white-point registers `wpx/wpy/wpz` at
  `0x37/0x39/0x3B` (which disptool's `--device=fpga --command=wpx` writes)
  **do not exist in this FPGA** — such writes are silently ignored. They
  belonged to the older display FPGA the legacy matching app was built
  against.
- Therefore: no remapping, no collision, no migration. The legacy
  white-point flow simply has no effect on pixelpipe-fpga displays, and
  `0x1D` is being phased out anyway.
- **wp_adjust is `0x1E`-only**, on its own page. Nothing wp_adjust-related
  is ever added to the `0x1D` map.

### 1.2 The boot-writable register mapping IS decided: `0x1E` page `0x03`

The wp_adjust logical map (8-bit register, 16-bit data; see
`docs/register-map.md`, revision `0x0113`) is exposed on the new I2C slave
`7'h1E` as **page `0x03`**, **2 bytes per logical register, big-endian**:

```text
page-3 byte offset = logical_register << 1     (even = hi byte, odd = lo byte)
```

Full byte map the Pi4 writes/reads:

| Logical reg | Name | Access | Page-3 byte offsets |
|---:|---|---|---|
| `0x00` | CONTROL_SHADOW | RW | `0x00,0x01` |
| `0x01` | R_GAIN_SHADOW (Q4.12) | RW | `0x02,0x03` |
| `0x02` | G_GAIN_SHADOW | RW | `0x04,0x05` |
| `0x03` | B_GAIN_SHADOW | RW | `0x06,0x07` |
| `0x04` | R_OFFSET_SHADOW | RW | `0x08,0x09` |
| `0x05` | G_OFFSET_SHADOW | RW | `0x0A,0x0B` |
| `0x06` | B_OFFSET_SHADOW | RW | `0x0C,0x0D` |
| `0x20` | CONTROL_ACTIVE | RO | `0x40,0x41` |
| `0x21` | R_GAIN_ACTIVE | RO | `0x42,0x43` |
| `0x22` | G_GAIN_ACTIVE | RO | `0x44,0x45` |
| `0x23` | B_GAIN_ACTIVE | RO | `0x46,0x47` |
| `0x24` | R_OFFSET_ACTIVE | RO | `0x48,0x49` |
| `0x25` | G_OFFSET_ACTIVE | RO | `0x4A,0x4B` |
| `0x26` | B_OFFSET_ACTIVE | RO | `0x4C,0x4D` |
| `0x70` | ID (`0x57A1`) | RO | `0xE0,0xE1` |
| `0x71` | VERSION (`0x0113`) | RO | `0xE2,0xE3` |
| `0x72` | STATUS | RO | `0xE4,0xE5` |
| `0x7E` | COMMIT (`0xCA1B` arm / `0xC0FF` cancel) | WO | `0xFC,0xFD` |
| `0x7F` | DEFAULTS (`0xD65D`) | WO | `0xFE,0xFF` |

Host contract: **one 16-bit register per I2C transaction** (the RTL adapter
prefetches on pointer-set; multi-register bursts are not promised in v1).

`i2ctransfer` reference (bus number per board wiring):

```bash
# probe
i2ctransfer -y 1 w2@0x1e 0x03 0xe0 r2          # ID      -> 0x57 0xa1
i2ctransfer -y 1 w2@0x1e 0x03 0xe2 r2          # VERSION -> 0x01 0x13
i2ctransfer -y 1 w2@0x1e 0x03 0xe4 r2          # STATUS  -> 0x0c 0x00 (FRAC_BITS=12, idle)

# boot-restore write sequence (example gains R=0x0F15 G=0x1000 B=0x0E99)
i2ctransfer -y 1 w4@0x1e 0x03 0x02 0x0f 0x15   # R_GAIN_SHADOW
i2ctransfer -y 1 w4@0x1e 0x03 0x04 0x10 0x00   # G_GAIN_SHADOW
i2ctransfer -y 1 w4@0x1e 0x03 0x06 0x0e 0x99   # B_GAIN_SHADOW
i2ctransfer -y 1 w4@0x1e 0x03 0x00 0x00 0x01   # CONTROL_SHADOW: enable=1
i2ctransfer -y 1 w2@0x1e 0x03 0x02 r2          # readback-verify each shadow reg...
i2ctransfer -y 1 w4@0x1e 0x03 0xfc 0xca 0x1b   # COMMIT (arms; latches at vsync)
i2ctransfer -y 1 w2@0x1e 0x03 0xe4 r2          # poll STATUS until bit1 (consumed)
```

The boot-restore sequence in full (probe → wait-not-pending → write shadow →
**readback verify** → COMMIT → poll consumed with pending-until-video
tolerance) is exactly what `fpga-wp-adjust/host/wp_load.py` implements; it
only needs the i2cdev backend below.

### 1.3 The calibration file the Pi replays at boot

- Producer: the **"D65 Calibration"** disp-tester app writes a
  **wp-cal-v1 schema** profile to
  `/home/pi/system-settings/wp-cal-d65.json` (validated against
  `fpga-wp-adjust/host/schema/wp-cal-v1.schema.json`; verified loadable by
  `wp_load.py` in mock mode).
- Consumer: `wp_load.py` (or a vendored stdlib equivalent) at every boot —
  the FPGA never persists gains by design.
- Safety already built in: the loader enforces the boot-safe gain window
  `[unity/4, unity]`, validates the schema, and fails closed leaving the
  FPGA in pass-through.

## 2. Remaining SW Work List

Ordered and gated on the RTL bring-up steps of
`docs/display-integration-guideline.md` (RTL-1 = pass-through inserted,
RTL-2 = page-3 probe works, RTL-3 = live gains verified).

### Phase SW-1 — can be done NOW (no hardware dependency)

| # | Repo | Task | Size |
|---|---|---|---|
| 1.1 | br-wrapper | **Byte-address fix** in `I2CDevWpAdjust.read16/write16` of all three children (`new-white-point-profile-child.py`, `d65-calibration-child.py`, `new-white-point-match-child.py`): send `(addr << 1) & 0xFF` instead of `addr & 0xFF` (the 2-bytes-per-register page-3 mapping, §1.2). Symptom if forgotten: ID read returns wrong/zero bytes. | 1 line × 3 files (+ docstring) |
| 1.2 | fpga-wp-adjust | **`I2CDevBackend` for `host/wp_load.py`** implementing `RegisterBackend.read16/write16` over `/dev/i2c-N` with the §1.2 framing (stdlib `fcntl.ioctl(I2C_SLAVE=0x0703)` + `os.read/os.write`, same as the children). New CLI: `--backend i2cdev --i2c-dev /dev/i2c-1 --i2c-addr 0x1E --wp-page 0x03`. This is Track B4 of `docs/implementation-plan.md`. Add unit tests for the byte framing (mock fd). | small module + tests |
| 1.3 | br-wrapper | **Match child: also emit a wp-cal-v1 profile.** `new-white-point-match-child.py` currently writes only its own `disp-tester-white-point-match-v2` JSON — the boot loader cannot replay a *pair-match* result. Mirror the D65 child: write a wp-cal-v1-conformant profile (target_white = measured reference white, `name` = `pair:<peer>:measured-white`) alongside the existing output. | ~60 lines (copy `wp_cal_v1_profile()` from the D65 child) |
| 1.4 | br-wrapper | **systemd boot-restore unit** (`wp-calibration.service`): after the I2C bus is up, run the loader with `--cal /home/pi/system-settings/wp-cal-d65.json --backend i2cdev --timeout-sec 10`; treat `pending_until_video` as success (video may start later; the commit latches at the first vsync). `ConditionPathExists=` on the cal file so units without calibration boot clean. Decide packaging: buildroot package vs PiOS micropanel deployment (open question §4.1). | unit file + install hook |
| 1.5 | br-wrapper | Decide + implement the **panel-serial convention** for per-unit files (`--panel-serial` arg on the D65/match buttons; file naming e.g. `wp-cal-<serial>.json` with `wp-cal-d65.json` as the single-unit default). Needed before calibrating more than one unit. | small |

### Phase SW-2 — after RTL-2 (page-3 probe HW-verified)

| # | Repo | Task |
|---|---|---|
| 2.1 | br-wrapper | Flip the three launcher buttons from `--script-arg=simulate` to `--script-arg=i2cdev` (+ `--script-arg=--wp-page`, `--script-arg=0x03` if the placeholder default changed). One JSON edit per button; sensor + spotread become required again. |
| 2.2 | bench | Run **"White Point Profiling New"** with the i1Display Pro on the real panel; hand the profile JSON back for analysis (datapath linearity, per-LSB response vs noise floor, **measured gamma**). |
| 2.3 | br-wrapper | Set the measured gamma on the D65/match buttons (`--script-arg=--gamma`, `--script-arg=<measured>`) replacing the 2.184 legacy assumption. |

### Phase SW-3 — after RTL-3 (live gains HW-verified) / productization

| # | Repo | Task |
|---|---|---|
| 3.1 | bench | **"D65 Calibration"** on one display; verify white moves toward D65 within tolerance; confirm `wp-cal-d65.json` + session log written; reboot and confirm the systemd unit (1.4) restores the gains (STATUS consumed, active regs match the profile). |
| 3.2 | bench | **"White Point Matching New"** with the second display per `docs/pair-matching.md` (common target, luminance co-matching, pair Δu′v′ acceptance, gray-ramp checks). |
| 3.3 | br-wrapper | Button curation: set `"enabled": false` in the launcher JSON for whichever of the five white-point buttons are not kept (candidates to hide after validation: legacy "White Point Matching" — inert on pixelpipe displays per §1.1 — and "White Point Profiling New" once characterization is done). Do not delete entries; keep configs recoverable. |
| 3.4 | br-wrapper | **Legacy phase-out check**: confirm nothing else replays the *legacy* calibration at boot — the old flow's `white-point-calibration.json` kept top-level `wpx/wpy/wpz` "for simple startup replay by als-dimmer". On pixelpipe displays those writes are no-ops, but the replay should be disabled/ignored explicitly so logs stay clean and nobody debugs a ghost. |

### Phase SW-4 — optional / nice-to-have

| # | Repo | Task |
|---|---|---|
| 4.1 | space6-architecture (disptool) | wp_adjust convenience commands on the `fpganew` device (e.g. `wpgains`, `wpcommit`, `wpdefaults`, or generic page-3 `regrd/regwr`) for field debugging without Python. The C++ plumbing exists (`writeRegisterPaged/readRegisterPaged`). |
| 4.2 | br-wrapper | Factor the duplicated backend/solver code in the three children into a shared module — only if the deployment story for a second file is settled; the current per-file duplication follows the existing disp-tester convention deliberately. |
| 4.3 | fpga-wp-adjust | Wire the same i2cdev backend into a future `wp_calibrate.py` (PRD §11) if the disp-tester children are ever replaced by the framework-driven flow. |

## 3. Final Integration-Test Acceptance Checklist

1. `i2ctransfer` probes (§1.2) return ID/VERSION/STATUS on both panels.
2. All three buttons run end-to-end against hardware (`--backend i2cdev`),
   sensor required, no simulate fallback.
3. Profile JSON from real silicon analyzed: monotonic, linear (−16/−4 LSB
   ratio ≈ 4), per-LSB response above noise, gamma extracted.
4. D65 calibration converges within tolerance; luminance loss recorded.
5. Reboot restores calibration automatically (systemd unit); STATUS shows
   consumed; active gains match the JSON.
6. Power-cycle + reboot with **no calibration file** boots clean into
   pass-through (loader exits with the documented warning).
7. Corrupt/out-of-window JSON is rejected before any register write (loader
   fails closed; display stays pass-through).
8. Pair match meets the Δu′v′ pair tolerance; both units' profiles carry the
   pair linkage metadata; reboot of both units restores the matched state.
9. Legacy `0x1D` regression: brightness, LD/PC enables, ALS, OTA unaffected
   throughout.

## 4. Open Questions (need owner decisions, none block SW-1)

1. **Where does the boot-restore service ship?** Buildroot package in
   br-wrapper (`disp-tester` or a new `wp-cal` package) vs the PiOS
   micropanel deployment. The loader itself is deployment-agnostic.
2. **Panel-serial source** for per-unit calibration files: FPGA has no
   serial register; candidates are an operator-entered ID, the Pi serial,
   or a manufacturing-assigned identifier (PRD V2F discusses the options).
3. **Single profile vs per-condition profiles**: one `wp-cal-d65.json` now;
   temperature-banded profiles (PRD V2D) would extend the loader's file
   selection later — no schema change needed.
4. **i2c bus number** on the production harness (`--i2c-dev` default is
   `/dev/i2c-1`; confirm against the board wiring used by disptool).
