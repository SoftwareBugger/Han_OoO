/* boot.ld */
ENTRY(_boot_start)

MEMORY {
  ROM (rx) : ORIGIN = 0x00000000, LENGTH = 4K
}

SECTIONS {
  . = ORIGIN(ROM);
  .text : { *(.text.boot*) *(.text*) *(.rodata*) } > ROM
}
