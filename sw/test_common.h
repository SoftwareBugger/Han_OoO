#pragma once
#include <stdint.h>

__attribute__((section(".signature")))
volatile uint32_t signature[16];

static inline void test_begin(uint32_t test_id) {
  signature[0] = 0xC0DEF00D;
  signature[1] = test_id;
  signature[2] = 0;
}

static inline void test_fail(uint32_t code) {
  signature[2] = code;
  // fallthrough: still write done so TB can end sim deterministically
}

static inline void test_done(uint32_t test_id) {
  signature[15] = 0xCAFE0000u | (test_id & 0xFFFFu); // "DONE" marker
  while (1) { }
}
