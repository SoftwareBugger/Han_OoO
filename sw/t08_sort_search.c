/* t_ds_mix.c */
#include <stdint.h>

__attribute__((section(".signature")))
volatile uint32_t signature[16];

#define N 256
#define H 512

static uint32_t a[N];
static uint32_t key[H];
static uint32_t val[H];

static uint32_t xorshift32(uint32_t x) {
  x ^= x << 13; x ^= x >> 17; x ^= x << 5;
  return x;
}

static void ht_init(void) {
  for (int i = 0; i < H; i++) { key[i] = 0; val[i] = 0; }
}

static void ht_put(uint32_t k, uint32_t v) {
  uint32_t h = (k * 2654435761u) & (H - 1);
  for (int i = 0; i < 16; i++) {
    uint32_t idx = (h + (uint32_t)i) & (H - 1);
    if (key[idx] == 0 || key[idx] == k) { key[idx] = k; val[idx] = v; return; }
  }
}

static uint32_t ht_get(uint32_t k) {
  uint32_t h = (k * 2654435761u) & (H - 1);
  for (int i = 0; i < 16; i++) {
    uint32_t idx = (h + (uint32_t)i) & (H - 1);
    if (key[idx] == k) return val[idx];
    if (key[idx] == 0) break;
  }
  return 0xFFFFFFFFu;
}

static uint32_t checksum32(const uint32_t *p, int n) {
  uint32_t x = 0x13579BDFu;
  for (int i = 0; i < n; i++) x ^= p[i] + (x<<5) + (x>>2);
  return x;
}

// insertion sort (O(N^2) but N=256 is fine)
static void isort(uint32_t *p, int n) {
  for (int i = 1; i < n; i++) {
    uint32_t x = p[i];
    int j = i - 1;
    while (j >= 0 && p[j] > x) {
      p[j + 1] = p[j];
      j--;
    }
    p[j + 1] = x;
  }
}

int main(void) {
  signature[0] = 0x44534D58u; // 'DSMX'
  uint32_t rng = 0x10203040u;

  for (int i = 0; i < N; i++) {
    rng = xorshift32(rng);
    a[i] = rng ^ (uint32_t)(i * 0x9e37u);
  }

  ht_init();
  // insert some pairs
  for (int i = 0; i < 300; i++) {
    uint32_t k = (a[i & (N-1)] | 1u); // avoid 0
    uint32_t v = (k ^ 0xA5A5A5A5u) + (uint32_t)i;
    ht_put(k, v);
  }

  // probe
  uint32_t acc = 0;
  for (int i = 0; i < 300; i++) {
    uint32_t k = (a[(i*7) & (N-1)] | 1u);
    uint32_t v = ht_get(k);
    acc ^= v + (acc<<3) + (acc>>1);
  }

  isort(a, N);

  // verify sorted order
  uint32_t bad = 0;
  for (int i = 1; i < N; i++) if (a[i-1] > a[i]) bad = 1;

  signature[1] = acc;
  signature[2] = bad;
  signature[3] = checksum32(a, N);

  // Expect: bad==0 always; acc+checksum are deterministic
  const uint32_t EXPECT_BAD = 0;
  signature[4] = (bad == EXPECT_BAD) ? 0u : 1u;

  while (1) { }
}
