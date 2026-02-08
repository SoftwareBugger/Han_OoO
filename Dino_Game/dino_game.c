#include "dino_game.h"

static bool aabb_hit(int ax,int ay,int aw,int ah, int bx,int by,int bw,int bh) {
    return (ax < bx + bw) && (ax + aw > bx) && (ay < by + bh) && (ay + ah > by);
}

// tiny deterministic rng
static uint32_t rng32(uint32_t x) {
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return x;
}

static void clear_obstacles(GameState *g) {
    for (int i = 0; i < MAX_OBS; i++) {
        g->obs[i].active = false;
        g->obs[i].type = OBS_NONE;
        g->obs[i].x = 0;
        g->obs[i].y = 0;
        g->obs[i].anim = false;
    }
}

void game_init(GameState *g) {
    g->ground_y = 54;
    g->x = 10;
    g->y = g->ground_y - SPR_DINO_R.h;
    g->vy = 0;
    g->on_ground = true;
    g->facing = +1;

    g->scroll_speed = 3;

    clear_obstacles(g);

    g->running = true;
    g->game_over = false;
    g->score = 0;
    g->tick = 0;

    g->next_spawn_tick = 40;
}

void game_handle_input(GameState *g, InputEvent ev) {
    if (ev == INPUT_NONE) return;

    if (ev == INPUT_RESET) { game_init(g); return; }
    if (ev == INPUT_PAUSE) { g->running = !g->running; return; }

    if (g->game_over || !g->running) return;

    if (ev == INPUT_JUMP) {
        if (g->on_ground) {
            g->vy = -9;
            g->on_ground = false;
        }
    } else if (ev == INPUT_LEFT) {
        g->facing = -1;
        g->x -= 2;
        if (g->x < 0) g->x = 0;
    } else if (ev == INPUT_RIGHT) {
        g->facing = +1;
        g->x += 2;
        int maxx = OLED_W - SPR_DINO_R.w;
        if (g->x > maxx) g->x = maxx;
    }
}

static void spawn_one(GameState *g) {
    int slot = -1;
    for (int i = 0; i < MAX_OBS; i++) {
        if (!g->obs[i].active) { slot = i; break; }
    }
    if (slot < 0) return;

    uint32_t r = rng32(g->tick + g->score * 17u);
    ObstacleType t = (r & 3u) ? OBS_CACTUS : OBS_BIRD;

    g->obs[slot].active = true;
    g->obs[slot].type = t;
    g->obs[slot].anim = false;
    g->obs[slot].x = OLED_W + 2;

    if (t == OBS_CACTUS) {
        g->obs[slot].y = g->ground_y - SPR_CACTUS.h;
    } else {
        int h = (r & 0x10u) ? 30 : 40; // two flight heights
        g->obs[slot].y = h;
    }

    uint32_t gap = 28 + (r & 31u); // 28..59 ticks
    g->next_spawn_tick = g->tick + gap;
}

void game_update(GameState *g) {
    if (g->game_over || !g->running) return;

    g->tick++;
    g->score++;

    // gravity
    if (!g->on_ground) {
        g->vy += 1;
        g->y += g->vy;

        int floor_y = g->ground_y - SPR_DINO_R.h;
        if (g->y >= floor_y) {
            g->y = floor_y;
            g->vy = 0;
            g->on_ground = true;
        }
    }

    // spawn
    if (g->tick >= g->next_spawn_tick) {
        spawn_one(g);
    }

    // move + animate
    for (int i = 0; i < MAX_OBS; i++) {
        if (!g->obs[i].active) continue;

        g->obs[i].x -= g->scroll_speed;

        if (g->obs[i].type == OBS_BIRD) {
            if ((g->tick & 3u) == 0) g->obs[i].anim = !g->obs[i].anim;
        }

        int w = (g->obs[i].type == OBS_BIRD) ? SPR_BIRD_UP.w : SPR_CACTUS.w;
        if (g->obs[i].x + w < 0) g->obs[i].active = false;
    }

    // collision (AABB)
    const SpriteV8 *dino = &SPR_DINO_R;
    int dx = g->x, dy = g->y, dw = dino->w, dh = dino->h;

    for (int i = 0; i < MAX_OBS; i++) {
        if (!g->obs[i].active) continue;

        const SpriteV8 *spr =
            (g->obs[i].type == OBS_BIRD)
                ? (g->obs[i].anim ? &SPR_BIRD_UP : &SPR_BIRD_DOWN)
                : &SPR_CACTUS;

        int ox = g->obs[i].x;
        int oy = g->obs[i].y;
        int ow = spr->w;
        int oh = spr->h;

        if (aabb_hit(dx, dy, dw, dh, ox, oy, ow, oh)) {
            g->game_over = true;
            g->running = false;
            break;
        }
    }

    // speed up slowly
    if ((g->tick % 200u) == 0 && g->scroll_speed < 6) g->scroll_speed++;
}

void game_render(const GameState *g, Framebuffer *fb) {
    uint16_t bg  = rgb565(0,0,0);
    uint16_t fg  = rgb565(235,235,235);
    uint16_t red = rgb565(255,80,80);

    fb_clear(fb, bg);

    // ground line
    fb_rectfill(fb, 0, g->ground_y, OLED_W, 2, fg);

    // dino
    const SpriteV8 *dino = &SPR_DINO_R;
    if (g->game_over) dino = &SPR_DINO_DIE;
    else if (g->facing < 0) dino = &SPR_DINO_L;

    fb_blit_v8_1bpp(fb, dino, g->x, g->y, g->game_over ? red : fg);

    // obstacles
    for (int i = 0; i < MAX_OBS; i++) {
        if (!g->obs[i].active) continue;

        const SpriteV8 *spr =
            (g->obs[i].type == OBS_BIRD)
                ? (g->obs[i].anim ? &SPR_BIRD_UP : &SPR_BIRD_DOWN)
                : &SPR_CACTUS;

        fb_blit_v8_1bpp(fb, spr, g->obs[i].x, g->obs[i].y, fg);
    }

    // simple game over banner (no font required)
    if (g->game_over) {
        fb_rectfill(fb, 10, 10, 76, 8, red);
    }
}
