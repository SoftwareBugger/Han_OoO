#include <stdint.h>
#include <stdbool.h>

#include "soc_mmio.h"
#include "dino_game.h"
#include "gfx.h"

// Framebuffer is large (~12 KB). Keep it out of the stack.
static Framebuffer g_fb;

static inline bool uart_has_rx(void) {
    return (uart_status() & UART_RX_VALID) != 0;
}

static void oled_flush_window_from_fb(const Framebuffer *fb, int x, int y, int w, int h) {
    if (w <= 0 || h <= 0) return;

    int x0 = x, y0 = y;
    int x1 = x + w - 1;
    int y1 = y + h - 1;

    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 >= OLED_W) x1 = OLED_W - 1;
    if (y1 >= OLED_H) y1 = OLED_H - 1;

    if (x1 < x0 || y1 < y0) return;

    uint8_t col[] = { 0x15, (uint8_t)x0, (uint8_t)x1 };
    uint8_t row[] = { 0x75, (uint8_t)y0, (uint8_t)y1 };
    oled_write_cmdN(col, (int)sizeof(col));
    oled_write_cmdN(row, (int)sizeof(row));

    int width = x1 - x0 + 1;
    static uint8_t linebuf[OLED_W * 2];
    for (int yy = y0; yy <= y1; yy++) {
        const uint16_t *rowp = &fb->pix[yy * OLED_W + x0];
        for (int xx = 0; xx < width; xx++) {
            uint16_t v = rowp[xx];
            linebuf[2*xx + 0] = (uint8_t)(v >> 8);
            linebuf[2*xx + 1] = (uint8_t)(v & 0xFF);
        }
        oled_write_dataN(linebuf, width * 2);
    }
}

typedef struct {
    int x, y, w, h;
} Rect;

static inline void add_rect(Rect *list, int *count, int x, int y, int w, int h) {
    if (w <= 0 || h <= 0) return;
    list[*count].x = x;
    list[*count].y = y;
    list[*count].w = w;
    list[*count].h = h;
    (*count)++;
}

static const SpriteV8 *obs_sprite(const Obstacle *o) {
    if (o->type == OBS_BIRD) return o->anim ? &SPR_BIRD_UP : &SPR_BIRD_DOWN;
    if (o->type == OBS_CACTUS) return &SPR_CACTUS;
    return &SPR_CACTUS;
}

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
    uart_puts_ram("Dino: w/space=jump, r=reset, p=pause\r\n");

    // --------------------
    // SPI + OLED init
    // --------------------
    spi_init(50, SPI_CTRL_EN | SPI_CTRL_WIDTH8 | SPI_CTRL_POS_EDGE | SPI_CTRL_CLK_PHASE);
    oled_init_ssd1331();

    // --------------------
    // Game state
    // --------------------
    GameState g;
    game_init(&g);

    // --------------------
    // Main loop: fixed tick
    // --------------------
    while (1) {
        GameState prev = g;

        if (uart_has_rx()) {
            uint8_t c = (uint8_t)mmio_read32(UART_BASE + UART_DATA);
            if (c == 'w' || c == ' ') game_handle_input(&g, INPUT_JUMP);
            else if (c == 'r') game_handle_input(&g, INPUT_RESET);
            else if (c == 'p') game_handle_input(&g, INPUT_PAUSE);
            else if (c == 'a') game_handle_input(&g, INPUT_LEFT);
            else if (c == 'd') game_handle_input(&g, INPUT_RIGHT);
        }

        game_update(&g);
        game_render(&g, &g_fb);

        Rect dirty[2 + (MAX_OBS * 2)];
        int dirty_count = 0;

        const SpriteV8 *d_prev = prev.game_over ? &SPR_DINO_DIE : (prev.facing < 0 ? &SPR_DINO_L : &SPR_DINO_R);
        const SpriteV8 *d_now  = g.game_over ? &SPR_DINO_DIE : (g.facing < 0 ? &SPR_DINO_L : &SPR_DINO_R);
        add_rect(dirty, &dirty_count, prev.x, prev.y, d_prev->w, d_prev->h);
        add_rect(dirty, &dirty_count, g.x, g.y, d_now->w, d_now->h);

        for (int i = 0; i < MAX_OBS; i++) {
            if (prev.obs[i].active) {
                const SpriteV8 *sp = obs_sprite(&prev.obs[i]);
                add_rect(dirty, &dirty_count, prev.obs[i].x, prev.obs[i].y, sp->w, sp->h);
            }
            if (g.obs[i].active) {
                const SpriteV8 *sn = obs_sprite(&g.obs[i]);
                add_rect(dirty, &dirty_count, g.obs[i].x, g.obs[i].y, sn->w, sn->h);
            }
        }

        for (int i = 0; i < dirty_count; i++) {
            oled_flush_window_from_fb(&g_fb, dirty[i].x, dirty[i].y, dirty[i].w, dirty[i].h);
        }

        // crude frame pacing; adjust for your clock
        delay_cycles(2000);
    }
}
