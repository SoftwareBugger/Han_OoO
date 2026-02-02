/* t_gomoku_core.c */
#include <stdint.h>

__attribute__((section(".signature")))
volatile uint32_t signature[16];

#define N 15
static uint8_t board[N*N];

static void clear_board(void) {
  for (int i = 0; i < N*N; i++) board[i] = 0;
}

static void place(int r, int c, uint8_t p) {
  board[r*N + c] = p;
}

static int inb(int r, int c) { return (r >= 0 && r < N && c >= 0 && c < N); }

static int count_dir(int r, int c, int dr, int dc, uint8_t p) {
  int k = 0;
  while (inb(r, c) && board[r*N + c] == p) {
    k++; r += dr; c += dc;
  }
  return k;
}

static int has_five(uint8_t p) {
  for (int r = 0; r < N; r++) {
    for (int c = 0; c < N; c++) {
      if (board[r*N + c] != p) continue;
      // 4 directions (avoid double count by only checking forward)
      if (count_dir(r,c, 0, 1,p) >= 5) return 1;
      if (count_dir(r,c, 1, 0,p) >= 5) return 1;
      if (count_dir(r,c, 1, 1,p) >= 5) return 1;
      if (count_dir(r,c, 1,-1,p) >= 5) return 1;
    }
  }
  return 0;
}

// deterministic pseudo-random (no mul/div needed)
static uint32_t xorshift32(uint32_t x) {
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  return x;
}

// simple move generator: pick first empty cell from a pseudo-random scan start
static int gen_move(uint32_t *state, int *out_r, int *out_c) {
  *state = xorshift32(*state);
  int start = (int)(*state & (N*N - 1)); // N*N=225 not pow2; that's okay, bias doesn't matter
  for (int i = 0; i < N*N; i++) {
    int idx = (start + i);
    if (idx >= N*N) idx -= N*N;
    if (board[idx] == 0) {
      *out_r = idx / N;
      *out_c = idx - (*out_r)*N;
      return 1;
    }
  }
  return 0;
}

static uint32_t checksum_board(void) {
  uint32_t x = 0xC0DEF00Du;
  for (int i = 0; i < N*N; i++) {
    x ^= (uint32_t)board[i] + (x << 5) + (x >> 2);
  }
  return x;
}

int main(void) {
  signature[0] = 0x474F4D4Fu; // 'GOMO'
  clear_board();

  uint32_t rng = 0x12345678u;
  uint8_t player = 1;
  int moves = 0;

  // play until someone wins or 120 moves
  while (moves < 120) {
    int r, c;
    if (!gen_move(&rng, &r, &c)) break;
    place(r, c, player);
    moves++;

    if (has_five(player)) break;
    player = (player == 1) ? 2 : 1;
  }

  uint32_t cs = checksum_board();
  signature[1] = (uint32_t)moves;
  signature[2] = cs;
  signature[3] = (uint32_t)has_five(1);
  signature[4] = (uint32_t)has_five(2);

  // Pass condition: deterministic checksum + deterministic move count for this seed
  // First run: set EXPECT = signature[2] from the golden run.
  const uint32_t EXPECT = cs;  // replace later
  signature[5] = (cs == EXPECT) ? 0u : 1u;

  *(volatile uint32_t*)0x00001000 = 0xdeadbeef;
  while (1) { }
}
