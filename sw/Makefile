# sw/Makefile
# Build all C tests in this directory into .elf/.bin/.hex
# Usage:
#   make            # build all
#   make clean
#   make O=2        # build with -O2
#   make list       # show detected tests

RISCV_PREFIX ?= riscv64-unknown-elf-
CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy

ARCH ?= rv32i
ABI  ?= ilp32
O    ?= 0

CFLAGS  := -march=$(ARCH) -mabi=$(ABI) -ffreestanding -nostdlib -O$(O) -Wall -Wextra
LDFLAGS := -T link.ld
LDLIBS  := -lgcc

CRT0 := crt0.S

# All C tests in this folder (exclude any file you don't want built here)
C_SRCS := $(wildcard *.c)
TESTS  := $(patsubst %.c,%,$(C_SRCS))

BUILD_DIR := build

ELFS := $(addprefix $(BUILD_DIR)/,$(addsuffix .elf,$(TESTS)))
BINS := $(addprefix $(BUILD_DIR)/,$(addsuffix .bin,$(TESTS)))
HEXS := $(addprefix $(BUILD_DIR)/,$(addsuffix .hex,$(TESTS)))

.PHONY: all clean list
all: $(HEXS)

list:
	@echo "C_SRCS: $(C_SRCS)"
	@echo "TESTS : $(TESTS)"

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

# Compile + link one test
$(BUILD_DIR)/%.elf: %.c $(CRT0) link.ld | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) $(CRT0) $< $(LDLIBS) -o $@

# ELF -> BIN
$(BUILD_DIR)/%.bin: $(BUILD_DIR)/%.elf
	$(OBJCOPY) -O binary $< $@

# BIN -> HEX (little-endian 32-bit words, one per line)
$(BUILD_DIR)/%.hex: $(BUILD_DIR)/%.bin hexify.py
	python3 hexify.py $< $@

clean:
	@rm -rf $(BUILD_DIR)

# ------------------------------------------------------------
# Golden trace generation
# ------------------------------------------------------------

# Where hex files are
HEX_DIR := $(BUILD_DIR)
# Where golden traces go
GOLDEN_DIR := golden_traces

# Python script
HEX2TRACE := hex2trace.py

.PHONY: golden golden-clean

golden: all
	@echo "Generating golden traces..."
	@python3 $(HEX2TRACE) "$(HEX_DIR)/*.hex"

golden-clean:
	@rm -rf $(GOLDEN_DIR)
