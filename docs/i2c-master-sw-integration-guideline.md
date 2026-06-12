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
  is added to the `0x1D` map.
- **Recorded option (not recommended): a legacy-compat shim on `0x1D`.**
  The `0x37/0x39/0x3B` addresses *are* free on the Xilinx displays and the
  `ctrl_regfile` window could be widened to host them, shimming the legacy
  semantics onto wp_adjust gains (legacy 0..256 scale × 16 = Q4.12, i.e.
  `gain = value << 4`; 256 → `0x1000` unity exactly). That would let the
  unmodified legacy matching app drive the new datapath during a transition.
  It is throwaway work against a slave being phased out, the legacy
  `wpx/wpy/wpz` ↔ RGB channel mapping would need re-deriving (on the old
  panel they behaved approximately as B/G/R gains), and the legacy
  immediate-write semantics bypass the shadow/COMMIT atomicity. Implement
  only if the old app must keep working during the migration window;
  otherwise skip.

### 1.2 The boot-writable register mapping IS decided: `0x1E` page `0x03`

Page choice cross-checked against
`pixelpipe-fpga/docs/i2c-register-map-new.md`: page `0x00` is the native
`0x00–0x36` map, page `0x01` is OTA control/status + the ALS snapshot block,
page `0x02` is the OTA 256-byte data window — **page `0x03` is the first
unallocated page** (and `ipcreg_core.v` returns `0xFF` for page ≥ 3 today).
One framing rule from that doc matters here: a **single-byte read pointer
defaults to page `0x00`**, so every page-3 access — reads included — must
send the explicit two-byte `{page, reg}` pointer (`w2@0x1E 0x03 <off>`),
exactly like the existing page-1 ALS reads. The host backends in this flow
already frame it that way.

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

### 1.3 The calibration file the Pi replays at boot — owner: **als-dimmer**

The boot-replay role already exists: the **als-dimmer daemon**
(`tmp-folder/als-dimmer/`, the display brightness/settings controller) loads
white-point calibration from `/home/pi/system-settings/` at startup and
writes it to the FPGA. Today's implementation
(`src/main.cpp` `restoreWhitePointCalibration()`, called once at daemon
start; `I2CDimmerOutput::applyWhitePoint/writeWhitePointRegister`):

- reads `/home/pi/system-settings/white-point-calibration.json`
  (config-overridable: `white_point_calibration.{enabled,file_path}`),
