/* app.ld */
ENTRY(_start)

MEMORY {
  RAM (rwx) : ORIGIN = 0x00002000, LENGTH = 64K
}

SECTIONS {
  . = ORIGIN(RAM);

  .text : {
    *(.text.start)
    *(.text*)
  } > RAM

  .rodata : {
    *(.rodata*)
    *(.srodata*)
  } > RAM

  .data : {
    *(.data*)
    *(.sdata*)
  } > RAM

  .bss : {
    __bss_start = .;
    *(.bss*)
    *(.sbss*)
    *(COMMON)
    __bss_end = .;
  } > RAM

  _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
