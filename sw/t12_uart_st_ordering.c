#include "soc_mmio.h"
#include <stdint.h>
volatile uint32_t flag;

int main(void) {
    uart_set_baud(217);

    for (int i = 0; i < 10000; i++) {
        flag = 0x12345678;
        uart_putc('A');      // MMIO write
        flag = 0xCAFEBABE;   // normal store

        if (flag != 0xCAFEBABE) {
            uart_putc('!');  // ordering / visibility bug
            while (1) {}
        }
    }

    uart_putc('\n');
    uart_putc('O'); uart_putc('K'); uart_putc('\n');
    while (1) {}
}