- parses top-level `wpx/wpy/wpz` (0..256, legacy scale),
- writes them with the **legacy `0x1D` 4-byte-prefix framing** to
  `0x37/0x39/0x3B` — which on pixelpipe-fpga displays is a **silent no-op**
  (registers don't exist, §1.1).

The wp_adjust boot restore therefore extends als-dimmer rather than adding a
parallel systemd unit (work item 1.4):

- Producer: the **"D65 Calibration"** disp-tester app writes a
  **wp-cal-v1 schema** profile to
  `/home/pi/system-settings/wp-cal-d65.json` (validated against
  `fpga-wp-adjust/host/schema/wp-cal-v1.schema.json`); the pair-match app
  gains the same output (work item 1.3).
- Consumer: als-dimmer at every boot — the FPGA never persists gains by
  design. The reference sequence/semantics to port to C++ are
  `fpga-wp-adjust/host/wp_load.py` (probe → window check → shadow writes →
  readback verify → COMMIT → poll consumed, pending-until-video tolerated)
  with the §1.2 byte framing.
- Safety to carry over: boot-safe gain window `[unity/4, unity]`, fail
  closed (skip + warn, display stays pass-through) on missing/invalid file
  or failed probe.

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
| 1.4 | als-dimmer | **Extend the daemon's boot replay for wp_adjust** (§1.3). Add a config block (e.g. `white_point_calibration.wp_adjust = {enabled, file_path: /home/pi/system-settings/wp-cal-d65.json, i2c_address: 0x1E, page: 0x03}`) and a C++ restore path mirroring `wp_load.py`: probe ID/VERSION/FRAC_BITS on `0x1E` page 3 (skip quietly if the probe fails — old display or RTL not present), enforce the boot-safe gain window, write shadow gains/offsets/control with the §1.2 framing, readback-verify, COMMIT, poll STATUS with pending-until-video tolerated. Keep the legacy `wpx/wpy/wpz` replay path as-is during the transition (harmless no-op on new displays); the `0x57A1` ID probe is the natural dispatcher between the two paths. Note the daemon's existing fd is ioctl'd to the dimmer address — the wp_adjust path needs its own `I2C_SLAVE` ioctl/fd for `0x1E`. | C++, ~200 lines + config |
| 1.5 | br-wrapper | **Panel-serial file convention** for per-unit calibrations: interim single default file now; serial-keyed `wp-cal-<serial>.json` once the factory serial-number feature exists — full plan in §4. | small |

### Phase SW-2 — after RTL-2 (page-3 probe HW-verified)

| # | Repo | Task |
|---|---|---|
| 2.1 | br-wrapper | Flip the three launcher buttons from `--script-arg=simulate` to `--script-arg=i2cdev` (+ `--script-arg=--wp-page`, `--script-arg=0x03` if the placeholder default changed). One JSON edit per button; sensor + spotread become required again. |
| 2.2 | bench | Run **"White Point Profiling New"** with the i1Display Pro on the real panel; hand the profile JSON back for analysis (datapath linearity, per-LSB response vs noise floor, **measured gamma**). |
| 2.3 | br-wrapper | Set the measured gamma on the D65/match buttons (`--script-arg=--gamma`, `--script-arg=<measured>`) replacing the 2.184 legacy assumption. |

### Phase SW-3 — after RTL-3 (live gains HW-verified) / productization

| # | Repo | Task |
|---|---|---|
| 3.1 | bench | **"D65 Calibration"** on one display; verify white moves toward D65 within tolerance; confirm `wp-cal-d65.json` + session log written; reboot and confirm the als-dimmer replay (1.4) restores the gains (STATUS consumed, active regs match the profile, daemon log shows the wp_adjust path taken). |
| 3.2 | bench | **"White Point Matching New"** with the second display per `docs/pair-matching.md` (common target, luminance co-matching, pair Δu′v′ acceptance, gray-ramp checks). |
| 3.3 | br-wrapper | Button curation: set `"enabled": false` in the launcher JSON for whichever of the five white-point buttons are not kept (candidates to hide after validation: legacy "White Point Matching" — inert on pixelpipe displays per §1.1 — and "White Point Profiling New" once characterization is done). Do not delete entries; keep configs recoverable. |
| 3.4 | als-dimmer | **Legacy replay retirement**: once all deployed displays are pixelpipe-based and `0x1D` is retired, remove `restoreWhitePointCalibration()`'s legacy `wpx/wpy/wpz` path (`main.cpp` startup + `I2CDimmerOutput::applyWhitePoint`) and the legacy `white-point-calibration.json` handling, leaving only the wp_adjust path from 1.4. Until then the legacy path stays (no-op on new displays) with the ID probe dispatching. |

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
5. Reboot restores calibration automatically (als-dimmer); STATUS shows
   consumed; active gains match the JSON.
6. Power-cycle + reboot with **no calibration file** boots clean into
   pass-through (loader exits with the documented warning).
7. Corrupt/out-of-window JSON is rejected before any register write (loader
   fails closed; display stays pass-through).
8. Pair match meets the Δu′v′ pair tolerance; both units' profiles carry the
   pair linkage metadata; reboot of both units restores the matched state.
9. Legacy `0x1D` regression: brightness, LD/PC enables, ALS, OTA unaffected
   throughout.

## 4. Suggestion: Display-Serial-Linked Calibration (factory process hook)

The plan of record: when the factory process later gains a **display
serial-number saving feature**, the boot loader uses that serial to select
the calibration file — so calibration follows the *display*, not the Pi
image.

1. **Interim (now, until the factory feature exists):** a single default
   file per unit (`/home/pi/system-settings/wp-cal-d65.json`). The
   wp-cal-v1 schema already carries `panel_serial`; the calibration apps
   write `unknown-or-real-serial` until a real source exists. Nothing
   blocks on the serial feature.
2. **Once the factory process stores the serial on the display:** the boot
   flow becomes `read display serial → load
   /home/pi/system-settings/wp-cal-<serial>.json → fall back to the default
   file (or pass-through) if absent`. The loader change is a few lines of
   file selection; the calibration apps gain `--panel-serial $(read-serial)`
   so the JSON `panel_serial` field matches the unit. A swapped display
   then automatically stops matching a stale calibration.
3. **Recommended place to store the serial: the FPGA SPI config flash**, in
   a small reserved factory-data sector. The read path already exists end
   to end — the OTA-over-I2C machinery (`0x1E` pages 1/2, `ota-read`) can
   read any flash offset from the Pi with **no new RTL**; the factory write
   is one `ota-flash`-style program of the reserved sector. Coordinate the
   offset with `pixelpipe-fpga/docs/ota-over-i2c.md`'s flash layout (GOLDEN
   at `0x0`, UPDATE at `0x400000`, scratch slots above; e.g. the last 4 KB
   sector of the 16 MB part). Alternatives: a dedicated RO I2C register
   loaded from flash at boot (needs RTL), or panel-side EDID/TDDI storage
   (transport unknown).
4. **Future option, explicitly not v1:** the calibration JSON itself could
   live in the same factory-data flash region so calibration physically
   travels with the display. Keep the v1 principle (Pi owns persistence,
   FPGA stores nothing) until multi-unit logistics actually demand it; the
   serial-keyed file scheme above already covers display swaps.

This section matches PRD §16.6 (V2F golden-vs-per-panel calibration) and
implementation-plan B4; when the factory feature lands, work items: factory
write step, `read-serial` helper (disptool or script over the OTA read
path), loader file-selection change, calibration-app `--panel-serial`
wiring.

## 5. Open Questions (need owner decisions, none block SW-1)

1. ~~Where does the boot-restore service ship?~~ **Resolved**: the
   boot-restore owner is the existing **als-dimmer daemon** (§1.3 / work
   item 1.4); no new service. `wp_load.py` remains the reference
   implementation and the bench/manual tool.
2. **Single profile vs per-condition profiles**: one calibration file per
   unit now; temperature-banded profiles (PRD V2D) would extend the
   loader's file selection later — no schema change needed.
3. **i2c bus number** on the production harness (`--i2c-dev` default is
   `/dev/i2c-1`; confirm against the board wiring used by disptool).
4. **Reserved flash offset for the factory-data sector** (§4.3) — needs
   sign-off against the OTA flash layout before the factory feature is
   specified.
