#pragma once
#include <stdint.h>
#include <stdbool.h>

#define OLED_W 96
#define OLED_H 64

// RGB565
static inline uint16_t rgb565(uint8_t r, uint8_t g, uint8_t b) {
    uint16_t R = (uint16_t)(r >> 3) & 0x1F;
    uint16_t G = (uint16_t)(g >> 2) & 0x3F;
    uint16_t B = (uint16_t)(b >> 3) & 0x1F;
    return (uint16_t)((R << 11) | (G << 5) | (B << 0));
}

typedef struct {
    uint16_t pix[OLED_W * OLED_H];
} Framebuffer;

// Your bitmap format: 1bpp vertical pages (SSD1306-style assets)
// data size = w * ceil(h/8)
typedef struct {
    int w;
    int h;
    const uint8_t *data;
} SpriteV8;

void fb_clear(Framebuffer *fb, uint16_t color);
void fb_putpixel(Framebuffer *fb, int x, int y, uint16_t color);
void fb_rectfill(Framebuffer *fb, int x, int y, int w, int h, uint16_t color);

// Blit 1bpp sprite in vertical-page format (transparent where bit=0)
// int fb_blit_v8_1bpp(
//     Framebuffer *fb,
//     const SpriteV8 *spr,
//     int dstx, int dsty,
//     uint16_t fg
// );
