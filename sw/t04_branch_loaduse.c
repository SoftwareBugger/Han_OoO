#include <stdint.h>
#include "test_common.h"

__attribute__((noinline))
static uint32_t step(uint32_t x) {
  // Branch-heavy transform
  if (x & 1) x = (x >> 1) ^ 0xA3000001u;
  else      x = (x << 1) ^ 0x5C000003u;

  if (x & 0x100) x ^= (x >> 7);
  if (x & 0x8000) x += 0x9e3779b9u;
  return x;
}

int main(void) {
  const uint32_t TID = 4;
  test_begin(TID);

  volatile uint32_t table[256];
  for (int i = 0; i < 256; i++) table[i] = (uint32_t)i * 0x01010101u;

  uint32_t x = 0x12345678u;
  uint32_t acc = 0;

  for (int k = 0; k < 5000; k++) {
    x = step(x);

    // Load-use: index depends on just-computed x
    uint32_t idx = (x >> 8) & 0xFF;
    uint32_t v = table[idx];

    // Store back (creates hazards)
    table[idx] = v ^ x ^ (uint32_t)k;

    // More branching
    if ((v ^ x) & 0x10) acc += (v + x);
    else                acc ^= (v ^ (x >> 3));
  }

  // Final reduce
  uint32_t h = 0;
  for (int i = 0; i < 256; i++) h ^= table[i];

  signature[3] = acc;
  signature[4] = h;

  if (h == 0) test_fail(0x401);
  test_done(TID);
  return 0;
}
