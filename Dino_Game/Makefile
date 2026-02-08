# sw/Makefile
# Build all C tests in this directory into .elf/.bin/.hex
#
# This Makefile builds:
#   1) <test>.hex      : Application image (ELF linked at 0x0000_0000)
#   2) imem_<test>.hex : IMEM image (app only, no boot patching)
#
# Typical flow:
#   make                     # builds imem_<test>.hex for all tests
#   make imem_t10_hello_soc   # builds imem image for one test
#
# Your testbench/BRAM init should load:
#   - build/imem_<test>.hex at address 0x0000_0000
# CPU resets at PC=0 -> app crt0/main

RISCV_PREFIX ?= riscv64-unknown-elf-
CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump
AR      := $(RISCV_PREFIX)ar

# Fail early if toolchain isn't in PATH
TOOL_OK := $(shell command -v $(CC) >/dev/null 2>&1; echo $$?)
ifeq ($(TOOL_OK),1)
$(error $(CC) not found in PATH. Ensure your RISC-V toolchain is in PATH.)
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

# Address map (must match app.ld IMEM ORIGIN)
APP_BASE ?= 0x00000000

# Linker / startup
APP_LINKER_SCRIPT ?= app.ld
CRT0              ?= crt0.S

BOOT_LINKER_SCRIPT ?= boot.ld
BOOT_S             ?= boot.S

# Backward-compat: if you still pass LINKER_SCRIPT, treat it as APP linker.
ifneq ($(origin LINKER_SCRIPT), undefined)
APP_LINKER_SCRIPT := $(LINKER_SCRIPT)
endif

# Single target only: main.c
TESTS := main

# Compile all other C sources as common objects (linked into main)
EXCLUDE_C := hex2trace.c hexify.c main.c
C_SRCS_ALL := $(wildcard *.c)
C_SRCS := $(filter-out $(EXCLUDE_C),$(C_SRCS_ALL))

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
# Very important for bring-up: disable GP-relative small-data to avoid "gp garbage" loads
CFLAGS  += -msmall-data-limit=0

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

.PHONY: all list clean toolchain golden golden-clean boot imem imem-all

# Default: build imem images for all tests
all: imem-all

list:
	@echo "Detected tests:"
	@for t in $(TESTS); do echo "  $$t"; done

toolchain:
	@echo "CC      = $(CC)"
	@echo "OBJCOPY = $(OBJCOPY)"
	@echo "OBJDUMP = $(OBJDUMP)"
	@$(CC) --version | head -n 2

# Build a named test: `make t08_sort_search`
$(TESTS): %: imem_%
	@true

# Ensure build dir exists
$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

# ------------------------------------------------------------------------------
# App build (link main.c with common objects)
COMMON_OBJS := $(C_SRCS:%.c=$(BUILD_DIR)/%.o)

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

# Link app
$(ELF_DIR)/%.elf: $(BUILD_DIR)/%.o $(CRT0_OBJ) $(COMMON_OBJS) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(CRT0_OBJ) $(COMMON_OBJS) $< -o $@ $(APP_LDFLAGS) $(LDLIBS) -lgcc

# ELF -> BIN
$(BIN_DIR)/%.bin: $(ELF_DIR)/%.elf | $(BUILD_DIR)
	$(OBJCOPY) -O binary $< $@

# BIN -> HEX (flat blob; load at 0x0000_0000)
$(HEX_DIR)/%.hex: $(BIN_DIR)/%.bin $(HEXIFY) | $(BUILD_DIR)
	$(PY) $(HEXIFY) $< $@ --strip-trailing-zeros --selfcheck

# ------------------------------------------------------------------------------
# IMEM image (app only, no boot patching)
#
# Produces:
#   build/imem_<test>.bin
#   build/imem_<test>.hex
#
# Load imem_<test>.hex at base 0 in your testbench/BRAM init.
# ------------------------------------------------------------------------------
imem:
	@if [ -z "$(TEST)" ]; then \
	  echo "ERROR: set TEST=<name> (e.g. make imem TEST=t10_hello_soc) or use make imem_<name>"; \
	  exit 1; \
	fi
	@$(MAKE) imem_$(TEST)

imem-all: $(TESTS:%=imem_%)

imem_%: $(BIN_DIR)/%.bin $(HEXIFY) | $(BUILD_DIR)
	@echo "[imem] app only at $(APP_BASE)"
	@$(PY) -c "import pathlib; \
app=pathlib.Path('$(BIN_DIR)/$*.bin').read_bytes(); \
out=pathlib.Path('$(BIN_DIR)/imem_$*.bin'); \
out.write_bytes(app); \
print(f'[imem] app={len(app)} -> {out}')"
	@$(PY) $(HEXIFY) "$(BIN_DIR)/imem_$*.bin" "$(HEX_DIR)/imem_$*.hex" --strip-trailing-zeros --selfcheck
	@echo "[imem] wrote $(HEX_DIR)/imem_$*.hex"

# ------------------------------------------------------------------------------
# Golden trace generation
#
# With combined IMEM images, just trace imem_*.hex (already includes boot jump bytes).
# ------------------------------------------------------------------------------
GOLDEN_CMD ?= $(PY) $(HEX2TRACE) "$(HEX_DIR)/imem_*.hex"

golden: all
	@echo "Generating golden traces..."
	@$(GOLDEN_CMD)

golden-clean:
	@rm -rf golden_traces

clean:
	@rm -rf $(BUILD_DIR)
