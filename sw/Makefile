# sw/Makefile
# Build all C tests in this directory into .elf/.bin/.hex
#
# This Makefile builds:
#   1) boot.hex        : Boot ROM at 0x0000_0000 (boot.S linked with boot.ld)
#   2) <test>.hex      : Application image (ELF linked to 0x0000_2000, but hex is a flat blob)
#   3) imem_<test>.hex : COMBINED IMEM image (boot@0 + padding + app@0x2000)  <-- recommended
#
# Typical flow (recommended):
#   make                     # builds boot + imem_<test>.hex for all tests
#   make imem_t10_hello_soc   # builds combined image for one test
#
# Your testbench/BRAM init should load:
#   - build/imem_<test>.hex at address 0x0000_0000
# CPU resets at PC=0 -> executes boot -> jr 0x2000 -> app crt0/main

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
APP_BASE ?= 0x00002000

# Linker / startup
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

# Default: build combined images for all tests (recommended)
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
$(TESTS): %: boot imem_%
	@true

# Ensure build dir exists
$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

# ------------------------------------------------------------------------------
# Boot ROM build
boot: $(HEX_DIR)/boot.hex

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

# Link app
$(ELF_DIR)/%.elf: $(BUILD_DIR)/%.o $(CRT0_OBJ) $(COMMON_OBJS) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(CRT0_OBJ) $(COMMON_OBJS) $< -o $@ $(APP_LDFLAGS) $(LDLIBS) -lgcc

# ELF -> BIN
$(BIN_DIR)/%.bin: $(ELF_DIR)/%.elf | $(BUILD_DIR)
	$(OBJCOPY) -O binary $< $@

# BIN -> HEX (flat blob; only "correct" if your loader loads it at 0x2000)
$(HEX_DIR)/%.hex: $(BIN_DIR)/%.bin $(HEXIFY) | $(BUILD_DIR)
	$(PY) $(HEXIFY) $< $@ --strip-trailing-zeros --selfcheck

# ------------------------------------------------------------------------------
# Combined IMEM image (boot@0x0 + padding + app@APP_BASE)  <-- USE THIS
#
# Produces:
#   build/imem_<test>.bin
#   build/imem_<test>.hex
#
# Load imem_<test>.hex at base 0 in your testbench/BRAM init.
# ------------------------------------------------------------------------------
imem: boot
	@if [ -z "$(TEST)" ]; then \
	  echo "ERROR: set TEST=<name> (e.g. make imem TEST=t10_hello_soc) or use make imem_<name>"; \
	  exit 1; \
	fi
	@$(MAKE) imem_$(TEST)

imem-all: boot $(TESTS:%=imem_%)

imem_%: boot $(BIN_DIR)/boot.bin $(BIN_DIR)/%.bin $(HEXIFY) | $(BUILD_DIR)
	@echo "[imem] combining boot + $* at $(APP_BASE)"
	@$(PY) -c "import pathlib; \
boot=pathlib.Path('$(BIN_DIR)/boot.bin').read_bytes(); \
app=pathlib.Path('$(BIN_DIR)/$*.bin').read_bytes(); \
base=int('$(APP_BASE)',16); \
assert base>=len(boot), f'APP_BASE {base:#x} overlaps boot size {len(boot):#x}'; \
pad=b'\\x00'*(base-len(boot)); \
imem=boot+pad+app; \
out=pathlib.Path('$(BIN_DIR)/imem_$*.bin'); \
out.write_bytes(imem); \
print(f'[imem] boot={len(boot)} pad={len(pad)} app={len(app)} total={len(imem)} -> {out}')"
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
