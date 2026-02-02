/* crt0.S — Unified-image startup for RV32 (IMEM fetch-only, DMEM pre-initialized)
 *
 * Scheme:
 *  - You initialize BOTH IMEM and DMEM with the SAME memory image.
 *  - Code runs from IMEM (instruction port), but DMEM already contains the
 *    same bytes, so .rodata/.data initial values are already correct in DMEM.
 *
 * Therefore:
 *  - DO NOT copy .rodata/.data from IMEM -> DMEM (no __rodata_load/__data_load).
 *  - Only need to set sp/gp and clear .bss, then call main.
 *
 * Required linker symbols:
 *  - __stack_top
 *  - __bss_start, __bss_end
 *  - __global_pointer$  (recommended; harmless if small-data disabled)
 */

    .section .text.startup, "ax", @progbits
    .globl _start
    .type  _start, @function

_start:
    /* ------------------------------------------------------------
     * 1) Stack pointer (sp)
     * ------------------------------------------------------------ */
    lui   t0, %hi(__stack_top)
    addi  sp, t0, %lo(__stack_top)

    /* ------------------------------------------------------------
     * 2) Global pointer (gp)
     * ------------------------------------------------------------ */
    lui   t0, %hi(__global_pointer$)
    addi  gp, t0, %lo(__global_pointer$)

    /* ------------------------------------------------------------
     * 3) Zero .bss: [__bss_start .. __bss_end)
     * ------------------------------------------------------------ */
    lui   t0, %hi(__bss_start)
    addi  t0, t0, %lo(__bss_start)
    lui   t1, %hi(__bss_end)
    addi  t1, t1, %lo(__bss_end)
1:
    bgeu  t0, t1, 2f
    sw    zero, 0(t0)
    addi  t0, t0, 4
    j     1b
2:

    /* ------------------------------------------------------------
     * 4) Enter C
     * ------------------------------------------------------------ */
    call  main

    /* If main returns, spin */
3:
    j     3b

    .size _start, . - _start
