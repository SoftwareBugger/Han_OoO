#include "soc_mmio.h"
#include <stdint.h>
static char line[64];


int main(void) {
    uart_set_baud(217);
    uart_puts_ram("UART console ready\n> ");

    int idx = 0;
    while (1) {
        char c = uart_getc_blocking();

        // echo
        // uart_putc(c);

        if (c == '\r' || c == '\n') {
            line[idx] = 0;

            uart_puts_ram("\nYou typed: ");
            uart_puts_ram(line);
            uart_putc('\n');
            uart_puts_ram("> ");

            idx = 0;
        } else if (idx < 63) {
            line[idx++] = c;
        }
    }
}
