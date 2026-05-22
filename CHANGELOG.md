# Changelog

## Unreleased

- Added host-side calibration math helpers and unit tests for Q-format conversion, seed reproduction, xyY/XYZ conversion, gain normalization, and safety limits.
- Added host-side logical register adapter with mock and dry-run backends.
- Added `make host-test` and CI coverage for host unit tests.
- Regenerated the example 12.3-nq1v1 seed from the committed math pipeline.

## 0.1.0 - 2026-05-22

- Added scalar v1 `wp_adjust` RTL with RGB gain, optional signed offsets, saturating clamp, and frame-boundary commit.
- Added directed Verilog testbench and Makefile targets for simulation and synthesis sanity checks.
- Added integration guide, register map, PRD, example FPGA insertion wrapper, and v1 calibration JSON schema.
- Register-map version reported by RTL: `0x0112`.
