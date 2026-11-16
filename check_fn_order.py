#!/usr/bin/env python3
"""检查 bash 脚本里"函数定义顺序"是否满足依赖关系。

为什么要它：hb 在脚本加载时就会执行 hb_bootstrap，链条是
hb_bootstrap → hb_seal_payload → hb_encrypt。任何一个被调函数定义在
调用者后面，就会出现"第一次 command not found、第二次却成功"的偶然正确
（第二次加载时已经走到那行了）。这个 bug 犯过两次，靠记性不可靠。

用法：python3 tools/check_fn_order.py [脚本路径]   违规时退出码 1
"""
import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "hb"
lines = open(path, encoding="utf-8", errors="replace").read().splitlines()

# 顶层函数定义：# 处理 ---- 注释、第 0 列开始的 name() { ... }
defs = {}      # name -> start_line(1-based)
for i, l in enumerate(lines):
    m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{", l)
    if m and m.group(1) not in defs:
        defs[m.group(1)] = i + 1

order = sorted(defs.items(), key=lambda kv: kv[1])
body_range = {}
for idx, (name, start) in enumerate(order):
    end = order[idx + 1][1] - 1 if idx + 1 < len(order) else len(lines)
    body_range[name] = (start, end)

# "加载即执行"链上的函数：这些必须按依赖顺序排好。
# 其余子命令函数只在 dispatch 时调用，天然靠后，不参与检查。
EAGER = {"hb_bootstrap", "hb_seal_payload", "hb_encrypt", "hb_decrypt",
         "hex2bin", "bin2hex", "node_anchor", "payload_present",
         "payload_wanted", "payload_wants_plain", "hb_unpack", "key_unseal",
         "find_vault_key", "ensure_ssh", "ensure_ssh_conf", "seal_plain_leaks"}

bad = 0
for name in sorted(EAGER & set(defs), key=lambda n: defs[n]):
    start, end = body_range[name]
    # 只看代码行：注释里提到某个函数名（比如"见 seal_plain_leaks()"）不是调用。
    # 第一版没做这一步，报出 115 条全是误报 —— 比没有检查器更糟，
    # 因为人一旦见过它满屏乱叫，就会开始无视它的输出。
    code = [l.split("#", 1)[0] for l in lines[start:end]]
    body = "\n".join(code)
    for callee in EAGER & set(defs):
        if callee == name:
            continue
        if re.search(r"\b%s\b" % re.escape(callee), body) and defs[callee] > start:
            print("  x %s(L%d) 调用 %s(L%d) -- 定义在后面"
                  % (name, start, callee, defs[callee]))
            bad += 1

if bad:
    print("\n%d 处违规：把被调函数整体移到调用者之前（含它自己的依赖）。" % bad)
    sys.exit(1)
print("OK  加载链上的函数定义顺序正确（%d 个已检查）" % len(EAGER & set(defs)))
