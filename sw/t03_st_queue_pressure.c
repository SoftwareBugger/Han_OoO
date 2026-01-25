#include <stdint.h>
#include "test_common.h"

static inline uint32_t rotl(uint32_t x, int r) {
  return (x << r) | (x >> (32 - r));
}

int main(void) {
  const uint32_t TID = 3;
  test_begin(TID);

  // A small “heap” area in stack frame: lots of stores + loads
  volatile uint32_t buf[128];

  // Init
  for (int i = 0; i < 128; i++) buf[i] = 0xAAAAAAAAu ^ (uint32_t)i;

  // Store storm + dependent loads
  uint32_t acc = 0x12345678u;
  for (int k = 0; k < 2000; k++) {
    // No mod/div: wrap using mask (128 is power of 2)
    int idx = (k * 37) & 127;

    uint32_t v = rotl(acc, (k & 15)) ^ (uint32_t)(k * 0x9e37u);
    buf[idx] = v;                       // store
    uint32_t r1 = buf[idx];             // load same addr (should see v via forwarding or memory)
    uint32_t r2 = buf[(idx + 1) & 127]; // neighbor load
    acc ^= (r1 + 0x11111111u) ^ (r2 ^ 0x22222222u);

    // Encourage additional store merging / hazards
    if ((k & 7) == 0) {
      buf[(idx + 2) & 127] = acc ^ 0xDEADBEEFu;
      acc = (acc << 1) ^ (acc >> 3) ^ 0xA5A5A5A5u;
    }
  }

  // Post-check: deterministic hash over memory
  uint32_t h = 0xCAFEBABEu;
  for (int i = 0; i < 128; i++) {
    h ^= buf[i] + (h << 5) + (h >> 2);
  }

  signature[3] = acc;
  signature[4] = h;

  if (h == 0 || h == 0xFFFFFFFFu) test_fail(0x301);
  test_done(TID);
  return 0;
}
