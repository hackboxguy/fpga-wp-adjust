SIM ?= iverilog
VVP ?= vvp
YOSYS ?= yosys
PYTHON ?= python3

BUILD_DIR := build
RTL := rtl/wp_adjust.v
TB := tb/tb_wp_adjust.v
TB_VVP := $(BUILD_DIR)/tb_wp_adjust.vvp
CAL_SCHEMA := host/schema/wp-cal-v1.schema.json
CAL_PROFILES := $(wildcard examples/calibration/*.json)

.PHONY: all test synth-check validate-json host-test clean

all: test

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(TB_VVP): $(RTL) $(TB) | $(BUILD_DIR)
	$(SIM) -g2012 -Wall -o $@ $(RTL) $(TB)

test: $(TB_VVP)
	$(VVP) $(TB_VVP)

synth-check:
	$(YOSYS) -q -p 'read_verilog $(RTL); hierarchy -check -top wp_adjust; proc; opt; stat'

validate-json:
	$(PYTHON) tools/validate_calibration_json.py --schema $(CAL_SCHEMA) $(CAL_PROFILES)

host-test:
	$(PYTHON) -m pytest host/tests

clean:
	rm -rf $(BUILD_DIR) .pytest_cache host/__pycache__ host/tests/__pycache__
