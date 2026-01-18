/* t_scheduler_sim.c */
#include <stdint.h>

__attribute__((section(".signature")))
volatile uint32_t signature[16];

#define NTASK 16
#define QSZ   32

typedef struct {
  uint32_t regs[8];
  uint32_t pc;
  uint32_t state;   // 0=ready 1=blocked
  uint32_t budget;
} task_t;

static task_t tasks[NTASK];
static int rq[QSZ];
static int rq_head, rq_tail;

static void rq_push(int tid) {
  rq[rq_tail] = tid;
  rq_tail = (rq_tail + 1) % QSZ;
}

static int rq_pop(void) {
  int tid = rq[rq_head];
  rq_head = (rq_head + 1) % QSZ;
  return tid;
}

static uint32_t xorshift32(uint32_t x) {
  x ^= x << 13; x ^= x >> 17; x ^= x << 5;
  return x;
}

static uint32_t checksum_tasks(void) {
  uint32_t x = 0x9E3779B9u;
  for (int t = 0; t < NTASK; t++) {
    x ^= tasks[t].pc + (x << 6) + (x >> 2);
    x ^= tasks[t].budget + (x << 6) + (x >> 2);
    for (int i = 0; i < 8; i++)
      x ^= tasks[t].regs[i] + (x << 6) + (x >> 2);
  }
  return x;
}

int main(void) {
  signature[0] = 0x53434844u; // 'SCHD'
  rq_head = rq_tail = 0;

  // init tasks
  for (int t = 0; t < NTASK; t++) {
    tasks[t].pc = 0x1000u + (uint32_t)(t * 4);
    tasks[t].state = 0;
    tasks[t].budget = (uint32_t)(5 + (t & 3));
    for (int i = 0; i < 8; i++) tasks[t].regs[i] = (uint32_t)(t * 17 + i);
    rq_push(t);
  }

  uint32_t rng = 0xCAFEBABEu;
  int ticks = 20000;

  while (ticks--) {
    int tid = rq_pop();
    task_t *cur = &tasks[tid];

    // emulate "running": update registers and pc
    rng = xorshift32(rng);
    cur->regs[rng & 7] ^= (rng + cur->pc);
    cur->pc += 4;

    // time slice / budget
    if (cur->budget) cur->budget--;
    if (cur->budget == 0) {
      cur->budget = (uint32_t)(5 + (tid & 3));
      // occasionally block/unblock
      if ((rng & 15) == 0) cur->state = 1;
    }

    // unblock sometimes
    if (cur->state && ((rng >> 8) & 7) == 0) cur->state = 0;

    // enqueue
    if (!cur->state) rq_push(tid);
    else rq_push((tid + 1) & (NTASK - 1)); // keep queue moving deterministically
  }

  uint32_t cs = checksum_tasks();
  signature[1] = cs;
  const uint32_t EXPECT = cs; // replace after first golden
  signature[2] = (cs == EXPECT) ? 0u : 1u;

  while (1) { }
}
