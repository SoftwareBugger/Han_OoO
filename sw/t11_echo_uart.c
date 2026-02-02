#include <stdint.h>
#include "soc_mmio.h"

static inline char hex_nibble(uint8_t x) {
    x &= 0xF;
    return (x < 10) ? (char)('0' + x) : (char)('A' + (x - 10));
}

static void uart_put_hex8(uint8_t v) {
    uart_putc((char)hex_nibble(v >> 4));
    uart_putc((char)hex_nibble(v));
}

static void delay(void) {
    for (volatile uint32_t i = 0; i < 60000; i++) {
        __asm__ volatile ("nop");
    }
}

static void build_banner(char *b) {
    int i = 0;

    /* "UART echo test\n" */
    b[i++] = 'U'; b[i++] = 'A'; b[i++] = 'R'; b[i++] = 'T'; b[i++] = ' ';
    b[i++] = 'e'; b[i++] = 'c'; b[i++] = 'h'; b[i++] = 'o'; b[i++] = ' ';
    b[i++] = 't'; b[i++] = 'e'; b[i++] = 's'; b[i++] = 't';
    b[i++] = '\n';

    /* "Type bytes; we echo and print hex.\n" */
    b[i++] = 'T'; b[i++] = 'y'; b[i++] = 'p'; b[i++] = 'e'; b[i++] = ' ';
    b[i++] = 'b'; b[i++] = 'y'; b[i++] = 't'; b[i++] = 'e'; b[i++] = 's';
    b[i++] = ';'; b[i++] = ' ';
    b[i++] = 'w'; b[i++] = 'e'; b[i++] = ' ';
    b[i++] = 'e'; b[i++] = 'c'; b[i++] = 'h'; b[i++] = 'o'; b[i++] = ' ';
    b[i++] = 'a'; b[i++] = 'n'; b[i++] = 'd'; b[i++] = ' ';
    b[i++] = 'p'; b[i++] = 'r'; b[i++] = 'i'; b[i++] = 'n'; b[i++] = 't'; b[i++] = ' ';
    b[i++] = 'h'; b[i++] = 'e'; b[i++] = 'x'; b[i++] = '.';
    b[i++] = '\n';

    b[i++] = 0;
}



int main(void) {
    uart_set_baud(217);   /* or uart_set_baud_div(217) — match your soc_mmio.h */

    // static const char banner[] = "UART echo something: Beauty is in the eye of the beholder. We should appreciate it.";// = "UART echo something sooooo Loooooong";   /* .bss */
    static char banner[96];
    build_banner(banner);

    // uart_puts_ram(banner);
    volatile uint8_t c = 0;
    // char banner[] = "ABCDEFGH!";


    while (1) {

        /* echo raw byte */
        if (banner[c] == 0) c = 0;
        uart_putc(banner[c++]);
        uart_getc_blocking();
    }
}
