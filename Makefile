SIM ?= iverilog
VVP ?= vvp
YOSYS ?= yosys
PYTHON ?= python3

BUILD_DIR := build
RTL := rtl/wp_adjust.v
RTL_CDC_BRIDGE := rtl/wp_adjust_cdc_bridge.v
TB := tb/tb_wp_adjust.v
TB_CDC_BRIDGE := tb/tb_wp_adjust_cdc_bridge.v
TB_PARAMS := tb/tb_wp_adjust_params.v
TB_OPTIONS := tb/tb_wp_adjust_options.v
TB_VVP := $(BUILD_DIR)/tb_wp_adjust.vvp
TB_CDC_BRIDGE_VVP := $(BUILD_DIR)/tb_wp_adjust_cdc_bridge.vvp
TB_OPTIONS_VVP := $(BUILD_DIR)/tb_wp_adjust_options.vvp
TB_PARAMS_DEFAULT_VVP := $(BUILD_DIR)/tb_wp_adjust_params_10_12.vvp
TB_PARAMS_8_10_VVP := $(BUILD_DIR)/tb_wp_adjust_params_8_10.vvp
TB_PARAMS_12_14_VVP := $(BUILD_DIR)/tb_wp_adjust_params_12_14.vvp
CAL_SCHEMA := host/schema/wp-cal-v1.schema.json
CAL_PROFILES := $(wildcard examples/calibration/*.json)

.PHONY: all test synth-check guard-check validate-json host-test clean

all: test

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(TB_VVP): $(RTL) $(TB) | $(BUILD_DIR)
	$(SIM) -g2012 -Wall -o $@ $(RTL) $(TB)

$(TB_CDC_BRIDGE_VVP): $(RTL) $(RTL_CDC_BRIDGE) $(TB_CDC_BRIDGE) | $(BUILD_DIR)
	$(SIM) -g2012 -Wall -o $@ $(RTL) $(RTL_CDC_BRIDGE) $(TB_CDC_BRIDGE)

$(TB_OPTIONS_VVP): $(RTL) $(TB_OPTIONS) | $(BUILD_DIR)
	$(SIM) -g2012 -Wall -o $@ $(RTL) $(TB_OPTIONS)

$(TB_PARAMS_DEFAULT_VVP): $(RTL) $(TB_PARAMS) | $(BUILD_DIR)
	$(SIM) -g2012 -Wall -o $@ $(RTL) $(TB_PARAMS)

$(TB_PARAMS_8_10_VVP): $(RTL) $(TB_PARAMS) | $(BUILD_DIR)
	$(SIM) -g2012 -Wall -DWP_PIXEL_BITS=8 -DWP_FRAC_BITS=10 -o $@ $(RTL) $(TB_PARAMS)

$(TB_PARAMS_12_14_VVP): $(RTL) $(TB_PARAMS) | $(BUILD_DIR)
	$(SIM) -g2012 -Wall -DWP_PIXEL_BITS=12 -DWP_FRAC_BITS=14 -o $@ $(RTL) $(TB_PARAMS)

test: $(TB_VVP) $(TB_CDC_BRIDGE_VVP) $(TB_OPTIONS_VVP) \
      $(TB_PARAMS_DEFAULT_VVP) $(TB_PARAMS_8_10_VVP) $(TB_PARAMS_12_14_VVP)
	$(VVP) $(TB_VVP)
	$(VVP) $(TB_CDC_BRIDGE_VVP)
	$(VVP) $(TB_CDC_BRIDGE_VVP) +bus_half=3
	$(VVP) $(TB_CDC_BRIDGE_VVP) +bus_half=10
	$(VVP) $(TB_OPTIONS_VVP)
	$(VVP) $(TB_PARAMS_DEFAULT_VVP)
	$(VVP) $(TB_PARAMS_8_10_VVP)
	$(VVP) $(TB_PARAMS_12_14_VVP)

synth-check: guard-check
	$(YOSYS) -q -p 'read_verilog $(RTL); hierarchy -check -top wp_adjust; proc; opt; stat'
	$(YOSYS) -q -p 'read_verilog $(RTL_CDC_BRIDGE); hierarchy -check -top wp_adjust_cdc_bridge; proc; opt; stat'

# Out-of-range parameters must FAIL elaboration (see the generate guards in
# rtl/wp_adjust.v). Each command is expected to error out.
guard-check:
	! $(YOSYS) -q -p 'read_verilog $(RTL); chparam -set FRAC_BITS 1 wp_adjust; hierarchy -check -top wp_adjust' 2>/dev/null
	! $(YOSYS) -q -p 'read_verilog $(RTL); chparam -set FRAC_BITS 16 wp_adjust; hierarchy -check -top wp_adjust' 2>/dev/null
	! $(YOSYS) -q -p 'read_verilog $(RTL); chparam -set PIXEL_BITS 16 wp_adjust; hierarchy -check -top wp_adjust' 2>/dev/null
	! $(YOSYS) -q -p 'read_verilog $(RTL); chparam -set PIXEL_BITS 3 wp_adjust; hierarchy -check -top wp_adjust' 2>/dev/null

validate-json:
	$(PYTHON) tools/validate_calibration_json.py --schema $(CAL_SCHEMA) $(CAL_PROFILES)

host-test:
	$(PYTHON) -m pytest host/tests

clean:
	rm -rf $(BUILD_DIR) .pytest_cache host/__pycache__ host/tests/__pycache__
