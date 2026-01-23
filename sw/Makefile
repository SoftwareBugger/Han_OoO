# sw/Makefile
# Build all C tests in this directory into .elf/.bin/.hex
#
# This Makefile now builds TWO images:
#   1) boot.hex  : a tiny Boot ROM at 0x0000_0000 (boot.S linked with boot.ld)
#   2) <test>.hex: the application image linked to run from 0x0000_2000 (app.ld + crt0.S)
#
# Typical flow:
#   make                 # builds boot.hex + all app .hex
#   make t10_hello_soc   # builds boot.hex + build/t10_hello_soc.hex
#   make golden          # generates golden traces (recommended: update hex2trace to include boot)
#
# NOTE: Your testbench should load:
#   - build/boot.hex at address 0x0000_0000
#   - build/<test>.hex  at address 0x0000_2000 (word offset 0x2000/4 = 2048)

RISCV_PREFIX ?= riscv64-unknown-elf-
CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump
AR      := $(RISCV_PREFIX)ar

# Fail early if toolchain isn't in PATH
TOOL_OK := $(shell command -v $(CC) >/dev/null 2>&1; echo $$?)
ifeq ($(TOOL_OK),1)
$(error $(CC) not found in PATH. On Athena, ensure Vitis toolchain is loaded.)
endif

# Build dirs
BUILD_DIR ?= build

ELF_DIR := $(BUILD_DIR)
BIN_DIR := $(BUILD_DIR)
HEX_DIR := $(BUILD_DIR)

# Python tools
PY        ?= python3
HEXIFY    ?= hexify.py
HEX2TRACE ?= hex2trace.py

# ISA/ABI (pick what your core supports)
ARCH ?= rv32i      # set to rv32im if you implemented MUL/DIV
ABI  ?= ilp32

# Optimization level
O ?= 1

# Linker / startup
# App is linked to run from 0x0000_2000
APP_LINKER_SCRIPT ?= app.ld
CRT0              ?= crt0.S

# Boot ROM (linked to 0x0000_0000)
BOOT_LINKER_SCRIPT ?= boot.ld
BOOT_S             ?= boot.S

# Backward-compat: if you still pass LINKER_SCRIPT, treat it as APP linker.
ifneq ($(origin LINKER_SCRIPT), undefined)
APP_LINKER_SCRIPT := $(LINKER_SCRIPT)
endif

# Detect tests: all .c files in this directory excluding "support" files
EXCLUDE_C := hex2trace.c hexify.c
C_SRCS_ALL := $(wildcard *.c)
C_SRCS := $(filter-out $(EXCLUDE_C),$(C_SRCS_ALL))
TESTS := $(sort $(basename $(C_SRCS)))

# Common include paths
INCLUDES ?= -I.

# Common flags
WARN   := -Wall -Wextra -Wno-unused-parameter
COMMON := -ffreestanding -fno-builtin -fno-plt -fdata-sections -ffunction-sections

CFLAGS  ?=
CFLAGS  += $(WARN) $(COMMON) $(INCLUDES)
CFLAGS  += -O$(O) -g
CFLAGS  += -march=$(ARCH) -mabi=$(ABI) -mcmodel=medany
CFLAGS  += -mno-relax

# App link flags
APP_LDFLAGS ?=
APP_LDFLAGS += -nostdlib
APP_LDFLAGS += -Wl,--gc-sections
APP_LDFLAGS += -Wl,--no-relax
APP_LDFLAGS += -T $(APP_LINKER_SCRIPT)

# Boot link flags
BOOT_LDFLAGS ?=
BOOT_LDFLAGS += -nostdlib
BOOT_LDFLAGS += -Wl,--gc-sections
BOOT_LDFLAGS += -Wl,--no-relax
BOOT_LDFLAGS += -T $(BOOT_LINKER_SCRIPT)

# You can add libs here if needed (normally empty for bare metal)
LDLIBS ?=

