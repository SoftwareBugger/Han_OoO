#include <stdint.h>
#include "test_common.h"

volatile uint32_t mem_area[64];

__attribute__((noinline))
static int branchy(uint32_t x) {
  // Create unpredictable branches for the predictor
  if ((x ^ (x >> 3) ^ (x >> 7)) & 1)
    return 1;
  else
    return 0;
}

int main(void) {
  const uint32_t TID = 5;
  test_begin(TID);

  // Initialize memory to known pattern
  for (int i = 0; i < 64; i++)
    mem_area[i] = 0x11110000u + (uint32_t)i;

  uint32_t acc = 0x12345678u;

  for (int k = 0; k < 1000; k++) {
    uint32_t idx = (k * 13u) & 63;

    // Force mispredicts by changing branch behavior over time
    if (branchy(acc)) {
      // ----- WRONG PATH (often) -----
      // These stores MUST NOT survive a mispredict
      mem_area[idx]     = acc ^ 0xAAAA0000u;
      mem_area[idx + 1] = acc ^ 0xBBBB0000u;

      // Encourage store addr+data to become ready
      acc = (acc << 1) ^ 0x13579BDFu;
    } else {
      // ----- CORRECT PATH -----
      // Loads must never see wrong-path stores
      uint32_t v0 = mem_area[idx];
      uint32_t v1 = mem_area[(idx + 1) & 63];

      acc ^= v0 + (v1 << 1);
    }

    // Force predictor churn
    acc ^= (acc >> 5) ^ (uint32_t)k;
  }

  // After all chaos, memory must still be original pattern
  uint32_t h = 0;
  for (int i = 0; i < 64; i++)
    h ^= mem_area[i] + (uint32_t)i;

  signature[3] = acc;
  signature[4] = h;

  // If any wrong-path store leaked, h will change
  uint32_t expected_h = 0;
  for (int i = 0; i < 64; i++)
    expected_h ^= (0x11110000u + (uint32_t)i) + (uint32_t)i;

  if (h != expected_h)
    test_fail(0x501);

  test_done(TID);
  return 0;
}
