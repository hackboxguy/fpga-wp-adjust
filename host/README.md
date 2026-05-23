# Host Tools

Host-side calibration and upload tools are intentionally separate from the FPGA datapath.

Host Python code targets Python 3.9 or newer.

The expected host responsibilities are:

1. Read display measurements.
2. Compute RGB gains for D65 white-point correction.
3. Store calibration JSON persistently.
4. Upload calibration at boot.
5. Respect the deferred-commit register contract.

Current and planned tools:

```text
wp_math.py        # implemented: xyY/RGB gain calculation and Q-format conversion
wp_registers.py   # implemented: logical register adapter, mock backend, dry-run backend
wp_load.py        # implemented: schema-validating dry-run/mock boot loader
wp_calibrate.py   # measurement-driven calibration loop
schema/           # calibration JSON schema
tests/            # host-side unit tests
```

The canonical v1 schema is [schema/wp-cal-v1.schema.json](schema/wp-cal-v1.schema.json). The seed profile in [../examples/calibration/12-3-nq1v1-seed.json](../examples/calibration/12-3-nq1v1-seed.json) is representative input for `wp_load.py`.

The FPGA block does not persist calibration data. A Pi or other host should load calibration values after every reboot.

Minimum upload sequence:

1. Probe `ID`, `VERSION`, and `STATUS`.
2. Confirm `STATUS[15:8] == 12` for Q4.12 v1.
3. Wait until no commit is pending.
4. Write shadow gains and control.
5. Write `COMMIT = 0xCA1B`.
6. Wait for commit consumed, or record pending-until-video if video is not yet running.

`wp_registers.py` intentionally exposes only the logical v1 register map. Board-specific I2C/SPI/CPU transport should be implemented as a backend that provides `read16(addr)` and `write16(addr, value)`.

Hardware backends should add field-debug logging around those low-level transactions. The mock and dry-run backends keep an in-memory transaction list for tests and dry-run output.

Example dry-run loader invocation:

```sh
python3 -m host.wp_load --cal ../examples/calibration/12-3-nq1v1-seed.json --dry-run
```

Use `--timeout-sec <seconds>` to poll for commit-consumed status before reporting `pending_until_video`. Missing calibration files, malformed JSON, and schema-invalid profiles return controlled non-zero exit codes and leave the FPGA in its reset/pass-through state.
