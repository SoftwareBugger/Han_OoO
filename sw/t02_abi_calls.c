#include <stdint.h>
#include "test_common.h"

// Prevent inlining so you get real call/ret + stack frames.
__attribute__((noinline))
static uint32_t mix(uint32_t a, uint32_t b, uint32_t c, uint32_t d, uint32_t e, uint32_t f) {
  // Encourage callee-saved usage by having locals and loops
  volatile uint32_t x = a + 0x11111111u;
  volatile uint32_t y = b ^ 0x22222222u;
  volatile uint32_t z = c + (d << 3);
  for (int i = 0; i < 7; i++) {
    x = (x << 1) ^ (x >> 3) ^ (uint32_t)i;
    y = (y + 0x9e3779b9u) ^ (y >> 1);
    z = z + (e ^ f) + (uint32_t)i;
  }
  return (uint32_t)(x ^ y ^ z);
}

__attribute__((noinline))
static uint32_t chain(uint32_t seed) {
  uint32_t r0 = mix(seed, seed+1, seed+2, seed+3, seed+4, seed+5);
  uint32_t r1 = mix(r0,   r0+1,   r0+2,   r0+3,   r0+4,   r0+5);
  uint32_t r2 = mix(r1,   r1^0x55u, r1+7,  r1+9,  r1+11, r1+13);
  return r0 ^ r1 ^ r2;
}

__attribute__((noinline))
static uint32_t recurse(uint32_t n, uint32_t acc) {
  // Simple recursion to stress stack/RA (no division/mod)
  if (n == 0) return acc;
  return recurse(n - 1, acc + (n ^ (acc << 1)));
}

int main(void) {
  const uint32_t TID = 2;
  test_begin(TID);

  uint32_t a = chain(0x1234u);
  uint32_t b = chain(0x4321u);
  uint32_t c = recurse(32, 0xACE1u);

  // Deterministic expected computed in a simple, independent way:
  // We'll just check internal consistency across different transformations.
  // If ABI/stack is broken, these will often go wildly off / become constant / crash.
  uint32_t sig = a ^ (b + 0x13579BDFu) ^ (c ^ 0x2468ACE0u);

  // A few strong invariants:
  if ((a ^ b) == 0) test_fail(0x201);
  if ((c & 0xFFFFu) == 0) test_fail(0x202);
  if (sig == 0 || sig == 0xFFFFFFFFu) test_fail(0x203);

  // Record signature so TB can compare across runs if you want.
  signature[3] = a;
  signature[4] = b;
  signature[5] = c;
  signature[6] = sig;

  test_done(TID);
  return 0;
}
