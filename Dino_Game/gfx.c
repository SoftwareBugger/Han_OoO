#include "gfx.h"

static inline int ceil_div8(int x) { return (x + 7) >> 3; }

void fb_clear(Framebuffer *fb, uint16_t color) {
    for (int i = 0; i < OLED_W * OLED_H; i++) fb->pix[i] = color;
}

void fb_putpixel(Framebuffer *fb, int x, int y, uint16_t color) {
    if ((unsigned)x >= OLED_W || (unsigned)y >= OLED_H) return;
    fb->pix[y * OLED_W + x] = color;
}

void fb_rectfill(Framebuffer *fb, int x, int y, int w, int h, uint16_t color) {
    if (w <= 0 || h <= 0) return;

    int x0 = x, y0 = y;
    int x1 = x + w - 1;
    int y1 = y + h - 1;

    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 >= OLED_W) x1 = OLED_W - 1;
    if (y1 >= OLED_H) y1 = OLED_H - 1;

    for (int yy = y0; yy <= y1; yy++) {
        uint16_t *row = &fb->pix[yy * OLED_W];
        for (int xx = x0; xx <= x1; xx++) row[xx] = color;
    }
}

int fb_blit_v8_1bpp(
    Framebuffer *fb,
    const SpriteV8 *spr,
    int dstx, int dsty,
    uint16_t fg
) {
    int pages = ceil_div8(spr->h);
    const uint8_t *pBMP = spr->data;
    int bit_count = 0;
    // Iterate down in 8-pixel row chunks (pages)
    for (int p = 0; p < pages; p++) {
        int ybase = p * 8;
        
        // Iterate across columns (left to right)
        for (int x = 0; x < spr->w; x++) {
            uint8_t b = *pBMP++;  // Read byte in row-major order
            
            // Draw each bit in the byte (LSB = top pixel)
            for (int bit = 0; bit < 8; bit++) {
                int y = ybase + bit;
                if (y >= spr->h) break;  // Don't draw beyond sprite height
                
                if (b & 0x01) {  // Check LSB (bit 0 = top pixel)
                    fb_putpixel(fb, dstx + x, dsty + y, fg);
                    bit_count++;
                }
                b >>= 1;  // Shift to next bit
            }
        }
    }
    return bit_count;
}
