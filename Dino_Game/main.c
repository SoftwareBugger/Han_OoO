#include <stdint.h>
#include <stdbool.h>

#include "soc_mmio.h"
#include "dino_game.h"   // for SPR_DINO_R (SpriteV8)
#include "gfx.h"         // for OLED_W/H

// If you want: simple echo for debugging
static inline void uart_echo(uint8_t c) { uart_putc((char)c); }

// Clamp helper
static inline int clamp_i(int v, int lo, int hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}


// Optional: draw a first frame using framebuffer flush (so OLED RAM has pixels to copy).
// You can also replace this with your own "draw sprite" routine if you already have one.
// Here we do a super-simple: clear whole screen, then draw the dino by brute-force full flush
// using your existing oled_flush in your old main (or keep it minimal and just draw once elsewhere).
static void oled_flush_rgb565_full(const Framebuffer *fb) {
    uint8_t col[] = { 0x15, 0x00, (uint8_t)(OLED_W - 1) };
    uint8_t row[] = { 0x75, 0x00, (uint8_t)(OLED_H - 1) };
    oled_write_cmdN(col, (int)sizeof(col));
    oled_write_cmdN(row, (int)sizeof(row));

    static uint8_t linebuf[OLED_W * 2];
    for (int y = 0; y < OLED_H; y++) {
        for (int x = 0; x < OLED_W; x++) {
            uint16_t v = fb->pix[y * OLED_W + x];
            linebuf[2*x + 0] = (uint8_t)(v >> 8);
            linebuf[2*x + 1] = (uint8_t)(v & 0xFF);
        }
        oled_write_dataN(linebuf, (int)sizeof(linebuf));
    }
}

int main(void) {
    // --------------------
    // UART init
    // --------------------
    uart_set_baud(217); // keep what you had (25MHz / 115200-ish)
    uart_puts_ram("Dino move: UART -> coords -> COPY then CLEAR\r\n");
    uart_puts_ram("Controls: a=left, d=right, w=up, s=down, r=reset\r\n");

    // --------------------
    // SPI + OLED init
    // --------------------
    spi_init(50, SPI_CTRL_EN | SPI_CTRL_WIDTH8 | SPI_CTRL_POS_EDGE | SPI_CTRL_CLK_PHASE);
    oled_init_ssd1331();

    // --------------------
    // Initial position + sprite box
    // --------------------
    const SpriteV8 *spr = &SPR_DINO_R;
    const int spr_w = spr->w;
    const int spr_h = spr->h;

    uart_puts_ram("spr ptr = "); uart_puthex((uint32_t)(uintptr_t)spr); uart_puts_ram("\r\n");
    uart_puts_ram("data ptr = "); uart_puthex((uint32_t)(uintptr_t)spr->data); uart_puts_ram("\r\n");
    for (int i = 0; i < 16; i++) {
        uart_puthex8(spr->data[i]); uart_putc(' ');
    }
    uart_puts_ram("\r\n");
    uart_puts_ram("w="); uart_putdec(spr->w);
    uart_puts_ram(" h="); uart_putdec(spr->h);
    uart_puts_ram("\r\n");

    int x = 10;
    int y = (OLED_H - spr_h - 2); // near bottom
    int old_x = x;
    int old_y = y;

    // --------------------
    // Draw initial scene once (so OLED RAM contains the dino pixels to copy)
    // If you already have a background + initial render path, keep that instead.
    // --------------------
    Framebuffer fb;
    fb_clear(&fb, rgb565(0,0,0));               // black bg
    int pix_count = fb_blit_v8_1bpp(&fb, spr, x, y, rgb565(255,255,255)); // white dino
    oled_flush_rgb565_full(&fb);
    if (pix_count == 0) {
        uart_puts_ram("Error: sprite blit failed\r\n");
        while (1);
    }

    // --------------------
    // Main loop: each UART char triggers one move/update
    // --------------------
    while (1) {
        uint8_t c = uart_getc_blocking();
        // uart_echo(c); // uncomment if you want to see typed keys echoed

        // 1) compute new coords from UART
        old_x = x;
        old_y = y;

        if (c == 'a') x -= 2;
        if (c == 'd') x += 2;
        if (c == 'w') y -= 2;
        if (c == 's') y += 2;
        if (c == 'r') { x = 10; y = (OLED_H - spr_h - 2); }

        // clamp to screen so copy window stays valid
        x = clamp_i(x, 0, OLED_W - spr_w);
        y = clamp_i(y, 0, OLED_H - spr_h);

        // no movement => no OLED ops
        if (x == old_x && y == old_y) continue;

        // 2) define old/new rectangles
        uint8_t x0 = (uint8_t)old_x;
        uint8_t y0 = (uint8_t)old_y;
        uint8_t x1 = (uint8_t)(old_x + spr_w - 1);
        uint8_t y1 = (uint8_t)(old_y + spr_h - 1);

        uint8_t nx = (uint8_t)x;
        uint8_t ny = (uint8_t)y;

        // If overlap happens, COPY-then-CLEAR can erase part of the copied region.
        // Easiest safe fallback: redraw whole frame (still deterministic).
        bool overlap =
            !( (nx + spr_w - 1) < x0 || (x0 + spr_w - 1) < nx ||
               (ny + spr_h - 1) < y0 || (y0 + spr_h - 1) < ny );

        if (overlap) {
            // Full redraw fallback
            fb_clear(&fb, rgb565(0,0,0));
            fb_blit_v8_1bpp(&fb, spr, x, y, rgb565(255,255,255));
            oled_flush_rgb565_full(&fb);
            continue;
        }

        // 3) COPY first (move pixels in OLED RAM)
        oled_copy_obj(x0, y0, x1, y1, nx, ny);

        // 4) CLEAR old window (erase old dino)
        oled_clear_window(x0, y0, x1, y1);
    }
}
