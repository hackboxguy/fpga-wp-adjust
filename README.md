# fpga-wp-adjust

A small FPGA white-point trim block for display pipelines. It applies per-channel RGB gain and optional signed offsets after pixel compensation and before LVDS/FPD-Link transmit. It is designed for host-driven calibration upload with frame-boundary commit.

Typical placement:

```text
pixel-compensation -> wp_adjust -> lvds-tx
```

The FPGA block only performs real-time streaming pixel math. Calibration, persistence, measurement, and boot-time upload are expected to live on the host side, such as a Raspberry Pi.

## Repository Layout

```text
rtl/
  wp_adjust.v              # synthesizable white-point adjustment block
tb/
  tb_wp_adjust.v           # self-checking directed Verilog testbench
docs/
  integration-guide.md     # FPGA integration contract and bring-up notes
  register-map.md          # logical register interface
  wp-adjust-prd.md         # project PRD and future extension roadmap
host/
  README.md                # planned Pi/host tooling boundary
  schema/                  # calibration JSON schema
examples/
  fpga/wp_adjust_insert.v  # example pipeline insertion wrapper
  calibration/*.json       # example calibration seed data
Makefile                   # simulation and synthesis sanity targets
CHANGELOG.md               # release notes and RTL register-map version
```

## Quick Start

Run the committed RTL testbench:

```sh
make test
```

Run a synthesis/elaboration sanity check:

```sh
make synth-check
```

Validate calibration example JSON files against the v1 schema:

```sh
make validate-json
```

Run host-side unit tests:

```sh
make host-test
```

These targets assume `iverilog`, `vvp`, `yosys`, `python3`, and the Python `jsonschema` and `pytest` packages are available on `PATH`.

## FPGA Integration

Instantiate `rtl/wp_adjust.v` between the existing pixel-compensation output and the LVDS transmitter input:

```verilog
wp_adjust #(
    .PIXEL_BITS(10),
    .FRAC_BITS(12)
) u_wp_adjust (
    .clk(pixel_clk),
    .rst_n(rst_n),

    .in_r(pixel_comp_r),
    .in_g(pixel_comp_g),
    .in_b(pixel_comp_b),
    .in_de(pixel_comp_de),
    .in_hsync(pixel_comp_hsync),
    .in_vsync(pixel_comp_vsync),

    .out_r(lvds_r),
    .out_g(lvds_g),
    .out_b(lvds_b),
    .out_de(lvds_de),
    .out_hsync(lvds_hsync),
    .out_vsync(lvds_vsync),

    .cfg_wr_en(wp_cfg_wr_en),
    .cfg_addr(wp_cfg_addr),
    .cfg_wdata(wp_cfg_wdata),
    .cfg_rdata(wp_cfg_rdata)
);
```

Important integration points:

- `cfg_*` must be synchronous to `clk`. If the control bus is I2C/SPI/CPU-clocked, add a CDC-safe register bridge outside this block.
- `in_vsync` is expected to be active-high and synchronous to `clk`.
- The pixel path latency is 2 clock cycles for RGB and sync/control signals.
- `COMMIT` updates active registers on the next filtered `in_vsync` rising edge.
- `DEFAULTS` restores pass-through immediately.

See [docs/integration-guide.md](docs/integration-guide.md) for the full contract.

## Calibration Model

V1 is intentionally simple:

- Host measures display white.
- Host computes RGB gains, preferably reducing stronger channels rather than boosting weaker channels.
- Host writes shadow registers over the board's register transport.
- Host writes `COMMIT = 16'hCA1B`.
- FPGA latches the update at a frame boundary.

The current default gain format is unsigned Q4.12, with unity gain equal to `0x1000`.

The canonical calibration schema is [host/schema/wp-cal-v1.schema.json](host/schema/wp-cal-v1.schema.json). The example seed profile in [examples/calibration/12-3-nq1v1-seed.json](examples/calibration/12-3-nq1v1-seed.json) follows that schema.

## Original System Context

This repo does not vendor the original display measurement framework or panel report-card artifacts used to derive the example seed values. Those live in the integrating system. The RTL, register map, testbench, schema, and example profile are self-contained.

## License

MIT
