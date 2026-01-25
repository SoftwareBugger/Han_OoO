ENTRY(_boot_start)

MEMORY {
  MEM (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
}

SECTIONS {
  . = ORIGIN(MEM);
  .text : ALIGN(4) {
    KEEP(*(.text.boot*))
    *(.text .text.*)
    *(.rodata .rodata.*)
  } > MEM
}
