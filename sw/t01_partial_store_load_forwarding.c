#include <stdint.h>
#include "test_common.h"

static inline uint32_t load_u32(const volatile void *p) {
  return *(const volatile uint32_t*)p;
}
static inline uint16_t load_u16(const volatile void *p) {
  return *(const volatile uint16_t*)p;
}
static inline uint8_t load_u8(const volatile void *p) {
  return *(const volatile uint8_t*)p;
}

int main(void) {
  const uint32_t TID = 1;
  test_begin(TID);

  // Use volatile so compiler really does the loads/stores.
  volatile uint32_t mem[4];
  volatile uint8_t *b = (volatile uint8_t*)mem;
  volatile uint16_t *h = (volatile uint16_t*)mem;

  // Initialize all to known pattern
  mem[0] = 0x11223344u;
  mem[1] = 0xAABBCCDDu;
  mem[2] = 0x00000000u;
  mem[3] = 0xFFFFFFFFu;

  // 1) Byte overwrite within a word
  b[0] = 0xFE; // lowest byte of mem[0]
  if (load_u32(&mem[0]) != 0x112233FEu) test_fail(0x101);

  // 2) Halfword overwrite within a word (little-endian)
  h[1] = 0x1357; // upper halfword of mem[0]
  if (load_u32(&mem[0]) != 0x135723FEu) test_fail(0x102);

  // 3) Word store then byte stores overlay
  mem[1] = 0x00000000u;
  b[4] = 0x11;
  b[5] = 0x22;
  b[6] = 0x33;
  b[7] = 0x44;
  if (load_u32(&mem[1]) != 0x44332211u) test_fail(0x103);

  // 4) Sign/zero extension checks
  // Set byte = 0x80 (negative for signed byte)
  b[8] = 0x80;
  // Read back as uint8/uint16 and also via signed int8 in C
  uint8_t  u8  = load_u8(&b[8]);
  uint16_t u16 = (uint16_t)u8;
  int8_t   s8  = (int8_t)u8;
  int32_t  s32 = (int32_t)s8;
  if (u8 != 0x80u) test_fail(0x104);
  if (u16 != 0x0080u) test_fail(0x105);
  if (s32 != -128) test_fail(0x106);

  // 5) Mixed-width overwrite ordering
  mem[3] = 0xDEADBEEFu;
  h[6] = 0x0000;      // lower half of mem[3]
  b[14] = 0xAA;       // byte 2 of mem[3]
  // mem[3] bytes: [..] little endian: EF BE AD DE
  // after h[6]=0 => low half becomes 0x0000 => bytes [0]=00 [1]=00
  // after b[14]=0xAA => byte 2 becomes AA
  // final bytes: 00 00 AA DE => 0xDEAA0000
  if (load_u32(&mem[3]) != 0xDEAA0000u) test_fail(0x107);

  test_done(TID);
  return 0;
}
