#define DONE_ADDR 0x00001000u
#define BAD_ADDR  0x00001004u

volatile unsigned *done = (unsigned*)DONE_ADDR;
volatile unsigned *bad  = (unsigned*)BAD_ADDR;

int main() {
    *bad = 0;              // clear

    // Make a hard-to-predict branch pattern or just force a mispredict
    // (Even a simple branch can mispredict depending on your predictor.)
    if (1) {
        // Correct path
        *done = 0xC0FFEE01;
    } else {
        // WRONG PATH: must never become visible
        *bad = 0xDEADBEEF;
    }

    // Now validate in software (or RTL capture bad-store MMIO)
    if (*bad == 0xDEADBEEF) {
        *done = 0xBAD0BAD0; // indicates store leaked
    }

    while (1) { }
}
