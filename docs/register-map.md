# Register Map

Logical register interface:

- 8-bit register subaddress
- 16-bit register data
- Register transport supplied by the integrating FPGA design
- `cfg_*` presented to `wp_adjust` synchronous to pixel `clk`

If the outer register transport is clocked differently from the pixel domain,
`rtl/wp_adjust_cdc_bridge.v` can bridge a simple one-transaction-at-a-time
logical bus into the synchronous `cfg_*` interface. Board-specific I2C/SPI/CPU
register framing remains outside the logical map. Its `bus_req` is accepted on
a rising edge while `bus_busy` is low.

## Addresses

| Address | Field | Access | Description |
|---:|---|---|---|
| `0x00` | `CONTROL_SHADOW` | RW | Bit 0 master enable, bit 1 offset enable |
| `0x01` | `R_GAIN_SHADOW` | RW | Red gain |
| `0x02` | `G_GAIN_SHADOW` | RW | Green gain |
| `0x03` | `B_GAIN_SHADOW` | RW | Blue gain |
| `0x04` | `R_OFFSET_SHADOW` | RW | Signed red output-code offset |
| `0x05` | `G_OFFSET_SHADOW` | RW | Signed green output-code offset |
| `0x06` | `B_OFFSET_SHADOW` | RW | Signed blue output-code offset |
| `0x20` | `CONTROL_ACTIVE` | RO | Active enable bits |
| `0x21` | `R_GAIN_ACTIVE` | RO | Active red gain |
| `0x22` | `G_GAIN_ACTIVE` | RO | Active green gain |
| `0x23` | `B_GAIN_ACTIVE` | RO | Active blue gain |
| `0x24` | `R_OFFSET_ACTIVE` | RO | Active red offset |
| `0x25` | `G_OFFSET_ACTIVE` | RO | Active green offset |
| `0x26` | `B_OFFSET_ACTIVE` | RO | Active blue offset |
| `0x70` | `ID` | RO | `16'h57A1` |
| `0x71` | `VERSION` | RO | `16'h0113` |
| `0x72` | `STATUS` | RO | Status and gain fractional-bit field |
| `0x7E` | `COMMIT` | WO | Write `16'hCA1B` to arm frame-boundary commit; write `16'hC0FF` to cancel an armed commit |
| `0x7F` | `DEFAULTS` | WO | Write `16'hD65D` to restore pass-through immediately |

## CONTROL

`CONTROL_SHADOW` and `CONTROL_ACTIVE` use the same low bits:

| Bit | Meaning |
|---:|---|
| 0 | Master enable for gain/offset datapath |
| 1 | Enable signed offsets; requires bit 0 to affect pixels |

Offset-only correction is done by enabling bit 0 with unity RGB gains and setting bit 1.

## Gain Format

Default gain format is unsigned Q4.12:

```text
unity = 1.0 = 16'h1000
0.5   = 16'h0800
1.5   = 16'h1800  (format example only; above-unity gains are outside the
                   v1 headroom-preserving calibration policy and the boot
                   loader's default safety window)
```

`STATUS[15:8]` reports `FRAC_BITS` and is the authoritative fractional-bit count for host software.

## STATUS

| Bit(s) | Meaning |
|---:|---|
| 0 | Commit pending |
| 1 | Last commit consumed on filtered `in_vsync`; sticky until next `COMMIT` or `DEFAULTS` |
| 2 | Active master enable |
| 3 | Active offset enable |
| 7:4 | Reserved, reads zero |
| 15:8 | `FRAC_BITS` |

## Commit Semantics

`COMMIT` arms an update. It does not snapshot the shadow registers immediately. Active registers latch from shadow registers at the next filtered rising edge of active-high `in_vsync` (or the filtered active edge when the RTL is built with `VSYNC_ACTIVE_HIGH=0`).

Host software must not write new shadow values while `STATUS[0]` is set.

Writing `16'hC0FF` to `COMMIT` cancels an armed commit: `STATUS[0]` and `STATUS[1]` clear, and shadow and active registers are left untouched. This is the way to abandon staged values without losing the active calibration (`DEFAULTS` resets both). A cancel that races the commit vsync edge may arrive after the update has latched; read the active registers after canceling when that matters. The cancel magic is new in revision `0x13`; on revision `0x12` hardware it is ignored.

## VERSION

`VERSION = 16'h0113`:

- bits 15:8: register-map major version, `8'h01` for scalar v1
- bits 7:0: implementation revision, `8'h13`; `0x13` adds `COMMIT` cancel
  (`16'hC0FF`) and the `VSYNC_ACTIVE_HIGH`/`GATE_BLANKING` build parameters
