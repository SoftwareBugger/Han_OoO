import sys

def load_hex(path):
    with open(path) as f:
        lines = [ln.strip() for ln in f if ln.strip() and not ln.startswith("//")]
    # hexify.py typically emits one 32-bit word per line (check your format)
    return lines

def main():
    boot_hex, app_hex, out_hex = sys.argv[1], sys.argv[2], sys.argv[3]
    app_word_offs = 0x2000 // 4  # 2048

    boot = load_hex(boot_hex)
    app  = load_hex(app_hex)

    total_words = max(len(boot), app_word_offs + len(app))
    mem = ["00000000"] * total_words

    for i,w in enumerate(boot):
        mem[i] = w
    for i,w in enumerate(app):
        mem[app_word_offs + i] = w

    with open(out_hex, "w") as f:
        for w in mem:
            f.write(w + "\n")

if __name__ == "__main__":
    main()
