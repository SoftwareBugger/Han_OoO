#include <stdint.h>
#include "soc_mmio.h"

static volatile uint8_t rx_log[4];
static volatile uint32_t sink;

static void uart_puthex4(uint8_t v) {
    v &= 0xF;
    uart_putc(v < 10 ? '0' + v : 'A' + (v - 10));
}

static void uart_puthex8(uint8_t v) {
    uart_puthex4(v >> 4);
    uart_puthex4(v);
}

static void uart_puthex32(uint32_t v) {
    uart_puthex8((v >> 24) & 0xFF);
    uart_puthex8((v >> 16) & 0xFF);
    uart_puthex8((v >>  8) & 0xFF);
    uart_puthex8((v >>  0) & 0xFF);
}


int main(void) {
    uart_set_baud(217);
    uart_puts_ram("spi_tx_sending\r\n");

    spi_init(100, SPI_CTRL_EN | SPI_CTRL_WIDTH8 | SPI_CTRL_POS_EDGE);

    while (1) {
        spi_cs_assert();

        uint8_t buf[] = {0xDE, 0xAD, 0xBE, 0xEF};
        spi_write_bytes(buf, sizeof(buf)); // JEDEC ID command

        spi_cs_deassert();

        // Optional: print once per loop, after CS high (safe)
        uart_puts_ram("done\r\n");
    }
}
