/* main.c */
#include <stdint.h>

__attribute__((section(".signature")))
volatile uint32_t signature[16];

static uint32_t checksum32(const uint32_t *p, int n) {
  uint32_t x = 0x12345678u;
  for (int i = 0; i < n; i++) {
    x ^= p[i] + (x << 5) + (x >> 2);
  }
  return x;
}

int main(void) {
  signature[0] = 0xC0DEF00D;

  /* Something branchy + memory-ish (C-like workload) */
  uint32_t board[15*15];
  for (int i = 0; i < 15*15; i++) board[i] = (uint32_t)i;
  for (int k = 0; k < 200; k++) {
    int idx = (k * 17) % (15*15);
    board[idx] ^= (uint32_t)(k + 0x9e37u);
    if (board[idx] & 1) board[(idx + 1) % (15*15)] += 3;
    else               board[(idx + 2) % (15*15)] -= 5;
  }

  uint32_t cs = checksum32(board, 15*15);
  signature[1] = cs;

  /* Put your expected checksum here once you decide a golden value */
  const uint32_t EXPECT = cs;   // start with “self-consistency”
  signature[2] = (cs == EXPECT) ? 0u : 1u;

  while (1) { }
}
/* End of main.c */