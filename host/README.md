# Host Tools

Host-side calibration and upload tools are intentionally separate from the FPGA datapath.

The expected host responsibilities are:

1. Read display measurements.
2. Compute RGB gains for D65 white-point correction.
3. Store calibration JSON persistently.
4. Upload calibration at boot.
5. Respect the deferred-commit register contract.

Current and planned tools:

```text
wp_math.py        # implemented: xyY/RGB gain calculation and Q-format conversion
wp_registers.py   # board-specific register transport adapter
wp_calibrate.py   # measurement-driven calibration loop
wp_load.py        # boot-time calibration upload
schema/           # calibration JSON schema
tests/            # host-side unit tests
```

The canonical v1 schema is [schema/wp-cal-v1.schema.json](schema/wp-cal-v1.schema.json). The seed profile in [../examples/calibration/12-3-nq1v1-seed.json](../examples/calibration/12-3-nq1v1-seed.json) is representative input for the planned `wp_load.py` tool.

The FPGA block does not persist calibration data. A Pi or other host should load calibration values after every reboot.

Minimum upload sequence:

1. Probe `ID`, `VERSION`, and `STATUS`.
2. Confirm `STATUS[15:8] == 12` for Q4.12 v1.
3. Wait until no commit is pending.
4. Write shadow gains and control.
5. Write `COMMIT = 0xCA1B`.
6. Wait for commit consumed, or record pending-until-video if video is not yet running.
