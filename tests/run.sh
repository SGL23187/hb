#!/usr/bin/env bash
# hb 的行为护栏。原则：**默认全离线**，不连 NAS、不碰 home1，能跑在任何一台机器上。
#   bash tests/run.sh          离线用例（秒级）
#   bash tests/run.sh --online 加跑需要网络的（ssh / tailscale）
#
# 为什么要有它：hb 以前是"改完手跑一遍"就算验收。自从拆成 src/*.sh 之后，
# 单条命令的回归就应该是可重放的，而不是靠记忆。
set -u
cd "$(dirname "$0")/.."

PASS=0; FAIL=0; FAILED=()
ok()   { PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  FAIL %s\n' "$1" >&2; }
section() { printf '\n▸ %s\n' "$1"; }

# assert_contains <名字> <输出> <子串>
assert_contains() {
  if [[ $2 == *"$3"* ]]; then ok "$1"; else bad "$1（缺 '$3'）"; printf '     实际: %s\n' "$(printf '%s' "$2" | head -3)"; fi
}
assert_rc() {   # <名字> <实际退出码> <期望>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（退出码 $2，期望 $3）"; fi
}

ONLINE=0
[ "${1:-}" = "--online" ] && ONLINE=1

section '构建与语法'
out=$(bash build.sh 2>&1); rc=$?
assert_rc 'build.sh 能拼出 hb' "$rc" 0
bash -n hb 2>&1; assert_rc 'hb 语法' "$?" 0

section '分发器必须在文件末尾'
# 少拼一个模块的症状是「命令表里有、敲了没反应」——比报错更难查。
tail -3 hb | grep -q '^cmd_run "\$@"$'
assert_rc '分发器在最后 3 行' "$?" 0
grep -q '^exit \$?$' hb && ok '末尾有显式 exit（退出码会被透传）' || bad '末尾缺 exit' 

section 'help 与命令表一致性'
CMDS=$(grep -cE '^  "[a-z0-9|_-]+\|cmd_' hb)
HELP_OUT=$(./hb --help 2>&1)
MISSING=()
while IFS= read -r line; do
  name=$(printf '%s' "$line" | cut -d'|' -f1 | sed 's/^ *//')
  printf '%s' "$HELP_OUT" | grep -q "hb $name " || MISSING+=("$name")
done < <(grep -E '^  "[a-z0-9|_-]+\|cmd_' hb | sed 's/^ *"//; s/"$//')
if [ ${#MISSING[@]} -eq 0 ]; then ok "help 覆盖全部 $CMDS 个命令"; else bad "help 漏了: ${MISSING[*]}"; fi

section '别名（hosts）'
# 用临时 hosts 文件，测试不依赖任何本机数据 —— 公开仓库里没有真实别名
TMPH=$(mktemp); printf 'box 127.0.0.1 user=test
lab 10.0.0.9
' > "$TMPH"
export HB_HOSTS_FILE="$TMPH"
HOSTS_OUT=$(./hb hosts 2>&1)
assert_contains 'hosts 能列出第一条' "$HOSTS_OUT" 'box'
assert_contains 'hosts 能列出第二条' "$HOSTS_OUT" 'lab'
./hb hosts add __hbtest 127.0.0.2 user=test >/dev/null 2>&1
assert_rc 'hosts add 退出码' "$?" 0
grep -q '__hbtest' "$TMPH" && ok '别名已落盘' || bad '别名没写入'
./hb hosts rm __hbtest >/dev/null 2>&1
grep -q '__hbtest' "$TMPH" && bad 'rm 没删掉' || ok 'hosts rm 能删'
# 别名与子命令同名必须被拒（否则 hb <词> 的语义靠 case 顺序决定）
./hb hosts add list 1.2.3.4 >/dev/null 2>&1 && bad '允许了与子命令同名的别名' || ok '拒绝与子命令同名的别名'
unset HB_HOSTS_FILE; rm -f "$TMPH"

section '错误契约（报错必须含"怎么修"）'
ERR=$(./hb definitely-not-a-command 2>&1); RC=$?
[ $RC -ne 0 ] && ok '未知命令返回非零' || bad '未知命令返回 0'
assert_contains '未知命令给了有用提示' "$ERR" 'hb hosts add'

section '静态检查（函数定义顺序）'
if command -v python3 >/dev/null; then
  python3 check_fn_order.py hb >/dev/null 2>&1
  assert_rc 'check_fn_order.py' "$?" 0
else
  echo '  skip  无 python3'
fi

section '平台层（src/05-platform.sh）'
# 这一步针对真 bug：MSYS 会把参数里的 "/" 改写成 Windows 路径
if [[ "$(uname -s 2>/dev/null)" == MINGW* || "$(uname -s 2>/dev/null)" == MSYS* ]]; then
  grep -q 'MSYS_NO_PATHCONV=1' hb
  assert_rc '产物里带 MSYS 路径改写防护' "$?" 0
  # 运行 hb 时环境变量必须已导出（否则子进程仍会拿到被改写的路径）
  ./hb hosts >/dev/null 2>&1
  assert_rc '加防护后 hosts 仍正常' "$?" 0
else
  echo '  skip  非 MSYS 平台（此坑只在 Windows 上出现）'
fi

section '跨平台端口探针（别再退回 nc -z）'
# 真 bug：MSYS 没有 nc，`nc -z ... 2>/dev/null` 静默失败 → "端口在监听"报成"未监听"
grep -q '^port_open()' hb
assert_rc 'port_open 存在于产物' "$?" 0
BAD_NC=$(grep -n 'nc -z' hb | grep -v 'port_open' | grep -v '^[0-9]*: *#' | grep -vc 'timeout "$tmo" nc -z' || true)
[ "$BAD_NC" = "0" ] && ok '没有绕过 port_open 的裸 nc -z' || bad "还有 $BAD_NC 处裸 nc -z"
# 行为：关着的端口必须判"不通"（端口 1 不会有服务）
eval "$(sed -n '/^port_open()/,/^}/p' hb)" 2>/dev/null || true
port_open 127.0.0.1 1 1; assert_rc 'port_open 对关闭端口返回非零' "$?" 1

section 'hb put / get'
HELP2=$(./hb --help 2>&1)
assert_contains 'help 有 put' "$HELP2" 'hb put'
assert_contains 'help 有 get' "$HELP2" 'hb get'
ERR2=$(./hb put 2>&1); RC2=$?
[ $RC2 -ne 0 ] && ok 'put 缺参数时非零退出' || bad 'put 缺参数返回 0'
assert_contains 'put 用法提示' "$ERR2" 'hb put <机器>'
# host_ssh_target 的关键契约：config 里没有的别名不能原样当 ssh Host 用
grep -q '^_ssh_conf_has_host()' hb
assert_rc '_ssh_conf_has_host 存在（避免拿 hosts 别名当 ssh 别名）' "$?" 0

section '加设备的分层方向（2026-11-16）'
# 事故①：没有上下文的 AI 从命令表里挑了字面最像「加设备」的 enroll，
#        拿到一条随本机名走的链接（desktop-sgl-4…），本机一改名就失效。
# 事故②：第一版修反了方向 —— 把 lend 说成"首选入口"，而代码里仍是 lend 调 enroll，
#        于是「能力层」里塞着整条业务流。正确方向：业务(enroll) 调 能力(lend) 调 原语。
_body() { sed -n "/^$1() {/,/^}/p" hb | sed 's/#.*//'; }
HELP3=$(./hb --help 2>&1)
ENROLL_LINE=$(printf '%s\n' "$HELP3" | grep -nE '^ +hb enroll( |$)' | head -1 | cut -d: -f1)
LEND_LINE=$(printf '%s\n' "$HELP3" | grep -nE '^ +hb lend( |$)' | head -1 | cut -d: -f1)
[ -n "$LEND_LINE" ] && [ -n "$ENROLL_LINE" ] && [ "$ENROLL_LINE" -lt "$LEND_LINE" ] \
  && ok 'help 里 enroll 在前（任务词优先）' \
  || bad "help 顺序不对（enroll=$ENROLL_LINE lend=$LEND_LINE）"
assert_contains 'enroll 说明写明了默认走 lend' "$HELP3" '默认经 hb lend 戴帽子'
assert_contains 'lend 说明自称能力层' "$HELP3" '能力层'
# 方向：业务 → 能力 → 原语，**不能反向**
_body cmd_enroll | grep -q 'cmd_lend' && ok 'enroll（业务）调用 lend（能力）' || bad 'enroll 没调 lend'
if _body cmd_lend | grep -q 'cmd_enroll'; then bad 'lend 还在调用 enroll（方向反了）'; else ok 'lend 不再调用 enroll（不再是能力调业务）'; fi
_body cmd_lend | grep -q '_dist_serve' && ok 'lend 调原语 _dist_serve' || bad 'lend 没调到原语'
_body cmd_enroll | grep -q '_dist_serve' && ok 'enroll --no-hub 才裸调原语' || bad 'enroll 缺 --no-hub 退路'
grep -q '\-\-no-hub' hb && ok '有 --no-hub 开关' || bad '没有 --no-hub'

section '自诊的判据不能自相矛盾（2026-11-16）'
# 事故：22 端口在听（sshd 明明在跑）却报「SSH 服务没在听」，
# 把「账号不对」指成「服务没起」，下一步该查什么屏幕上没说。
grep -q '22 端口在听 → 问题在认证' hb && ok '端口在听时指向认证问题' || bad '仍把认证失败说成服务没起'
grep -q '通，但 SSH 服务没在听' hb && bad '旧的自相矛盾文案还在' || ok '矛盾文案已移除（只剩解释性注释）'

section 'enroll 自测要能分辨"本机被劫持"（2026-11-16）'
# 事故：本机 DNS 把短链域名解析成 198.18.x（代理 fake-ip），自测必然 000，
# 却要白等 45 轮、最后报「取不到」，让人以为服务坏了。
grep -q '198.18\.\*|198.19\.\*' hb && ok '有 fake-ip 段的短路判据' || bad '没有 fake-ip 判据'
grep -q '_enroll_peer_code' hb && ok '能借别的节点代验' || bad '没有节点代验'

if [ $ONLINE -eq 1 ]; then
  section '联网用例（可选）'
  OUT=$(./hb minas 'id -u' 2>/dev/null); RC=$?
  assert_rc 'hb minas id -u 退出码' "$RC" 0
  assert_contains 'hb minas 返回 root' "$OUT" '0'
fi

printf '\n==== %d 通过 / %d 失败 ====\n' "$PASS" "$FAIL"
if [ $FAIL -gt 0 ]; then printf '失败项：%s\n' "${FAILED[*]}"; exit 1; fi
exit 0
