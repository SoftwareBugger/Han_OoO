/* crt0.S */
.section .text.start
.global _start
_start:
  /* sp = _stack_top */
  la   sp, _stack_top

  /* clear .bss */
  la   t0, __bss_start
  la   t1, __bss_end
1:
  bge  t0, t1, 2f
  sw   zero, 0(t0)
  addi t0, t0, 4
  j    1b
2:
  call main

  /* if main returns: spin */
3:
  j 3b
