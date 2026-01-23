/* boot.S */
.section .text.boot
.global _boot_start
_boot_start:
  /* jump to app entry at 0x00002000 */
  li  t0, 0x00002000
  jr  t0
