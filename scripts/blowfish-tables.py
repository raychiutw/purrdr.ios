# 以 Machin 公式計算 π 的十六進位小數，產生 Blowfish 初始表(P 18 個字 + S 4×256 個字)。
import sys

WORDS = 18 + 4 * 256
HEX_DIGITS = WORDS * 8
BITS = HEX_DIGITS * 4 + 64


def arctan_inv(x, one):
    total = term = one // x
    x2 = x * x
    n = 1
    sign = -1
    while term:
        term //= x2
        n += 2
        total += sign * (term // n)
        sign = -sign
    return total


one = 1 << BITS
pi = 4 * (4 * arctan_inv(5, one) - arctan_inv(239, one))
frac = pi - (3 << BITS)
frac >>= 64  # 丟掉保護位元
hexstr = format(frac, "0{}x".format(HEX_DIGITS))
words = [int(hexstr[i * 8:(i + 1) * 8], 16) for i in range(WORDS)]
assert words[0] == 0x243F6A88, hex(words[0])
assert words[18] == 0xD1310BA6, hex(words[18])  # S0[0]
assert words[-1] == 0x3AC372E6, hex(words[-1])  # S3[255]

out = sys.argv[1]
with open(out, "w") as f:
    f.write("// 由 scripts/blowfish-tables.py 產生:Blowfish 的初始表是 π 的十六進位小數(Schneier 1993)。不要手改。\n")
    f.write("// P 陣列 18 個字，之後是 S-box 0～3 各 256 個字。\n\n")
    f.write("let blowfishInitialState: [UInt32] = [\n")
    for i in range(0, WORDS, 6):
        f.write("    " + ", ".join("0x%08X" % w for w in words[i:i + 6]) + ",\n")
    f.write("]\n")