.SECONDARY:
.PRECIOUS: $(BUILD_DIR)/%.elf $(BUILD_DIR)/%.bin

# ------------------------------------------------------------------------------
.PHONY: all list clean toolchain golden golden-clean boot

# Default: build boot + all app hex
all: boot $(TESTS:%=$(HEX_DIR)/%.hex)

list:
	@echo "Detected tests:"
	@for t in $(TESTS); do echo "  $$t"; done

toolchain:
	@echo "CC      = $(CC)"
	@echo "OBJCOPY = $(OBJCOPY)"
	@echo "OBJDUMP = $(OBJDUMP)"
	@$(CC) --version | head -n 2

# Build a named test: `make t08_sort_search`
$(TESTS): %: boot $(HEX_DIR)/%.hex
	@true

# Ensure build dir exists
$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

# ------------------------------------------------------------------------------
# Boot ROM build
boot: $(HEX_DIR)/boot.hex

# boot.S is required for the boot target. If you don't have it yet, create it.
# Minimal boot.S (RV32I):
#   .section .text.boot
#   .global _boot_start
# _boot_start:
#   li t0, 0x00002000
#   jr t0
$(BUILD_DIR)/boot.o: $(BOOT_S) | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(ELF_DIR)/boot.elf: $(BUILD_DIR)/boot.o | $(BUILD_DIR)
	$(CC) $(CFLAGS) $< -o $@ $(BOOT_LDFLAGS) $(LDLIBS) -lgcc

$(BIN_DIR)/boot.bin: $(ELF_DIR)/boot.elf | $(BUILD_DIR)
	$(OBJCOPY) -O binary $< $@

$(HEX_DIR)/boot.hex: $(BIN_DIR)/boot.bin $(HEXIFY) | $(BUILD_DIR)
	$(PY) $(HEXIFY) $< $@ --strip-trailing-zeros --selfcheck

# ------------------------------------------------------------------------------
# App build (each .c becomes a standalone program linked at 0x00002000)
COMMON_OBJS :=

# Startup object (optional; only used if CRT0 exists)
CRT0_OBJ :=
ifneq ("$(wildcard $(CRT0))","")
CRT0_OBJ := $(BUILD_DIR)/$(basename $(CRT0)).o
endif

# Compile assembly
$(BUILD_DIR)/%.o: %.S | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/%.o: %.s | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

# Compile C
$(BUILD_DIR)/%.o: %.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

# Compile CRT0 if present
# (Handled by the generic %.o: %.S rule above)

# Link app
$(ELF_DIR)/%.elf: $(BUILD_DIR)/%.o $(CRT0_OBJ) $(COMMON_OBJS) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(CRT0_OBJ) $(COMMON_OBJS) $< -o $@ $(APP_LDFLAGS) $(LDLIBS) -lgcc

# ELF -> BIN
$(BIN_DIR)/%.bin: $(ELF_DIR)/%.elf | $(BUILD_DIR)
	$(OBJCOPY) -O binary $< $@

# BIN -> HEX
$(HEX_DIR)/%.hex: $(BIN_DIR)/%.bin $(HEXIFY) | $(BUILD_DIR)
	$(PY) $(HEXIFY) $< $@ --strip-trailing-zeros --selfcheck

# ------------------------------------------------------------------------------
# Golden trace generation
#
# Recommended: update hex2trace.py to accept:
#   --boot build/boot.hex
# so the trace includes the boot jump from 0x0 -> 0x2000.
#
# This Makefile will try to call it that way; if your hex2trace doesn't support
# --boot yet, either add support or change GOLDEN_CMD below.
GOLDEN_CMD ?= $(PY) $(HEX2TRACE) --boot "$(HEX_DIR)/boot.hex" "$(HEX_DIR)/*.hex"

golden: all
	@echo "Generating golden traces..."
	@$(GOLDEN_CMD)

golden-clean:
	@rm -rf golden_traces

clean:
	@rm -rf $(BUILD_DIR)
