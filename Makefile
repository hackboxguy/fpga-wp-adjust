SIM ?= iverilog
VVP ?= vvp
YOSYS ?= yosys
PYTHON ?= python3

BUILD_DIR := build
RTL := rtl/wp_adjust.v
RTL_CDC_BRIDGE := rtl/wp_adjust_cdc_bridge.v
TB := tb/tb_wp_adjust.v
TB_CDC_BRIDGE := tb/tb_wp_adjust_cdc_bridge.v
TB_VVP := $(BUILD_DIR)/tb_wp_adjust.vvp
TB_CDC_BRIDGE_VVP := $(BUILD_DIR)/tb_wp_adjust_cdc_bridge.vvp
CAL_SCHEMA := host/schema/wp-cal-v1.schema.json
CAL_PROFILES := $(wildcard examples/calibration/*.json)

.PHONY: all test synth-check validate-json host-test clean

all: test

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(TB_VVP): $(RTL) $(TB) | $(BUILD_DIR)
	$(SIM) -g2012 -Wall -o $@ $(RTL) $(TB)

$(TB_CDC_BRIDGE_VVP): $(RTL) $(RTL_CDC_BRIDGE) $(TB_CDC_BRIDGE) | $(BUILD_DIR)
	$(SIM) -g2012 -Wall -o $@ $(RTL) $(RTL_CDC_BRIDGE) $(TB_CDC_BRIDGE)

test: $(TB_VVP) $(TB_CDC_BRIDGE_VVP)
	$(VVP) $(TB_VVP)
	$(VVP) $(TB_CDC_BRIDGE_VVP)

synth-check:
	$(YOSYS) -q -p 'read_verilog $(RTL); hierarchy -check -top wp_adjust; proc; opt; stat'
	$(YOSYS) -q -p 'read_verilog $(RTL_CDC_BRIDGE); hierarchy -check -top wp_adjust_cdc_bridge; proc; opt; stat'

validate-json:
	$(PYTHON) tools/validate_calibration_json.py --schema $(CAL_SCHEMA) $(CAL_PROFILES)

host-test:
	$(PYTHON) -m pytest host/tests

clean:
	rm -rf $(BUILD_DIR) .pytest_cache host/__pycache__ host/tests/__pycache__
