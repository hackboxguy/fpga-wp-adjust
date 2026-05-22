# Register Map

Logical register interface:

- 8-bit register subaddress
- 16-bit register data
- Register transport supplied by the integrating FPGA design
- `cfg_*` presented to `wp_adjust` synchronous to pixel `clk`

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
| `0x71` | `VERSION` | RO | `16'h0112` |
| `0x72` | `STATUS` | RO | Status and gain fractional-bit field |
| `0x7E` | `COMMIT` | WO | Write `16'hCA1B` to arm frame-boundary commit |
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
1.5   = 16'h1800
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

`COMMIT` arms an update. It does not snapshot the shadow registers immediately. Active registers latch from shadow registers at the next filtered rising edge of active-high `in_vsync`.

Host software must not write new shadow values while `STATUS[0]` is set.

## VERSION

`VERSION = 16'h0112`:

- bits 15:8: register-map major version, `8'h01` for scalar v1
- bits 7:0: implementation revision, `8'h12`
