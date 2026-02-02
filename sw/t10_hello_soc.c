#include <stdint.h>
#include "soc_mmio.h"

static void delay(void) {
    for (volatile uint32_t i = 0; i < 60000; i++) {
        __asm__ volatile ("nop");
    }
}

/* Build message at runtime into .bss so it doesn't depend on .rodata/.data init */
static void build_hello(char *buf) {
    int i = 0;
    buf[i++] = 'H';
    buf[i++] = 'e';
    buf[i++] = 'l';
    buf[i++] = 'l';
    buf[i++] = 'o';
    buf[i++] = ' ';
    buf[i++] = 'S';
    buf[i++] = 'o';
    buf[i++] = 'C';
    buf[i++] = '!';
    buf[i++] = '\n';
    buf[i++] = 0;
}

int main(void) {
    uart_set_baud(217);  // 25MHz / 115200 ≈ 217 (adjust as needed)

    static char msg[32];     // .bss (no init image needed)
    build_hello(msg);

    while (1) {
        uart_puts_ram(msg);  // RAM-safe + TX polling
        delay();
    }
}
