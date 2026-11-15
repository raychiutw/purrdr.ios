import random, sys, time, string

# 3 秒內持續輸出隨機 256 色文字(最壞情況頻寬測試)
end = time.time() + float(sys.argv[1]) if len(sys.argv) > 1 else time.time() + 3
chars = string.ascii_letters + string.digits
out = sys.stdout
while time.time() < end:
    buf = []
    for _ in range(2000):
        buf.append("\x1b[38;5;%dm\x1b[48;5;%dm%s" % (random.randrange(256), random.randrange(256), random.choice(chars)))
    out.write("".join(buf))
    out.flush()
out.write("\x1b[0m\n")
