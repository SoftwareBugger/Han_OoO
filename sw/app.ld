ENTRY(_start)

MEMORY {
  MEM (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
}

__stack_size = 0x2000;  /* 8 KiB */
__stack_top  = ORIGIN(MEM) + LENGTH(MEM);          /* 0x8000 */
__stack_bot  = __stack_top - __stack_size;         /* 0x6000 */

SECTIONS {
  /* App starts at 0x2000 */
  . = 0x00002000;

  .text : ALIGN(4) {
    __text_start = .;
    KEEP(*(.text.startup .text.startup.*))
    *(.text .text.*)
    __text_end = .;
  } > MEM

  .rodata : ALIGN(4) {
    __rodata_start = .;
    *(.rodata .rodata.*)
    *(.srodata .srodata.*)
    . = ALIGN(4);
    __rodata_end = .;
  } > MEM

  .data : ALIGN(4) {
    __data_start = .;
    *(.data .data.*)
    *(.sdata .sdata.*)
    . = ALIGN(4);
    __data_end = .;
  } > MEM

  PROVIDE(__global_pointer$ = __data_start + 0x800);

  .bss (NOLOAD) : ALIGN(4) {
    __bss_start = .;
    *(.bss .bss.*)
    *(.sbss .sbss.*)
    *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > MEM

  /* Optional heap region */
  __heap_start = __bss_end;
  __heap_end   = __stack_bot;

  ASSERT(__bss_end <= __stack_bot,
         "ERROR: DMEM overflow: app sections collide with stack")
}
