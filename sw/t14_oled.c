#include "soc_mmio.h"
#include <stdint.h>

static void oled_fill_enable(int en) {
    oled_write_cmd2(0x26, en ? 0x01 : 0x00);
}

static void oled_draw_rect(uint8_t x0, uint8_t y0, uint8_t x1, uint8_t y1,
                           uint8_t ol_r, uint8_t ol_g, uint8_t ol_b,
                           uint8_t fi_r, uint8_t fi_g, uint8_t fi_b) {
    uint8_t cmd[] = {
        0x22, x0, y0, x1, y1,
        ol_r, ol_g, ol_b,
        fi_r, fi_g, fi_b
    };
    oled_write_cmdN(cmd, (int)sizeof(cmd));
}

void oled_demo(void) {
    oled_fill_enable(1);
    // Full screen rectangle: x=0..95 (0x5F), y=0..63 (0x3F)
    // Outline color: red-ish, Fill color: green-ish (tweak)
    oled_draw_rect(0x03, 0x02, 0x12, 0x15, 28,0,0, 0,0,40);
}

int main(void)
{
    // Optional UART debug
    uart_set_baud(217);
    uart_puts_ram("OLED bringup...\r\n");

    // Init SPI first
    spi_init(50, SPI_CTRL_EN | SPI_CTRL_WIDTH8 | SPI_CTRL_POS_EDGE | SPI_CTRL_CLK_PHASE);

    // *** THIS WAS THE MISSING STEP ***
    oled_init_ssd1331();
    // oled_power_on_simple();

    uint8_t done = 0;

    // Draw demo forever
    while (1) {
        if (!done) {
            *(volatile uint32_t *)0x10000000 = 0xDEADBEEF;
            done = 1;
        }
        oled_demo();
        delay_ms(50);
    }
    // return 0; // unreachable
}


