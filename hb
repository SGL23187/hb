#!/bin/bash
# hb —— 把「连上、修好、干活」收进一个文件
#
# 名字来历：AGENTS.md 是给人读的交接书，hb 是那份文档里每条命令的可执行版本。
# 两者一一对应：改文档就要改这里，不许只有一边。
#
# ══ 它解决什么 ══════════════════════════════════════════════════
# 远程开发环境最常见的三种坏法：
#   ① 机器换了个网络（NAT / 客户端隔离），ssh 不通，
#      而「修网络」本身又需要网络 —— 死锁
#   ② 新设备要接进来，手头没有任何现成安装包，也不想教人一堆手工步骤
#   ③ 排障全靠猜，报错指向错误的方向
# hb 的答案是：把判据写进命令里，让每条命令自己说「哪里坏了、下一步做什么」。
#
# ══ 设计口径（不是风格问题，是「能不能被 AI 用」的问题）══════════════
#   · 裸调用 = doctor，只读。想不起子命令时敲一下就有信息量
#   · 机器要读的用 JSON：hb list --json，字段稳定（ok/role/host/tailscale_ip/
#     netmap_nodes/checks{}/peers[]；本机用不上的检查项给 null，不是 false）
#   · 只用一个流表达失败：退出码非 0 = 有问题；stdout 是结果，诊断走 stderr
#   · 每个失败都自带「下一步」一行 —— 调用者没有本机上下文
#   · 端口探测一律用 port_open：MSYS(Git Bash) 没有 nc，
#     `nc -z ... 2>/dev/null` 会把「在监听」静默判成「未监听」
#   · ssh/scp 目标一律走 host_ssh_target：别名不等于 ssh Host
#
# ══ 它不做什么 ══════════════════════════════════════════════════
#   · 不内嵌密钥、凭据、authkey。身份来自你自己的 ~/.ssh 与 $HB_KEY_FILE
#   · 不代你登录 Tailscale（Windows 上交给官方客户端）
#   · 不在你不知道的时候改系统：写动作只有 ~/.ssh/config、~/.hb/、hosts 文件
#
# ══ 两边通用 ════════════════════════════════════════════════════
# 同一个文件在 Linux / macOS / Windows(Git Bash) 上行为一致，差别只在
# 二进制从哪来、ssh 要不要穿 SOCKS。平台判断只看 hb_is_msys / hb_is_windows。
#
# ══ 这不是「控制端 / 受控端」 ══════════════════════════════════════
# 它是对等的网格工具：任何一台在网的机器，用同一个 hb，都能调用网内任何
# 一台别的机器。谁都能当发起方，也谁都能被调。
#
# ══════ 全局量（一处定义，别在别处再写一遍）══════════════════════════
VER=${TS_VERSION:-1.104.4}
TS_CACHE="${HB_CACHE_DIR:-$HOME/.cache/hb}"
TS_VENDOR="${HB_VENDOR_DIR:-$HOME/.cache/hb/vendor}"

# 包名必须跟着架构走，不能写死 amd64。
# 写死的话，包能下、能解、能 install，然后每行 tailscale 命令报
# "cannot execute binary file" —— 报错点在 40 MB 下载之后，看起来像装好了但坏的。
case "$(uname -m 2>/dev/null)" in
  x86_64|amd64)   TS_ARCH=amd64 ;;
  aarch64|arm64)  TS_ARCH=arm64 ;;
  armv7l|armv6l)  TS_ARCH=arm ;;
  i386|i686)      TS_ARCH=x86 ;;
  *)              TS_ARCH=amd64 ;;
esac
TS_PKG="tailscale_${VER}_${TS_ARCH}.tgz"
STATE=/var/lib/tailscale/tailscaled.state
SOCK=/var/run/tailscale/tailscaled.sock
SOCKS=127.0.0.1:1055

# Windows 上 Git Bash 会把 --socket=/var/run/... 当成 MSYS 路径改写成
# D:/.../Git/var/run/...，于是永远连不上。Windows 客户端用默认命名管道，别给参数。
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) TS=(tailscale) ;;
  *)                    TS=(tailscale --socket="$SOCK") ;;
esac
LOG=/tmp/hb.log
# 数组不是字符串：字符串带参数再塞进 $() 会被重新分词，
# 顺手加个 2>/dev/null 甚至能把输出整段吞掉。

SELF=$(basename "$0")

# hb 自身位置（解析软链：/usr/local/bin/hb 指向仓库里的真身）
HB_SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
HB_HOME=$(CDPATH= cd -- "$(dirname -- "$HB_SELF")" 2>/dev/null && pwd)
# 本机状态目录（别名、帽子原名、公钥名单）。放 ~/.hb 而不是安装目录：
# 安装目录可能只读，状态得有个可写的地方。
HB_STATE_DIR="${HB_STATE_DIR:-$HOME/.hb}"

# ══════ 命令表（唯一来源）══════════════════════════════════════════════
# 帮助文本、子命令分发、重名检查都读这一张表。加一个命令只改这里一处。
# 格式：名字|处理函数|一句话
HB_CMDS=(
  "doctor|cmd_doctor|本机体检（裸调用 hb 就是它）"
  "list|cmd_list|设备总览：本机各关 + 网内每台，含离线多久（--json）"
  "up|cmd_up|一次修到底，幂等，随便重复跑"
  "run|cmd_run|远程执行：hb <机器> <命令...>"
  "hosts|cmd_hosts|别名一览 / add / rm（第一个是默认机器）"
  "put|cmd_put|传文件：hb put <机器> <本地> <远端>"
  "get|cmd_get|取文件：hb get <机器> <远端> <本地>"
  "enroll|cmd_enroll|加设备：默认经 hb lend 戴帽子（短链固定），--no-hub 不戴"
  "lend|cmd_lend|能力层：把自己临时变成分发服务器（hb enroll 默认调它）"
  "sync-keys|cmd_sync_keys|向在线节点同步公钥名单"
  "ts|cmd_ts|透传 tailscale 命令"
  "route|cmd_route|子网路由：ls 看谁在广播，approve 批准（需要 API token）"
  "vendor|cmd_vendor|把 tailscale 二进制归档到目录（离线自举用）"
  "help|show_help|这一页"
)
# 别名：名字|展开成的子命令（真子命令永远优先于同名的机器别名）
HB_ALIASES=(
  "status|ts status"
  "host|hosts"
)

say() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
die() { bad "$*"; exit 1; }

#
# ══════ 区 0.5 平台层：把"这台机器怎么说话"收在这一处 ══════
#
# 为什么要这一层：MSYS/编码/路径判断以前散在各函数里，同一个坑今晚犯了三次 ——
# Git Bash 把参数里的 "/" 改写成 "C:/Program Files/Git/"，导致
#   · 给 NAS 发 `GET / HTTP/1.1` 变成 `GET C:/... HTTP/1.1`，服务器回 400
#   · ssh 的远程命令里 `/data/docker/docker ps` 变成 Windows 路径
# 平台差异只允许有一处定义；后面加功能一律调这里的函数，不要再写 uname 判断。

hb_is_msys() { case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }
hb_is_windows() { [ "${OS:-}" = "Windows_NT" ] || hb_is_msys; }
hb_is_macos() { [ "$(uname -s 2>/dev/null)" = "Darwin" ]; }

# 主机名归一化：去掉域后缀（Windows 上是 COMPUTERNAME，Linux 可能是 FQDN）
hb_hostname() {
  local n
  n=$(hostname 2>/dev/null | tr -d '\r\n')
  [ -n "$n" ] || n=$(cat /etc/hostname 2>/dev/null | tr -d '\r\n')
  printf '%s' "${n%%.*}"
}

# 禁止 MSYS 改写参数与输出中的路径。
# hb 传的是"远程命令"和 URL，MSYS 的转换只会制造错误，没有任何一个调用点需要它。
# 注意：这必须在 hb 一开始就执行，子进程（ssh/scp/tailscale）才能继承。
if hb_is_msys; then
  export MSYS_NO_PATHCONV=1
  export MSYS2_ARG_CONV_EXCL='*'
fi

# 端口探针：**不要再用 `nc -z`**。
# MSYS（Git Bash）根本没装 nc，`nc -z ... 2>/dev/null` 会静默失败 —— 于是
# "端口在监听"被报成"未监听"。2026-11-14 现场咬到：hb proxy 假报未监听，
# 连带 1055 端口的几处检查全部假阴性，人差点去动 sgl 上的 Clash。
#
# 三级降级，全部零依赖：
#   ① bash 内建 /dev/tcp（我们的目标机都有 bash，最快）
#   ② nc -z（Linux 常见，MSYS 没有）
#   ③ python3（Yocto/NAS 这类只有 python 的环境）
# 用法：port_open <host> <port> [超时秒，默认 3]     0=通 1=不通
port_open() {
  local host=$1 port=$2 tmo=${3:-3}
  [ -n "$host" ] && [ -n "$port" ] || return 1
  # ① /dev/tcp：外再套 timeout，避免不可达地址把调用方挂死
  if timeout "$tmo" bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
    return 0
  fi
  # ② nc（只在真的存在时才用 —— 这就是当年那个 bug 的根源）
  if command -v nc >/dev/null 2>&1; then
    timeout "$tmo" nc -z "$host" "$port" 2>/dev/null && return 0
  fi
  # ③ python3
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$host" "$port" "$tmo" <<'PY' 2>/dev/null && return 0
import socket, sys
h, p, t = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
s = socket.socket()
s.settimeout(t)
try:
    sys.exit(0 if s.connect_ex((h, p)) == 0 else 1)
finally:
    s.close()
PY
  fi
  return 1
}

# ══════ 区 1 基础：网络与 TS 调用 ══════
#
net_up() {
  "${TS[@]}" status >/dev/null 2>&1 || return 1
  local _n; _n=$("${TS[@]}" status | tr -d '\r' | grep '^100\.' | wc -l | tr -d ' ')
  [ "${_n:-0}" -gt 1 ] || return 1
  # 1055 只在「本机自己走 SOCKS 出去」时才必须有。判据落在 ssh 配置上，
  # 不落在平台上 —— Windows 侧 ssh 直连 tailnet，config 里没有 ProxyCommand，
  # 本来就不该有 1055。旧写法硬卡 1055，于是 net_up 在 Windows 上恒为假：
  # 2026-11-03 在 sgl 实测，enroll 每次先白跑一遍 hb up，多花 60 秒，
  # 而网络其实一点问题没有（§8.4：别把「某台机器该不该做」写成判据）。
  if grep -qs -- "$SOCKS" "${HOME}/.ssh/config"; then
    port_open 127.0.0.1 1055 5 || return 1
  fi
  return 0
}

# 进程活着 ≠ 与协调服务器连着。
# 2026-11-03 实测：tailscaled 连续跑了两天，到 controlplane 的 TCP 早已死掉，
# netmap 停在「只有本机 1 个节点」，sgl / jetson27 全部不可达；而 ② 段只判
# pgrep，看见「已在运行」就跳过 —— 用户体感是「hb up 跑完了，还是连不上」。
# 判据必须落在后端自述上（BackendState + Health），不能落在进程存在性上。
ts_coord_ok() {
  local j
  j=$("${TS[@]}" status --json 2>/dev/null | tr -d '\r')
  [ -n "$j" ] || return 1
  # ⚠️ 必须用 herestring，不能 `printf '%s' "$j" | grep -q ...`：
  # grep -q 命中后立刻退出，上游 printf 正在写 38 KB 的 JSON，第二次 write
  # 就撞上已关闭的管道 → SIGPIPE → 141；set -o pipefail 把这个 141 当成
  # 整条管道的结果，于是**健康的机器被判成断连**。实测 rc=141 vs 0。
  # 症状还特别坏：doctor 恒报红、up 每次都无谓重启 tailscaled。
  grep -q '"BackendState": *"Running"' <<< "$j" || return 1
  grep -q 'Unable to connect to the Tailscale coordination server' <<< "$j" && return 1
  return 0
}

# ── 二进制：四级降级 ───────────────────────────────────────────────
is_windows() {
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac
  return 1
}

# ── tailscaled 的两种跑法：系统服务 / 用户态 ────────────────────────
#
# 沙箱只能用户态（没有 /dev/net/tun、没有 systemd），Jetson 这类真机该用系统
# 服务。两者的差别不是"干净不干净"，是**能不能被连进来**：
#   · 用户态（--tun=userspace-networking）：出站靠 SOCKS5 转发，入站没人监听
#     → 别人 ssh 不进这台，只能这台 ssh 别人。沙箱这样是对的。
#   · 系统服务（tun）：一张真的 tailscale0 网卡，双向通
#     → 这才是"一台能被管理的节点"，Jetson / yahboom 都该是这样。
# 所以判据是「这台机器上有没有 tun + systemd + root」，不是平台名字。
ts_system_mode() {
  is_windows && return 1
  [ "$(id -u 2>/dev/null)" = 0 ] || return 1
  [ -e /dev/net/tun ] || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  # 已有用户态 daemon 在跑就别再起一个：两个 daemon 抢 1055 是 sgl 上踩过的坑，
  # 症状是"服务看着好好的，但短链/SSH 全是 000"。
  pgrep -f 'tailscaled.*--tun=userspace' >/dev/null 2>&1 && return 1
  return 0
}

ensure_ts_system() {
  local _i _unit=""
  for _unit in /lib/systemd/system/tailscaled.service \
               /usr/lib/systemd/system/tailscaled.service \
               /etc/systemd/system/tailscaled.service; do
    [ -s "$_unit" ] && break
    _unit=""
  done
  if [ -z "$_unit" ]; then
    warn "没有 tailscaled.service → 用官方脚本装（systemd 版）"
    if curl -fsSL --max-time 150 https://tailscale.com/install.sh 2>/dev/null | sh \
         >/tmp/hb-ts-install.log 2>&1; then
      ok "官方安装脚本完成"
    else
      warn "官方脚本没成（日志 /tmp/hb-ts-install.log）→ 退回静态包 + 手写 unit"
      ensure_bin || return 1
      cat > /etc/systemd/system/tailscaled.service <<'UNIT'
[Unit]
Description=Tailscale node agent
After=network-pre.target
Wants=network-pre.target

[Service]
EnvironmentFile=-/etc/default/tailscaled
ExecStart=/usr/local/bin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock --port=41641
Restart=on-failure
RuntimeDirectory=tailscale
RuntimeDirectoryMode=0755
StateDirectory=tailscale
StateDirectoryMode=0700

[Install]
WantedBy=multi-user.target
UNIT
      systemctl daemon-reload >/dev/null 2>&1
    fi
  fi
  # 两套东西同时存在的后果：① 用静态包装了 /usr/local/bin/tailscale，
  # ② 官方脚本 deb 又装了 /usr/sbin/tailscaled + /usr/bin/tailscale，
  # 而 PATH 顺序决定你敲的 `tailscale` 到底是哪一个。版本一混，"能跑但状态诡异"
  # 就开始了 —— 2026-11-09 Jetson 上 ① 和 ② 是同一次 hb up 里先后发生的。
  # 不强行拆掉任何一套（官方 deb 有自己的 unit，拆了反而乱），只把事实说清楚。
  local _wl _wd
  _wl=$(command -v tailscale 2>/dev/null)
  _wd=$(systemctl show -p ExecStart tailscaled.service 2>/dev/null \
        | grep -o '/[^ ;]*tailscaled' | head -1)
  if [ -n "$_wl" ] && [ -n "$_wd" ] && [ "$(readlink -f "$_wl")" != "$(readlink -f "$_wd")" ]; then
    warn "命令行用的 tailscale 与服务用的 tailscaled 不是同一套"
    echo "      命令：$_wl  ($("$_wl" version 2>/dev/null | head -1))"
    echo "      服务：$_wd  ($("$_wd" version 2>/dev/null | head -1))"
    echo "    多数情况下能用（同主版本协议兼容），但排查问题时先确认版本一致。"
  fi
  mkdir -p /var/lib/tailscale /var/run/tailscale

  # ── 服务"起来了"和"能登录"是两件事 ──────────────────────────────
  # 2026-11-09 Jetson 实测：服务 Active: active (running)，但
  #   Status: "Needs login:"        ← 不是 failed，systemctl 不报错
  #   Switching ipn state NoState -> NeedsLogin (WantRunning=false)
  # 于是原来那句 `systemctl enable --now` 之后判 status 可读，会以为"服务好了"，
  # 接着 `tailscale up --authkey` 又被拒（key 已过期）→ 人只看到"系统服务起不来"，
  # 而日志里没有任何一行是错的。判据必须落在 login 状态上。
  systemctl enable tailscaled.service >/dev/null 2>&1
  systemctl restart tailscaled.service >/dev/null 2>&1
  for _i in $(seq 1 20); do
    "${TS[@]}" status >/dev/null 2>&1 && break
    sleep 1
  done

  local _ak _uplog
  if ensure_authkey; then
    _ak="$AUTHKEY_VALUE"
    # 显式写全所有非默认 flag：tailscaled 一旦存过 non-default 设置，
    # 少写一个就直接拒绝，报错是「requires mentioning all non-default flags」，
    # 看起来像鉴权失败，其实是参数没写全（与用户态那条同一个坑）。
    _uplog=$("${TS[@]}" up --authkey="$_ak" --hostname="$(hostname)" \
               --accept-routes --accept-dns=false 2>&1)
    if [ -n "$(tailscale_ip_of)" ]; then
      ok "系统服务已登录 $(tailscale_ip_of)（tun 模式，双向可达）"
      return 0
    fi
    bad "authkey 登录被拒 —— 服务本身是好的，是这把 key 不能用了"
    printf '%s\n' "$_uplog" | sed 's/^/    /' | head -8
    # 把 controlplane 的原话翻译成"下一步做什么"，别让人去猜 key 的三种失效方式：
    # 过期 / 一次性被用掉 / 被吊销 —— 三者处置完全不同，混成一句等于没说。
    case "$_uplog" in
      *"invalid key"*|*"not valid"*|*"invalid authkey"*)
        echo "    → 这把 key 已经不认了。两种可能："
        echo "       · 它是 one-off（单次）key，已经在别的机器上被用掉"
        echo "       · 它在控制台被 revoke 了"
        echo "      控制台能看到这把 key 的状态：https://login.tailscale.com/admin/settings/keys" ;;
      *expired*|*"too old"*)
        echo "    → 这把 key 过期了。控制台里看它的 Expiry，换一把新的或设 No expiry。" ;;
      *)
        echo "    → 上面是 controlplane 的原话。如果只是 Needs login，说明还没授权过。" ;;
    esac
    echo "    注意 systemctl 在这里会显示 active (running) + Needs login，那不是故障。"
    authkey_rotate_hint
    return 1
  fi

  # 没有可用 key：不是错，是需要人在前面点一下授权
  bad "没有可用的 authkey —— 这台机器需要交互登录一次"
  authkey_hint
  authkey_rotate_hint
  return 1
}

# ── 加密要防的是谁（2026-11-03 用户纠正，之前的判据方向错了）─────────
#
# 三条前提，按用户原话：
#   ① 这个 tailnet 里的所有机器都信任 —— 所以**可以保留明文**，不必防同机的人；
#   ② 保留明文本身没有安全价值，真正的理由是**能一把抓下来**：
#      私钥/凭据如果散落在 ~/.ssh、C:\Users\...，换台机器就得逐个去捞，还可能漏；
#      压进 hb 之后，"抓到 hb"就等于"抓到全部"；
#   ③ 唯一要防的是**短链厂商读我们的脚本内容** —— 传输链路经过别人，正文会被看。
#
# 所以加密的位置只有一处：**hb 自身的载荷**（内嵌的 base64 tar.gz）。
# 它不是"本机机密保护"，是"过路时别让人读到"。落地之后爱落明文就落明文。
#
# 之前判成「Windows 不落明文、只落 hb_key.enc」是把威胁模型搞错了：
# 那防的是"同机登录的别人"，而这类机器本来就在可信网络里、也都有登录权。
# 代价却是实打实的 —— 多一层解封、多一个"机器名一改就解不开"的坑。
#
# ══════ 区 2 自举：二进制从哪来、ssh 怎么穿出去 ══════
#
# 抽掉「内嵌载荷」之后的版本：hb 不再自带密钥与凭据。
# 身份来源改成三条明路，按顺序找：
#   ① $HB_KEY_FILE            显式指定（调试、临时换钥）
#   ② $HB_HOME/hb_key         放在 hb 旁边的那把
#   ③ ~/.ssh/$SSH_KEY_NAME    系统里的标准私钥
# 谁都没有就明说「缺私钥、怎么补」，不生成新钥 —— 新钥对方不认，
# 报出来的会是 Permission denied，看着像网络问题（这个坑踩过）。

ensure_bin() {
  # Windows 上 tailscaled 是系统服务，没有同名可执行文件，只认 tailscale.exe。
  # 装好的官方客户端比任何下载链都可靠。
  if is_windows; then
    if command -v tailscale >/dev/null 2>&1; then
      ok "二进制已就位 $(tailscale version 2>/dev/null | head -1)"
      return 0
    fi
    bad "未找到 tailscale.exe"
    echo "    装一个官方客户端即可：https://tailscale.com/download/windows"
    return 1
  fi

  if command -v tailscale >/dev/null && command -v tailscaled >/dev/null; then
    ok "二进制已就位 $(tailscale version 2>/dev/null | head -1)"
    return 0
  fi

  local pkg="" pkg_origin=""
  for cand in "$TS_CACHE/$TS_PKG" "$TS_VENDOR/$TS_PKG"; do
    [ -s "$cand" ] && { pkg="$cand"; pkg_origin="local"; ok "从本地取包: $cand"; break; }
  done

  if [ -z "$pkg" ]; then
    warn "本地无包，尝试上游下载（这一步需要网络）"
    mkdir -p "$TS_CACHE"
    if curl -fsSL --max-time 240 -o "$TS_CACHE/$TS_PKG" \
         "https://pkgs.tailscale.com/stable/$TS_PKG"; then
      pkg="$TS_CACHE/$TS_PKG"; pkg_origin="remote"; ok "上游下载成功"
    else
      bad "上游也取不到 —— 这台机器现在是断网状态"
      echo "    hb 装不下 39 MB 的二进制，所以这一层必须借助网络。出路按成本排序："
      echo "      1) 换一台有外网的环境重跑"
      echo "      2) 从任意能上网的机器下载后放到下面任一位置，再重跑 $SELF up："
      echo "           https://pkgs.tailscale.com/stable/$TS_PKG"
      echo "           $TS_VENDOR/$TS_PKG"
      echo "           $TS_CACHE/$TS_PKG"
      echo "    ⚠️ 别手动解压装到 /usr/local/bin —— 那会绕开校验，下次换机器还得重来。"
      return 1
    fi
  fi

  local tmp; tmp=$(mktemp -d)
  if ! tar -xzf "$pkg" -C "$tmp" 2>/dev/null; then
    bad "包损坏: $pkg"; rm -rf "$tmp"; return 1
  fi

  # ── SHA256 ────────────────────────────────────────────────────────
  # 校验依据必须跟着**包的来源**走，不能一律拿远端清单去否本地包。
  # 踩过：本地包的摘要是官方早先构建的，官方后来重打包，于是每次用本地包
  # 都被判不符 → 人只好手工装，错误被掩盖。根因不是包坏了，是拿别人的摘要
  # 验自己家的东西。现在按来源分治：
  #   本地包   → 只认包旁 <pkg>.sha256；没有就打印实测值后固化一份
  #   网络下载 → 必须对在线清单，不符即拒（这才是真正要防的场景）
  #   TS_SHA256 → 显式指定，永远最高优先级
  local want="" src_desc="" want_local="" src_local=""
  if [ -n "${TS_SHA256:-}" ]; then
    want="$TS_SHA256"; src_desc="环境变量 TS_SHA256"
  elif [ "$pkg_origin" = "remote" ]; then
    local fetched
    fetched=$(curl -fsSL --max-time 15 \
                "https://pkgs.tailscale.com/stable/$TS_PKG.sha256" 2>/dev/null \
              | awk '{print $1}' | head -1 | tr -d '\r')
    [ -n "$fetched" ] && { want="$fetched"; src_desc="官方在线清单"; }
  fi
  if [ -s "$pkg.sha256" ]; then
    want_local=$(awk '{print $1}' "$pkg.sha256" | head -1 | tr -d '\r')
    src_local="包旁 $(basename "$pkg").sha256"
    [ -z "$want" ] && { want="$want_local"; src_desc="$src_local"; }
  fi

  local got; got=$(sha256sum "$pkg" | cut -d' ' -f1)

  if [ -n "$want_local" ] && [ "$got" != "$want_local" ]; then
    bad "SHA256 不符，拒绝安装（文件本身坏了）"
    echo "     依据 $src_local"
    echo "     期望 $want_local"
    echo "     实际 $got"
    echo "     删掉它让 hb 重新下载： rm -f \"$pkg\" \"$pkg.sha256\""
    rm -rf "$tmp"; return 1
  fi

  if [ -n "$want" ]; then
    if [ "$got" != "$want" ]; then
      bad "SHA256 不符，拒绝安装"
      echo "     来源 $src_desc"
      echo "     期望 $want"
      echo "     实际 $got"
      echo "     ⚠️ 不要自己 curl 下载来绕过这一步 —— 装二进制的职责在 hb。"
      echo "        如果 hb 判错了，请改 hb 的判据，而不是绕开它。"
      rm -rf "$tmp"; return 1
    fi
    ok "SHA256 校验通过（依据：$src_desc）"
  else
    if [ "$pkg_origin" = "local" ]; then
      if { printf '%s  %s\n' "$got" "$TS_PKG" > "$pkg.sha256"; } 2>/dev/null; then
        ok "本地包放行，已记录摘要到 $(basename "$pkg").sha256"
      else
        warn "本地包放行（包旁 .sha256 不可写，摘要未固化）"
      fi
    else
      warn "取不到可信摘要（离线且无 .sha256），跳过校验"
      echo "     如需强校验：TS_SHA256=<摘要> $SELF up"
    fi
  fi

  local src; src=$(find "$tmp" -maxdepth 2 -name tailscaled -type f | head -1)
  [ -n "$src" ] || { bad "包内找不到 tailscaled"; rm -rf "$tmp"; return 1; }
  src=$(dirname "$src")
  install -m 755 "$src/tailscale"  /usr/local/bin/tailscale
  install -m 755 "$src/tailscaled" /usr/local/bin/tailscaled
  rm -rf "$tmp"
  ok "已安装 $(tailscale version 2>/dev/null | head -1)"
}

# ── 用什么把 TCP 送进 tailnet ─────────────────────────────────────
#
# 用户态 tailscaled（没有 TUN）时，100.x 不在任何网卡上，裸 TCP 没路由，必须绕。
# 两条路差别很大：
#   nc -X 5 -x 127.0.0.1:1055   SOCKS5。能用，但要等 DERP 建链，首包 20~60 秒，
#                               ssh 的 ConnectTimeout 一到就判死；而同时 `nc -z`
#                               又显示端口通 —— 自相矛盾。
#   tailscale nc <ip> <port>    让 tailscaled 自己连。同样走 DERP，但握手里有
#                               它自己的重试与选路，实测 3 秒内出 banner。
# 判据落在「这个二进制支不支持 nc 子命令」，不落在平台名字上。
SSH_PROXY_CMD=""
ssh_proxy_cmd() {
  [ -n "$SSH_PROXY_CMD" ] && { printf '%s' "$SSH_PROXY_CMD"; return 0; }
  if "${TS[@]}" nc --help >/dev/null 2>&1 || "${TS[@]}" nc 2>&1 | grep -qi 'usage'; then
    SSH_PROXY_CMD="${TS[*]} nc %h %p"
  else
    SSH_PROXY_CMD="nc -X 5 -x $SOCKS %h %p"
  fi
  printf '%s' "$SSH_PROXY_CMD"
}

# 私钥在哪：三条明路，找到即用。都没有就返回 1（调用方负责说怎么补）。
hb_key_path() {
  local k
  [ -n "${HB_KEY_FILE:-}" ] && [ -s "$HB_KEY_FILE" ] && { printf '%s' "$HB_KEY_FILE"; return 0; }
  for k in "$HB_HOME/hb_key" "$HB_STATE_DIR/hb_key" "$SSH_DIR/${SSH_KEY_NAME:-id_ed25519}"; do
    [ -n "$k" ] && [ -s "$k" ] && { printf '%s' "$k"; return 0; }
  done
  return 1
}
# ══════ 区 3 SSH 身份与主机别名 ══════
#
ensure_ssh_conf() {
  mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"
  [ -s "$SSH_DIR/config" ] && return 0
  # 公开版没有「预设主机列表」：别名由 hb hosts add 维护，ssh 目标走 host_ssh_target。
  # 硬生成一份带 IP 的 config 只会在别人机器上制造垃圾条目。
  [ -n "$SSH_TARGETS" ] || {
    warn "没有预设主机（SSH_TARGETS 为空）—— 跳过生成 ~/.ssh/config"
    echo "    要加主机：$SELF hosts add <名字> <IP> [user=<账号>]"
    return 0; }
  local IFS=':' t ip
  set -- $SSH_TARGETS
  while [ $# -ge 2 ]; do
    t="$1"; ip="$2"; shift 2
    {
      echo "Host $t"
      echo "    HostName $ip"
      echo "    User ${t%%[0-9]*}"
      echo "    IdentityFile $SSH_DIR/$SSH_KEY_NAME"
      # 穿隧道只在"本机是 Linux 沙箱"时成立：Windows 侧没有 1055，
      # 那边的连接是直连 tailnet 的。写死 ProxyCommand 会让 Windows 上全超时。
      is_windows || echo "    ProxyCommand $(ssh_proxy_cmd)"
      echo "    ServerAliveInterval 15"
      echo "    StrictHostKeyChecking accept-new"
      echo
    } >> "$SSH_DIR/config"
  done
  chmod 600 "$SSH_DIR/config"
  ok "~/.ssh/config 已生成"
  return 0
}

# ══ 入站授权：让别的节点能 ssh 进这台 ══════════════════════════════
#
# 出站和入站是两件事，之前只做了一半。hb 每台机器都落了同一把私钥，
# 但**没有哪一步把它们互相加进 authorized_keys** —— 于是：
#   · A ssh B 成功，只因为 B 上恰好有人手工加过
#   · 新机器 C 上来，谁也连不进去，而 hb 自己诊断成"网络不通"
# Jetson 实测就是这个：端口通、banner 出来、四五个账号全 Permission denied。
#
# 集中式（所有人写一个 sgl 的 authorized_keys）不行：sgl 一关，全网失联，
# 而且每加一台机器都要去改那台。改成**每台机器各自持有一份"谁可以进来"**，
# 名单靠 hb 自己传播（见 hb sync-keys）：
#   · 戴帽子那台 = 分发者：注册时它在，新机器缺什么它就给
#   · 其他在线的 = 同步源：不在线的机器开机后从它们那里补齐
# 名单就是各机的 id_ed25519.pub，判据是内容（同一条公钥只进一次），不是文件名。
AUTHKEYS_FILE="$SSH_DIR/authorized_keys"
HB_PUBKEYS_DIR="$HB_STATE_DIR/pubkeys"

ensure_authorized() {
  mkdir -p "$SSH_DIR" "$HB_PUBKEYS_DIR"; chmod 700 "$SSH_DIR"
  local pub="$SSH_DIR/$SSH_KEY_NAME.pub" mine n_add=0 k
  [ -s "$pub" ] || ssh-keygen -y -f "$SSH_DIR/$SSH_KEY_NAME" > "$pub" 2>/dev/null || {
    bad "推不出本机公钥，入站授权跳过"; return 1; }
  chmod 644 "$pub"
  # 本机公钥也进名单：自己 ssh 自己、以及把名单传给别人的时候都要完整
  cp "$pub" "$HB_PUBKEYS_DIR/$(hostname).pub" 2>/dev/null || true

  touch "$AUTHKEYS_FILE"; chmod 600 "$AUTHKEYS_FILE"
  # 先并入 $HB_PUBKEYS_DIR 里所有已知公钥（同步来的、别的机器给的）
  for k in "$HB_PUBKEYS_DIR"/*.pub; do
    [ -s "$k" ] || continue
    _authkeys_merge "$k" && n_add=$((n_add+1))
  done
  # 再并本机自己的
  _authkeys_merge "$pub" && n_add=$((n_add+1))
  if [ "$n_add" -gt 0 ]; then ok "入站授权：新增 $n_add 把公钥（共 $(grep -c '^ssh-\|^ecdsa-' "$AUTHKEYS_FILE" 2>/dev/null || echo 0) 把）"
  else ok "入站授权：已有 $(grep -c '^ssh-\|^ecdsa-' "$AUTHKEYS_FILE" 2>/dev/null || echo 0) 把公钥"
  fi
  return 0
}

# 按"公钥主体"去重，不按整行 —— 同一把钥换个注释就是另一行了。
# awk 而不是 grep -F：grep 的退出码在这里会被 set -o pipefail 放大成误判。
_authkeys_merge() {
  local src=$1 body
  body=$(awk '{print $1" "$2}' "$src" 2>/dev/null | head -1)
  [ -n "$body" ] || return 1
  awk -v b="$body" '{l=$1" "$2; if (l==b) f=1} END{exit !f}' "$AUTHKEYS_FILE" && return 1
  cat "$src" >> "$AUTHKEYS_FILE"
  return 0
}

ensure_ssh() {
  mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"

  # ① 私钥：已有 → 任一来源恢复 → 报错（不生成新的，新钥 sgl 不认）
  local key="$SSH_DIR/$SSH_KEY_NAME" src
  if [ ! -s "$key" ]; then
    if src=$(hb_key_path); then
      install -m 600 "$src" "$key"
      ok "私钥已恢复（$src）"
    else
      bad "缺私钥 $key"
      echo "    hb 不自带密钥，身份得由你提供。按顺序找过这些位置，都没有："
      echo "      \$HB_KEY_FILE（当前：${HB_KEY_FILE:-未设置}）"
      echo "      $HB_HOME/hb_key"
      echo "      $HB_STATE_DIR/hb_key"
      echo "      $SSH_DIR/$SSH_KEY_NAME"
      echo "    处置（任选其一）："
      echo "      ssh-keygen -t ed25519 -f $SSH_DIR/$SSH_KEY_NAME     # 新机器用这个"
      echo "      或把已有私钥放进来：install -m 600 <你的私钥> $HB_HOME/hb_key"
      echo "      ⚠️ 别在对方没授权这把钥之前就断言"网络不通" —— 报错会指向错误方向。"
      return 1
    fi
  fi
  chmod 600 "$key"
  # 公钥：能推就推出来，省得单独维护
  if [ ! -s "$key.pub" ]; then
    ssh-keygen -y -f "$key" > "$key.pub" 2>/dev/null && chmod 644 "$key.pub"
  fi

  # ② config：按标准模板生成（幂等——已有就不动，避免覆盖人工配置）
  if [ ! -s "$SSH_DIR/config" ]; then
    ensure_ssh_conf || return 1
  else
    ok "~/.ssh/config 已存在，保持不动"
  fi
  # 注意：这里**不**清理 $HB_HOME 里那份明文。它本来就是留着的，
  # 私钥进 ~/.ssh 只是"又抄了一份到标准位置"，不是"搬走"。
  ensure_authorized || warn "入站授权没做完 —— 别的节点 ssh 进不来"
  return 0
}


# ══ 子命令表：唯一的"哪些词已经被占"的真相 ══════════════════════════
# 为什么要有一张表，而不是散在 case 里：机器别名必须**不能落在**这些词上
# （否则 `hb sgl "ls"` 与 `hb status` 谁优先就成了运气问题）。
# 表里加一个词，别名那边自动就避让了 —— 这是它们唯一的耦合点。
HB_SUBCMDS="list status doctor up run ts vendor sync-keys hosts enroll lend route put get help"

# 别名文件：本机私有，不进 git、不进载荷。一行 `sgl 100.113.237.37`
# 第一行是默认主机（hb sgl "..." 里的 sgl 就到它）。
HOSTS_FILE="${HB_HOSTS_FILE:-$HB_STATE_DIR/hosts}"

# 一个名字能不能安全地当机器别名：
#   ① 不能与已有子命令同名 —— 否则 `hb X` 到底是"跑 X 子命令"还是"连 X 机器"，
#      取决于 case 的顺序，而顺序是会被别人改的；
#   ② 不能带空白/引号（`hb my pc "ls"` 会被拆成两个参数）；
#   ③ 不能以 - 开头（会被当成选项）。
alias_usable() {
  local n=$1 w
  case "$n" in
    ""|-*|*[[:space:]]*|*[\"\'\`\$\;\&\|\<\>\(\)]) return 1 ;;
  esac
  for w in $HB_SUBCMDS; do
    [ "$n" = "$w" ] && return 1
  done
  return 0
}

hosts_all() {
  [ -s "$HOSTS_FILE" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$HOSTS_FILE" 2>/dev/null
}

# 别名 → 目标（IP 或 ~/.ssh/config 里的 Host）。没有这个别名就原样返回。
hosts_resolve() {
  local n=$1 hit
  hit=$(hosts_all | awk -v n="$n" '$1==n{print $2; exit}')
  printf '%s' "${hit:-$n}"
}

# 别名里显式写的账号（`sgl 100.113.237.37 user=sgl` 的第三段）
hosts_user() {
  hosts_all | awk -v n="$1" '$1==n{for(i=3;i<=NF;i++) if ($i ~ /^user=/) { sub(/^user=/,"",$i); print $i; exit }}'
}

# 一个 IP 该怎么登：先看 config 里 HostName 匹配的那条，再看 sgl 约定
_ssh_user_for() {
  local ip=$1 u=""
  # 逐行：进入 Host 块后看 HostName 是否等于 ip，是就记下这个块里的 User，
  # 下一个 Host 就离开块。用整段扫而不是 END 里判一次 —— 多个块时
  # 哪块是"最后一块"由文件顺序决定，而顺序该由 IP 决定。
  u=$(awk -v ip="$ip" '
    tolower($1)=="host"      { next }
    tolower($1)=="hostname"  { matchip = ($2==ip) ; next }
    tolower($1)=="user" && matchip { u=$2; matchip=0; next }
    END { print u }' "$SSH_DIR/config" 2>/dev/null)
  printf '%s' "${u:-${USER:-root}}"
}

cmd_hosts() {
  local sub=${1:-}
  case "$sub" in
    add)
      local name=$2 target=$3
      # 把后面几段一并收进 target：`hosts add ubuntu 100.88.99.106 user=root`
      # 的 user=root 是第 4 个参数，只取 $3 等于直接把它丢了 ——
      # 打印"登录账号：sgl"时人会以为自己看错，其实是根本没读到 root。
      if [ $# -gt 3 ]; then
        shift 2
        target="$*"
      fi
      if [ -z "$name" ] || [ -z "$target" ]; then
        bad "用法：$SELF hosts add <名字> <IP|ssh别名>"; return 2
      fi
      if ! alias_usable "$name"; then
        bad "「$name」不能用作机器别名"
        case " $HB_SUBCMDS " in *" $name "*) echo "    它已经是子命令。换一个名字，例如 sgl2 / sglbox。";; esac
        echo "    规则：不与子命令重名、不含空白或引号、不以 - 开头。"
        return 2
      fi
      # 目标也不能是子命令：`hb hosts add nas list` 会把 list 解析成"连 list 这台机"
      if ! alias_usable "$target" && ! printf '%s' "$target" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
        case " $HB_SUBCMDS " in *" $target "*) bad "目标「$target」是子命令，不像机器"; return 2 ;; esac
      fi
      # 把"该怎么登"一并记下来：别名只是想换个叫法，不该改掉账号。
      # 不记的话，hb 只能从名字前缀猜（esxi8 → esxi），猜错报的是
      # "Permission denied"，看着像密钥没授权。
      #
      # 2026-11-09 实测：`hb hosts add ubuntu 100.88.99.106 user=root` 打印了
      # "登录账号：root"，落盘的却是 `100.88.99.106 user=sgl` —— 因为 user=
      # 是在这条 IP 判据之后才被看的，此处重写了一遍 target，把人家写的参数吃掉，
      # 然后拿 _ssh_user_for 的兜底值 sgl 顶上去。现在先解析 user=，再补默认。
      local ip="${target%% *}" own_user=""
      case " $target " in *" user="*) own_user="${target#*user=}"; own_user="${own_user%% *}" ;; esac
      if printf '%s' "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        if [ -n "$own_user" ]; then
          target="$ip user=$own_user"
          ok "登录账号：$own_user（按你指定的）"
        else
          target="$ip user=$(_ssh_user_for "$ip")"
          ok "登录账号：${target##*user=}（可用 $SELF hosts add $name <IP> user=<账号> 指定）"
        fi
      fi
      mkdir -p "$(dirname "$HOSTS_FILE")"
      touch "$HOSTS_FILE"
      if hosts_all | awk -v n="$name" '$1==n{f=1} END{exit !f}'; then
        # 改指向而不是再插一行：同一个名字两行，取哪行取决于 awk 的第一次命中，
        # 而"第一次命中"是上次留下的事实，不是这次的意思。
        local tmp; tmp=$(mktemp)
        awk -v n="$name" -v t="$target" '$1==n{print n" "t; next} {print}' "$HOSTS_FILE" > "$tmp"
        cat "$tmp" > "$HOSTS_FILE"; rm -f "$tmp"
        ok "$name → $target（已更新）"
      else
        printf '%s %s\n' "$name" "$target" >> "$HOSTS_FILE"
        ok "$name → $target（已添加）"
      fi
      # 顺手把 ssh 别名补上：只有加了这句，hb ssh <name> 才不需要再问端口和密钥。
      # 目标本身就是 IP 才补；目标是已有 ssh Host 的话，ssh 自己会认。
      if printf '%s' "$target" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        ssh_alias_ensure "$name" "$target" >/dev/null 2>&1 || true
      fi
      ;;
    rm|del)
      local name=$2
      [ -z "$name" ] && { bad "用法：$SELF hosts rm <名字>"; return 2; }
      if ! hosts_all | awk -v n="$name" '$1==n{f=1} END{exit !f}'; then
        bad "没有这个别名：$name"; return 1
      fi
      local tmp; tmp=$(mktemp)
      awk -v n="$name" '$1!=n' "$HOSTS_FILE" > "$tmp"
      cat "$tmp" > "$HOSTS_FILE"; rm -f "$tmp"
      ok "已删除 $name（~/.ssh/config 里的同名 Host 没动，需要时手删）"
      ;;
    ""|list)
      if [ ! -s "$HOSTS_FILE" ]; then
        echo "  （没有机器别名。加一个：$SELF hosts add sgl 100.113.237.37）"
        echo "  没有别名时，hb 也会认 ~/.ssh/config 里的 Host 和网内的节点名。"
        return 0
      fi
      local first=1 n t note
      say "机器别名  $HOSTS_FILE"
      while read -r n t; do
        [ -z "$n" ] && continue
        note=""
        [ $first -eq 1 ] && { note="  ← 默认（$SELF sgl 等同于 $SELF $n）"; first=0; }
        if ! alias_usable "$n"; then note="$note  ✗ 与子命令重名，会被忽略"; fi
        printf '  %-10s → %-16s%s\n' "$n" "$t" "$note"
      done <<< "$(hosts_all)"
      ;;
    *)
      bad "用法：$SELF hosts [list|add <名字> <地址>|rm <名字>]"; return 2 ;;
  esac
}

# 调过一次就记住它。规则只有一条：**同名不覆盖、默认位只有一次**。
# 第一台调到的机器记为 sgl（`hb sgl "…"` 的默认指向），之后各自用节点名。
hosts_remember() {
  local n=$1 ip=$2
  [ -z "$n" ] || [ -z "$ip" ] && return 0
  # 名字是 IP、或与子命令重名，就别往别名表里塞
  printf '%s' "$n" | grep -qE '^[0-9]+\.' && return 0
  alias_usable "$n" || return 0
  mkdir -p "$(dirname "$HOSTS_FILE")" 2>/dev/null
  # 已经有这个指向就不动
  hosts_all | awk -v n="$n" '$1==n{f=1} END{exit !f}' && return 0
  # 同 IP 已有别名也不重复记
  hosts_all | awk -v ip="$ip" '{for(i=2;i<=NF;i++) if($i==ip) f=1} END{exit !f}' && return 0
  local first=""
  first=$(hosts_all | head -1 | awk '{print $1}')
  if [ -z "$first" ] && ! hosts_all | awk '$1=="sgl"{f=1} END{exit !f}'; then
    printf 'sgl %s user=%s\n' "$ip" "$(_ssh_user_for "$ip")" >> "$HOSTS_FILE"
    printf '  \033[2m# 记住了这台：以后 hb sgl "…" 就指它（要改指向：hb hosts add sgl <IP>）\033[0m\n' >&2
  else
    printf '%s %s user=%s\n' "$n" "$ip" "$(_ssh_user_for "$ip")" >> "$HOSTS_FILE"
    printf '  \033[2m# 记住了这台：hb %s "…"\033[0m\n' "$n" >&2
  fi
  return 0
}

# 给某台机器补一条 ssh Host（幂等；已有同名 Host 就不动）
ssh_alias_ensure() {
  local n=$1 ip=$2 cfg="$SSH_DIR/config"
  [ -s "$cfg" ] || return 0
  grep -qiE "^[[:space:]]*Host[[:space:]]+.*\b$n\b" "$cfg" && return 0
  {
    echo
    echo "Host $n"
    echo "    HostName $ip"
    echo "    IdentityFile $SSH_DIR/$SSH_KEY_NAME"
    is_windows || echo "    ProxyCommand $(ssh_proxy_cmd)"
    echo "    ServerAliveInterval 15"
    echo "    StrictHostKeyChecking accept-new"
  } >> "$cfg"
}

# ── authkey 逐级降级 ───────────────────────────────────────────────
# 判据与 hb_key 完全一致：**先认「自己旁边」**。
# 理由：网盘 00_环境恢复/ 里 hb、hb_key、credentials 就是并排放的，
# 一起下到同一个目录是最自然的动作。旧版这里只查两个约定目录，
# 于是出现了荒谬局面 —— hb 认得出旁边的私钥，却认不出旁边的 authkey，
# 报「无 authkey」，逼人去读源码找第三级路径、再手工把文件挪到 vendor/。
# 那是 hb 该自己做的事，不该变成文档里的一个操作步骤。
#
# 候选文件名按「网盘上实际叫什么」列全：那个文件历史上叫过 credentials.tmp。
authkey_candidates() {
  printf '%s\n' \
    "$HB_STATE_DIR/credentials.json" \
    "$HB_HOME/credentials.json" \
    "$HB_STATE_DIR/authkey" \
    "$TS_VENDOR/credentials.json"
}

# 从一个文件里取 authkey：JSON 优先，抓不到就正则兜底（纯文本也能用）
read_authkey_file() {
  local f=$1 v=""
  if [ -s "$f" ] && head -c 1 "$f" 2>/dev/null | grep -q '{'; then
    v=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("authkey",""))' "$f" 2>/dev/null)
  fi
  [ -z "$v" ] && v=$(grep -oE 'tskey-[A-Za-z0-9_-]+' "$f" 2>/dev/null | head -1)
  printf '%s' "$v"
}

ensure_authkey() {
  local persist=0 k="" c v
  [ "${1:-}" = "--persist" ] && persist=1

  [ -n "${TAILSCALE_AUTHKEY:-}" ] && k="$TAILSCALE_AUTHKEY"
  [ -z "$k" ] && [ -s "$HOME/.config/tailscale/authkey" ] && \
    k=$(tr -d '\n' < "$HOME/.config/tailscale/authkey")

  if [ -z "$k" ]; then
    while IFS= read -r c; do
      [ -s "$c" ] || continue
      v=$(read_authkey_file "$c")
      [ -n "$v" ] && { k="$v"; AUTHKEY_FROM="$c"; break; }
    done <<EOF
$(authkey_candidates)
EOF
  fi

  # 固化：命中一次就写进标准位置，下次直接读，不再逐级找。
  # 只在 hb up 里做 —— doctor 是只读的，不能顺手改磁盘。
  if [ $persist -eq 1 ] && [ -n "$k" ]; then
    if [ ! -s "$HOME/.config/tailscale/authkey" ]; then
      mkdir -p "$HOME/.config/tailscale"
      printf '%s\n' "$k" > "$HOME/.config/tailscale/authkey"
      chmod 600 "$HOME/.config/tailscale/authkey"
      [ -n "${AUTHKEY_FROM:-}" ] && \
        printf '  \033[32m✓\033[0m authkey 取自 %s（已固化到 ~/.config/tailscale/authkey）\n' "$AUTHKEY_FROM" >&2
    fi
  fi
  # 结果通过全局变量回传，而不是 printf 到 stdout ——
  # 否则命令替换会把调用方困在子 shell 里，AUTHKEY_FROM 传不出来，
  # 「这个 key 是从哪找到的」就永远说不清（排查时最想知道的就是这句）。
  AUTHKEY_VALUE="$k"
  [ -n "$k" ]
}

# 找不到时，把「找过哪些地方、该把文件放哪」一次说清，别让人去翻源码
authkey_hint() {
  echo "     按顺序找过："
  echo "       \$TAILSCALE_AUTHKEY"
  echo "       ~/.config/tailscale/authkey"
  echo "       $HB_STATE_DIR/credentials.json（内容：{\"authkey\":\"tskey-auth-…\"}）"
  echo "       $HB_HOME/credentials.json"
  echo "       $HB_STATE_DIR/authkey"
  echo "     公开版不带任何凭据 —— 这一步必须由你提供。"
  echo "     最快的一条：echo '{\"authkey\":\"tskey-auth-你的\"}' > $HB_STATE_DIR/credentials.json"
}

# 本机 tailnet IP（没有就输出空）。系统服务与用户态都用 tailscale ip -4。
tailscale_ip_of() {
  "${TS[@]}" ip -4 2>/dev/null | tr -d '\r' | head -1
}

# ── authkey 过期之后怎么办 ────────────────────────────────────────
# 这不是"再试一次"能解决的问题：tskey-auth-* 是有有效期的（默认 90 天），
# 过期/被吊销之后，任何拿到旧 hb 的机器都会卡在同一处。
# 所以给两条路，按"要不要登录账号"分开：
#   A. 交互授权（不需要任何 key，人点一下浏览器）—— 推荐，一次性
#   B. 换一把新 key（要进 admin 控制台），适合批量/无人值守
authkey_rotate_hint() {
  echo
  echo "    两条路，选一条："
  echo "    A) 交互登录（最快，不用 key，浏览器点一下）："
  echo "         sudo tailscale up --hostname=$(hostname)"
  echo "       它会给一个 https://login.tailscale.com/a/xxxx 链接，"
  echo "       在浏览器里用同一个 tailnet 账号确认即可，之后这台就留在网内。"
  echo
  echo "    B) 换一把新 key（以后别的机器也能用）："
  echo "         https://login.tailscale.com/admin/settings/keys → Generate auth key"
  echo "       勾 Reusable、关掉过期（或设长一点），然后把新 key 交给 hb："
  echo "         sudo TAILSCALE_AUTHKEY=tskey-auth-xxxxx /tmp/hb up"
  echo "       想让它变成内置的（下次发的短链就带新 key）："
  echo "         在能做 hb pack 的机器上更新 credentials.json 后 hb pack，再回传网盘"
}

# ── 主流程 ─────────────────────────────────────────────────────────
# 沙箱的 git 到底读不读 ~/.git-credentials —— 一次真问题换来的判据。
# 现象：hb up ⑦ 说「git 凭据 ✓ 已从 sgl 取回」，文件 69 字节、内容正确，
# 但 git clone 私有仓库照样要账号（could not read Username），
# 因为系统级 credential.helper 指着一个自带的 helper，store 排不上。
# 这是本环境那类「看起来正常、实际在说谎」的典型，所以判据必须落在**行为**上：
# 问 git 自己"你会用什么取凭据"，而不是看文件在不在。
# 真正的判据：让 git 自己把凭据吐出来一次。
# `git config --get-all credential.helper` 说"有 store"，不等于"store 能找到文件"：
# 实测两次 ——
#   ① helper 顺序对、文件也在（600），但当前工作目录不在任何仓库里，
#      git 改读了别的配置，返回的凭据是**空的**；
#   ② 在仓库里就正常。
# 所以判据不能只看配置，要让 git 走一遍。走不通就退回读文件：
# 那个文件就在固定位置，读得到就是读得到。
_git_sees_credential() {
  local out
  out=$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null)
  case "$out" in *"username="*) return 0 ;; esac
  # 退路：直接看文件里有没有 hosts 匹配的那一行（凭据格式 `https://user:token@host`）
  [ -s "$HOME/.git-credentials" ] || return 1
  grep -q "github.com" "$HOME/.git-credentials" 2>/dev/null
}

# helper 列表里**有没有** store —— 不是"第一行是不是 store"。
# 曾经要求"排第一"，结果在 Windows 上永远为假：系统级 gitconfig 的 `manager`
# 排在用户级 `store` 前面，而实际生效时 manager 会自己认输（README 里也写了这一点）。
# 判据要问「会不会用到 store」，不是「它排第几」。
git_reads_store() {
  local hs
  hs=$(git config --get-all credential.helper 2>/dev/null | tr -d '\r')
  # 空 = 用默认（默认就是 store）
  [ -z "$hs" ] && return 0
  grep -qxE 'store|!?(\S*/)?git-credential-store' <<< "$hs"
}

# 把 store 排到第一位，原 helper 原样保留在后。
# 不改系统级、不动 helper 本体 —— 只改顺序，最小侵入、可回退。
ensure_cred_helper() {
  git_reads_store && { ok "git credential.helper 已能用 store"; return 0; }
  local cur new
  cur=$(git config --global --get-all credential.helper 2>/dev/null | tr -d '\r')
  # --global 里没有就取生效值（可能来自 system），合并成一条 global 列表
  [ -z "$cur" ] && cur=$(git config --show-origin --get-all credential.helper 2>/dev/null | sed 's/^[^:]*:[^:]*:[[:space:]]*//')
  # 先把 global 里现有的全部清掉再按新顺序写回。
  # `--replace-all` 只替换**第一处**，原来若有两行（manager / store），
  # 结果就是 `store / store` —— 看着对了，实际把 manager 丢了。
  git config --global --unset-all credential.helper >/dev/null 2>&1
  git config --global --add credential.helper store
  if [ -n "$cur" ]; then
    printf '%s\n' "$cur" | grep -vE '^!?(\S*/)?git-credential-store$|^store$' | awk '!s[$0]++' |
    while IFS= read -r l; do
      [ -n "$l" ] && git config --global --add credential.helper "$l"
    done
  fi
  if git_reads_store; then
    ok "已把 store 排到 credential.helper 第一位（原有 helper 保留在后）"
    return 0
  fi

  # 仍读不到：Windows 上系统级 gitconfig 常把 manager 排在最前，
  # 而 `--global` 在 HOME 被 MSYS 改写时甚至读不到用户级配置。
  # 宁可在这个仓库里**明确指定** store —— 本地配置文件，不污染全局，可回退。
  if git config --get-all credential.helper 2>/dev/null | head -1 | grep -vqE '^!?(\S*/)?git-credential-store$|^store$'; then
    if ( cd "$HB_HOME" 2>/dev/null || cd "$HOME"; git config --local --replace-all credential.helper store ) 2>/dev/null; then
      warn "系统级 helper 排在 store 前面，已在 $HB_HOME/.git 里本地覆盖为 store"
      return 0
    fi
  fi
  bad "改不动 credential.helper —— 检查 git config --show-origin 的写入权限"
  echo "    手工等价：git config --local credential.helper store（在该仓库目录里执行）"
  return 2
}

#

# ssh config 里是否真有这个 Host（`ssh <名字>` 能直接用的前提）。
# 注意别用 alias_usable 代替：那个函数只校验"名字字符串合法"，
# 对 `minas` 这种只在 hosts 文件里存在、config 里没有的名字也会返回真，
# 于是 scp 会发给一个不存在的 ssh 别名，报 `Connection closed`（2026-11-14 咬到）。
_ssh_conf_has_host() {
  awk -v n="$1" '
    tolower($1)=="host" { for (i=2; i<=NF; i++) if ($i==n) f=1 }
    END { exit(f?0:1) }' "$SSH_DIR/config" 2>/dev/null
}

# 一个别名该怎么登：config 里有 Host 就用名字（端口/密钥都齐），
# 否则解析 hosts 文件 → user@ip，由调用方显式带 -i。
host_ssh_target() {
  local n=$1 t u
  _ssh_conf_has_host "$n" && { printf '%s' "$n"; return 0; }
  t=$(hosts_resolve "$n")
  if printf '%s' "$t" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    u=$(hosts_user "$n")
    [ -n "$u" ] || u=$(_ssh_user_for "$t")
    printf '%s@%s' "$u" "$t"
    return 0
  fi
  return 1
}

# ── 传文件：hb 缺的一环 ────────────────────────────────────────────
# 以前传文件只能手搓 scp，还得自己记得 MSYS_NO_PATHCONV（否则远端绝对路径会被
# 改写成 Windows 路径）。于是"访问设备一律走 hb"这条约定在这件事上永远是空的。
# 现在 put/get 直接把"别名解析 + 密钥 + 路径改写防护"收进来。
cmd_put() {
  local host=${1:-} l=${2:-} r=${3:-} tgt
  [ -n "$host" ] && [ -n "$l" ] && [ -n "$r" ] || die "用法：$SELF put <机器> <本地文件> <远端路径>"
  [ -e "$l" ] || die "本地不存在：$l"
  tgt=$(host_ssh_target "$host") || die "不认识「$host」（$SELF hosts 看别名）"
  if scp -q -i "$SSH_DIR/$SSH_KEY_NAME" -o BatchMode=yes "$l" "$tgt:$r"; then
    ok "已上传  $l  →  $host:$r"
  else
    die "scp 失败 —— 确认 $host 可达（$SELF $host true）且远端目录可写"
  fi
}

cmd_get() {
  local host=${1:-} r=${2:-} l=${3:-} tgt
  [ -n "$host" ] && [ -n "$r" ] && [ -n "$l" ] || die "用法：$SELF get <机器> <远端文件> <本地路径>"
  tgt=$(host_ssh_target "$host") || die "不认识「$host」（$SELF hosts 看别名）"
  if scp -q -i "$SSH_DIR/$SSH_KEY_NAME" -o BatchMode=yes "$tgt:$r" "$l"; then
    ok "已取回  $host:$r  →  $l"
  else
    die "scp 失败 —— 确认远端文件存在：$SELF $host 'ls -l $r'"
  fi
}
# ══════ 区 4 命令：运行与体检 ══════
#
cmd_up() {
  local quiet=${1:-}
  # 这里曾经写的是「sgl 侧不做自愈，它就是被连的那一头」。那句话在两个层面都错：
  #   · 事实层：sgl 也能 `hb <别的机器> "…"`，它不是"被连的一端"；
  #   · 工程层：把一个跨平台工具塞进"我修你 / 你被我修"的模型后，
  #     第一件事就是给某一端写死一个 no-op —— 而那正是故障藏身的地方。
  #
  # 但下面这些**平台差异是真的**，不修掉会真出事：
  #   在 sgl 上照搬 Linux 那套 → mkdir /var/lib/tailscale（被 MSYS 改写成
  #   D:/2Environment/Git/var/lib/…）、pgrep '--tun=userspace' 必然找不到、
  #   然后 nohup tailscaled 起**第二个**用户态 daemon 抢 1055，和系统服务打架；
  #   失败时报的还是"守护进程启动失败"，看着像网络问题。
  # 判据是「这台机器上这件事怎么做」，不是「这台机器该不该做」：
  if is_windows; then
    say "⓪ 身份（私钥在哪）"
    local _k
    if _k=$(hb_key_path); then
      ok "$_k"
    else
      bad "缺私钥 —— hb 不自带密钥，身份要你提供"
      echo "    任选其一："
      echo "      ssh-keygen -t ed25519           # 新机器"
      echo "      把现有私钥放进 $HB_HOME/hb_key  # 已有密钥体系"
      return 1
    fi

    say "① 二进制"
    if command -v tailscale >/dev/null 2>&1; then
      ok "$(tailscale version 2>/dev/null | head -1)（官方客户端，不走下载链）"
    else
      bad "没找到 tailscale.exe —— 这台机器上得先装官方客户端"
      echo "    这台不像 sgl：这里没有可用的系统服务，也没有下载链（Windows 版需要 MSI）"
      echo "    下一步：装上 Tailscale 后重跑；或者 $SELF doctor 看还差什么"
      return 1
    fi

    say "② tailscaled"
    if tailscale status >/dev/null 2>&1; then
      # 与 Linux 同一条判据：可读 ≠ 连着协调面。断连时 netmap 不下发，
      # 表现就是「服务好好的，但一台别的机器都看不见」。
      # herestring 而不是管道：grep -q 提前退出会让上游吃 SIGPIPE，
      # 在 pipefail 下把"断连"判成"没断连"（见 ts_coord_ok 上的注释）。
      local _tj
      _tj=$(tailscale status --json 2>/dev/null | tr -d '\r')
      if [ -n "$_tj" ] && grep -q 'Unable to connect to the Tailscale coordination server' <<< "$_tj"; then
        bad "服务在跑，但与协调服务器断连 —— netmap 不会下发"
        echo "    处置（管理员）：Restart-Service Tailscale    然后重跑 $SELF up"
        return 1
      fi
      ok "系统服务在跑（tailscale status 可读）"
    else
      bad "tailscale status 不通 —— 服务可能没起"
      echo "    处置（管理员）：Restart-Service Tailscale    然后重跑 $SELF up"
      return 1
    fi

    say "③ 入网"
    local _ip; _ip=$(tailscale ip -4 2>/dev/null | tr -d '\r' | head -1)
    if [ -n "$_ip" ]; then ok "已入网 $_ip"; else
      bad "未入网：这台机器没有登录，hb 不在 Windows 上代做登录"
      echo "    处置（管理员）：tailscale up     登录一次即可，之后凭本机状态保持"
      return 1
    fi

    say "④ netmap"
    local _n=0 i
    for i in 1 2 3 4 5 6; do
      _n=$(tailscale status 2>/dev/null | tr -d '\r' | grep -c '^100\.')
      [ "$_n" -gt 1 ] && break
      sleep 2
    done
    if [ "$_n" -gt 1 ]; then ok "可见 $_n 个节点"; else
      bad "netmap 只有 $_n 个节点 —— 网络层面没下发"
      echo "    下一步：等 30 秒重试；仍不行就是这台没登录（见 ③）"
      return 1
    fi

    say "⑤ SSH 身份"
    ensure_ssh && ok "ssh 可用" || { bad "SSH 身份没就绪"; return 1; }

    say "⑥ git 凭据"
    # 凭据从载荷里取（pack 时带进去的那份）：别的机器不该为了拉一次仓库
    # 先让人登录配 PAT。已有就不覆盖 —— 本机的凭据可能更新。
    if [ ! -s "$HOME/.git-credentials" ]; then
      local _c=""
      for _c in "$HB_STATE_DIR/.git-credentials" "$HB_HOME/.git-credentials"; do
        [ -n "$_c" ] && [ -s "$_c" ] && { mkdir -p "$HOME" 2>/dev/null
          install -m 600 "$_c" "$HOME/.git-credentials" 2>/dev/null && ok "凭据已从载荷恢复（$_c）"; break; }
      done
    fi
    if [ -s "$HOME/.git-credentials" ] && git_reads_store; then
      ok "可用（store 排第一顺位）"
    elif [ -s "$HOME/.git-credentials" ]; then
      warn "文件在，但 credential.helper 读不到它 —— 改顺序"
      # ensure_cred_helper 自己在成功/降级时报 ok/warn，这里只看结果，不重复喊
      ensure_cred_helper || [ $? -eq 2 ] || return 1
    else
      warn "没有 ~/.git-credentials：拉私有仓库会卡在 could not read Username"
      echo "    这机器若也要 push/pull：git config --global credential.helper store 后首次输入令牌"
    fi

    # SSH config：对等网格里，这台也可以是"发起方"。没有 config 就没有 ProxyCommand，
    # 于是 `hb yahboom8 "…"` 会直连超时 —— 看着像"对方没开机"。
    say "⑦ SSH 配置（作为发起方时用）"
    if [ -s "$SSH_DIR/config" ]; then
      ok "已有 ~/.ssh/config"
    elif ensure_ssh_conf; then
      ok "已按标准模板生成（ProxyCommand 走本机/对端的出口）"
    else
      warn "没生成 $SSH_DIR/config —— 作为发起方调别的机器时可能直连超时"
    fi
    echo "    自己不需 ssh 自己，但网内别的 Windows 机器可能要走这台"

    # SOCKS5 那一段不在这儿做，但它不是"不需要"，是"本机自己不用绕自己"：
    # 别的主机要借道 GitHub 时，连的是这台机器的 Clash（7897），不是 hb 的隧道。
    echo "    出口：别的机器要借道 GitHub，连的是本机 Clash（127.0.0.1:7897）"
    say "完成"
    echo "    $SELF list 看全貌 · $SELF <机器> \"命令\" 调别的机器"
    return 0
  fi

  say "⓪ 身份（私钥在哪）"
  local _k
  if _k=$(hb_key_path); then
    ok "$_k"
  else
    bad "缺私钥 —— hb 不自带密钥，身份要你提供"
    echo "    任选其一："
    echo "      ssh-keygen -t ed25519           # 新机器"
    echo "      把现有私钥放进 $HB_HOME/hb_key  # 已有密钥体系"
    return 1
  fi

  say "① 二进制"
  ensure_bin || return 1
  mkdir -p /var/lib/tailscale /var/run/tailscale

  say "② tailscaled"
  local i _need=0
  if ts_system_mode; then
    # 真机（有 tun + systemd + root）：装成系统服务，别用用户态顶替。
    ensure_ts_system || return 1
  elif pgrep -f 'tailscaled.*--tun=userspace' >/dev/null 2>&1; then
    if ts_coord_ok; then
      ok "守护进程在跑，且与协调服务器连着"
    else
      warn "进程在，但与协调服务器断连（netmap 会停在只有本机）→ 重启一次"
      # 只 kill 这一个 pid。别用 pkill -f 'tailscaled.*--tun=userspace'：
      # 执行它的 shell 命令行里就含这串，会把自己一起 SIGTERM（实测踩过）。
      local _p; _p=$(pgrep -f 'tailscaled.*--tun=userspace' | head -1)
      [ -n "$_p" ] && kill "$_p" 2>/dev/null
      for i in $(seq 1 10); do
        pgrep -f 'tailscaled.*--tun=userspace' >/dev/null 2>&1 || break
        sleep 1
      done
      _need=1
    fi
  else
    warn "未运行，启动中"
    _need=1
  fi
  if [ $_need -eq 1 ]; then
    # 状态文件与二进制版本必须配套：1.104 之前的状态文件被新二进制读到，
    # 或反过来，都会表现成"进程活着但协调面不认"。这里只在新建时提示，
    # 不自动删 —— 删状态 = 掉线重登，代价比一句警告大。
    if [ -s "$STATE" ] && ! ts_coord_ok; then
      warn "状态文件在，但与协调面连不上（$STATE）"
      echo "    若刚换过 tailscale 版本，先备份再重建："
      echo "      sudo cp $STATE $STATE.bak && sudo rm $STATE && $SELF up"
    fi
    nohup tailscaled --tun=userspace-networking \
      --socks5-server="$SOCKS" --state="$STATE" --socket="$SOCK" \
      >"$LOG" 2>&1 &
    for i in $(seq 1 15); do
      [ -S "$SOCK" ] && break
      sleep 1
    done
    [ -S "$SOCK" ] || { bad "启动失败，日志 $LOG"; tail -5 "$LOG"; return 1; }
    ok "守护进程就绪"
  fi

  say "③ 入网"
  local st ip
  st=$("${TS[@]}" status 2>&1)
  st=$(printf '%s' "$st" | tr -d '\r')
  if grep -q '^100\.' <<< "$st"; then
    ip=$(printf '%s' "$st" | grep '^100\.' | head -1 | awk '{print $1}')
    ok "本机 $ip"
  else
    local ak
    if ensure_authkey --persist; then
      ak=$AUTHKEY_VALUE
    else
      bad "无 authkey —— 找不到入网凭据"
      authkey_hint
      return 1
    fi
    # 必须显式写全所有非默认 flag：tailscaled 一旦存过 non-default 设置，
    # 少写一个 `tailscale up` 就直接拒绝 —— 报错还是「requires mentioning all
    # non-default flags」，看起来像鉴权失败，实际是参数没写全（`--accept-dns=false`
    # 是本机历史遗留的 non-default 项）。--reset 会连 hostname 一起重置，别用。
    local uplog
    uplog=$("${TS[@]}" up --authkey="$ak" --accept-routes --hostname="$(hostname)" \
              --accept-dns=false 2>&1)
    st=$("${TS[@]}" status 2>&1)
    ip=$(printf '%s' "$st" | grep '^100\.' | head -1 | awk '{print $1}')
    if [ -n "$ip" ]; then
      ok "已入网 $ip"
    else
      bad "入网失败"
      printf '%s\n' "$uplog" | sed 's/^/    /' | head -6
      return 1
    fi
  fi

  say "④ 等 netmap 下发"
  local n=0 i
  for i in $(seq 1 30); do
    n=$("${TS[@]}" status | tr -d '\r' | grep -c '^100\.')
    [ "$n" -gt 1 ] && break
    sleep 1
  done
  ok "可见 $n 个节点"

  say "⑤ 连通性自检"
  local h out line got=0
  for h in 100.113.237.37 100.67.55.35; do
    got=0
    for i in 1 2 3; do
      out=$(timeout 20 "${TS[@]}" ping -c 2 "$h" 2>&1)
      if grep -q pong <<< "$out"; then
        got=1
        line=$(printf '%s\n' "$out" | grep -oE 'via [A-Za-z()0-9]+ in [0-9]+ms' | head -1)
        printf '    %-16s [%s] OK\n' "$h" "${line:-pong}"
        break
      fi
      sleep 3
    done
    [ $got -eq 0 ] && printf '    %-16s 不可达\n' "$h"
  done

  say "⑥ SSH 身份"
  if ! ensure_ssh; then
    warn "SSH 身份不完整 —— 网络已通，但别的节点连不进来"
    echo "    这一步不影响网络自愈，只影响远程执行。"
    return 1
  fi
  # 只做一次真连接验证：私钥对但 sgl 的 authorized_keys 没这把钥时，
  # 症状是 "Permission denied (publickey)"，与「网络不通」完全是两件事。
  #
  # 这里**不再** return 1。原来是"sgl 不通 = up 失败"，但 sgl 是台会关机的
  # Windows 台式机，一年里大半时间不在线；把它当唯一参照物，等于让"这台机器
  # 环境好不好"取决于另一台开没开机。而真正影响全网的只有"别人进不来"，
  # 那件事由 ⑥½ 用所有在线节点兜。
  if timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=12 sgl "exit 0" >/dev/null 2>&1; then
    ok "ssh sgl 可用"
  else
    warn "ssh sgl 不通 —— 忽略，下面改用所有在线节点"
    echo "    若别的机器也连不进这台，问题在本机授权；否则只是 sgl 没开机。"
  fi

  say "⑥½ 公钥名单"
  sync_keys_quiet

  # ⑦ 补上「能拉代码」这一环。
  # 沙箱被清空时 ~/.git-credentials 一并消失，于是 git clone 私有仓库失败；
  # 而 sgl 上那份一直是好的。缺了它，「环境恢复好了」只到能 ssh，还干不了活 ——
  # 上一个接手的人就是在这里折返的：先试直连（被掐）→ 想配代理（没凭据）→
  # 最后用 git bundle 从 sgl 打包含中转。凭据就在对端放着，取回来就完了。
  say "⑦ git 凭据"
  if [ -s "$HOME/.git-credentials" ]; then
    ok "已存在"
  else
    # 平台无关：sgl 上取不出就直说，别让 PowerShell 去拼 base64 再报个看不懂的错
    local _cred
    _cred=$(ssh -o BatchMode=yes -o ConnectTimeout=12 sgl \
              "bash -lc 'base64 -w0 < \"\$HOME/.git-credentials\" 2>/dev/null'" 2>/dev/null \
            | tr -d '\r\n')
    # 取回的是 base64 原文（远端只负责编码，解码在本地做）：
    # 让远端跑 `base64 -d | bash` 等于让对端执行一段看不懂的代码，
    # 而且 PowerShell 会吃掉 $HOME —— 这正是"手工绕行"的起点。
    if [ -n "$_cred" ] && printf '%s' "$_cred" | base64 -d > "$HOME/.git-credentials.hb" 2>/dev/null \
       && [ -s "$HOME/.git-credentials.hb" ]; then
      mv "$HOME/.git-credentials.hb" "$HOME/.git-credentials"
      chmod 600 "$HOME/.git-credentials"
      ok "已从 sgl 取回"
    else
      rm -f "$HOME/.git-credentials.hb"
      is_windows && { warn "本机即 sgl，无对端可取"; } || {
        warn "沙箱与 sgl 都没有 —— 拉私有仓库会失败"
        echo "     在 sgl 上执行 cat \$HOME/.git-credentials，粘到沙箱同名文件（chmod 600）"
      }
    fi
  fi
  # 文件在 ≠ git 能用：本次恢复就是「文件 69 字节、内容正确，clone 仍要账号」。
  # 所以判据放在这里，一次修到底。
  if [ -s "$HOME/.git-credentials" ]; then
    ensure_cred_helper || warn "git 凭据文件在，但 git 不会读它 —— 见上方提示"
  fi

  # 别在这里教人 `ssh sgl` —— 裸 ssh 不会先自修网络，掉线时给出的又是那句
  # 指向错误方向的 "Connection closed by UNKNOWN port 65535"。用 hb 自己。
  [ -z "$quiet" ] && { echo; ok "完成"; echo "   用法：$SELF sgl \"命令\"（与 ssh 等价，但掉线会先自修）"; }
  return 0
}

cmd_doctor() {
  local fail=0
  say "体检"
  # 第一行就报"我是不是完整的" —— 一个被截断下载的 hb 会让后面全线失败，
  # 而报错会指向"没有 authkey""没有私钥"，那是指向错误方向的。
  printf '  %-24s ' "SSH 私钥"
  if _k=$(hb_key_path); then
    echo "OK  $_k"
  else
    echo "无 —— 用 ssh-keygen 生成，或放到 $HB_HOME/hb_key"
    fail=1
  fi

  if command -v tailscale >/dev/null 2>&1; then
    printf '  %-24s OK  %s\n' "tailscale 二进制" "$(tailscale version 2>/dev/null | head -1)"
  else echo "缺失 —— $SELF up 会装"; fail=1; fi

  # Windows（sgl）是出口而不是客户端，下面这些「修隧道用的东西」它不需要，
  # 标成 —  而不是 ✗，否则 sgl 上永远显示体检失败，等于噪音。
  if is_windows; then
    printf '  %-24s %s\n' "本地安装包缓存" "—  不适用（Windows 用官方客户端）"
    printf '  %-24s %s\n' "项目 vendor 缓存" "—  不适用"
  else
    printf '  %-24s ' "本地安装包缓存"
    [ -s "$TS_CACHE/$TS_PKG" ] && echo "OK  $TS_CACHE/$TS_PKG" || echo "无（换沙箱后需要重建）"

    printf '  %-24s ' "项目 vendor 缓存"
    [ -s "$TS_VENDOR/$TS_PKG" ] && echo "OK  $TS_VENDOR/$TS_PKG" || echo "无"
  fi

  if is_windows; then
    printf '  %-24s %s\n' "authkey" "—  不适用（已登录状态由客户端保存）"
    printf '  %-24s ' "Tailscale 服务"
    tailscale status >/dev/null 2>&1 && echo "OK  运行中" || { echo "未运行"; fail=1; }
  else
    printf '  %-24s ' "authkey"
    AUTHKEY_FROM=""
    if ensure_authkey; then
      # 从「自己旁边」找到、但还没固化的，明确指出来 —— 否则下一次 hb up
      # 会静默把它写进 ~/.config/tailscale/authkey，人不知道这个动作发生过。
      if [ -n "${AUTHKEY_FROM:-}" ] && [ -s "${AUTHKEY_FROM}" ]; then
        echo "OK  将取自 ${AUTHKEY_FROM}"
      else
        echo "OK"
      fi
    else
      echo "无 → hb 载荷残缺，重新下载 hb 一个文件即可"
      fail=1
    fi

    printf '  %-24s ' "tailscaled 进程"
    if pgrep -f 'tailscaled.*--tun=userspace' >/dev/null 2>&1; then
      # 「有进程」和「连得上控制面」是两件事：断连时进程照样在，netmap 却是空的。
      # 这一行本来只报 pid，等于把最隐蔽的一种坏况报成绿的。
      if ts_coord_ok; then
        echo "OK  pid=$(pgrep -f 'tailscaled.*--tun=userspace' | head -1)"
      else
        echo "在跑，但与协调服务器断连 → $SELF up（会重启它）"; fail=1
      fi
    else
      echo "未运行"; fail=1
    fi

    printf '  %-24s ' "SOCKS5 :1055"
    port_open 127.0.0.1 1055 5 && echo "监听中" || { echo "未监听"; fail=1; }
  fi

  printf '  %-24s ' "netmap 节点数"
  # 不能用 `grep '^100\.'` 数：Windows 客户端的 status 每行带 \r，
  # `wc -l` 认不出来，sgl 上明明 6 个节点却报 0。改数「含 100. 的行」。
  local n; n=$("${TS[@]}" status 2>/dev/null | tr -d '\r' | grep -c '100\.' || true)
  echo "$n"
  [ "${n:-0}" -gt 1 ] || fail=1

  if is_windows; then
    printf '  %-24s %s\n' "对端可达" "—  本机即出口，无对端需检"
  else
    printf '  %-24s ' "git 凭据"
    # 只看文件在不在是假判据：本次恢复就撞上了「文件在、但沙箱 git 用的是
    # 自带 helper，根本不读 store」→ clone 报 could not read Username。
    # 判的是「沙箱 git 认不认」：store 排第一就行。
    if [ ! -s "$HOME/.git-credentials" ]; then
      echo "无 → hb up 会从 sgl 取回"; fail=1
    elif git_reads_store; then
      echo "OK  ~/.git-credentials（store 生效）"
    else
      echo "文件在，但 git 的 credential.helper 读不到它"
      echo "    当前 helper：$(git config --show-origin --get-all credential.helper 2>/dev/null | tr '\n' ' ')"
      echo "    修：$SELF up（会把 store 排到第一位，原 helper 保留在后）"
      fail=1
    fi

    printf '  %-24s ' "SSH 私钥"
    if _k=$(hb_key_path); then
      echo "OK  $_k"
    else
      echo "无 —— 用 ssh-keygen 生成，或放到 $HB_HOME/hb_key"; fail=1
    fi
    printf '  %-24s ' "sgl 可达"
    if port_open 127.0.0.1 1055 8 && \
       timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=10 sgl "exit 0" >/dev/null 2>&1; then
      echo "OK"
    else echo "不通"; fail=1; fi
  fi

  # 出口：三个域名代表三条不同的链路，分开探才分得清「哪一段断了」。
  #   pkgs.tailscale.com → CDN，装二进制用（实测这条很少被掐）
  #   controlplane…      → 协调面，netmap 靠它下发
  #   api.github.com     → 代码，push / clone 用
  # 并行探，上限约 5 秒；全通只占一行，有失败才展开判读。
  # 2026-11-03 就是靠这组分项探测才判定「不是全网断，是控制面那条断」——
  # 只看"能不能上网"会得出相反结论。
  printf '  %-24s ' "出口连通"
  local _t; _t=$(mktemp -d 2>/dev/null || echo /tmp)
  ( timeout 5 curl -sS -o /dev/null -w '%{http_code}' --max-time 4 https://pkgs.tailscale.com/stable/  > "$_t/a" 2>/dev/null ) &
  ( timeout 5 curl -sS -o /dev/null -w '%{http_code}' --max-time 4 https://controlplane.tailscale.com     > "$_t/b" 2>/dev/null ) &
  ( timeout 5 curl -sS -o /dev/null -w '%{http_code}' --max-time 4 https://api.github.com                > "$_t/c" 2>/dev/null ) &
  wait
  local _a _b _c
  _a=$(cat "$_t/a" 2>/dev/null); _b=$(cat "$_t/b" 2>/dev/null); _c=$(cat "$_t/c" 2>/dev/null)
  rm -rf "$_t" 2>/dev/null
  if [ "$_a" = "200" ] && [ "$_c" = "200" ] && { [ "$_b" = "302" ] || [ "$_b" = "200" ]; }; then
    echo "OK  CDN $_a · 协调面 $_b · GitHub $_c"
  else
    echo "CDN ${_a:-超时} · 协调面 ${_b:-超时} · GitHub ${_c:-超时}"
    if [ "$_c" != "200" ]; then
      echo "    GitHub 断 → 直连被掐，$SELF proxy on 借道（与本机 ssh 无关）"
    fi
    if [ "$_b" = "000" ] || [ -z "$_b" ]; then
      echo "    协调面断 → netmap 不会下发，$SELF up 会重启 tailscaled"
    fi
    fail=1
  fi

  echo
  # 「先读说明书」没法强制执行，但可以让它出现在体检末尾 —— 任何接手的
  # AI 第一次裸调用就会看到路径，不用先去猜该信谁。
  printf '  %-24s ' "说明书"
  local doc=""
  for doc in "$HB_HOME/README.md" "$HB_HOME/../README.md"; do
    [ -f "$doc" ] && break; doc=""
  done
  if [ -n "$doc" ]; then
    echo "OK  $(cd "$(dirname "$doc")" && pwd)/$(basename "$doc")"
  else
    echo "缺 —— 仓库根的 README.md（安装说明与命令口径都在里面）"
  fi

  echo
  [ $fail -eq 0 ] && ok "全部通过" || { bad "有项目未通过，试 $SELF up"; return 1; }
}

# 需联网的命令统一入口：先确保网络，再执行
# 注意：兜底分支会把未识别首参当主机名，所以这里必须先判断主机能否解析 ——
# 否则 `hb upp`（子命令打错）会安静地走一次 DNS 失败，报 "Could not resolve
# hostname"，让人误以为是网络问题。这类「报错指向错误方向」正是本环境最贵的坑。
cmd_run() {
  [ $# -ge 1 ] || die "用法：$SELF <host|别名> <命令...>"
  local name=$1; shift
  # 三种名字都认，顺序固定：① 别名文件 ② ~/.ssh/config 的 Host ③ 网内节点名/IP。
  # 别名的优先级高于 ssh config —— 别名是"我这次的叫法"，config 是历史遗留。
  local host host_user
  host=$(hosts_resolve "$name" | awk '{print $1}')
  host_user=$(hosts_user "$name")
  local cfg_hosts nodes
  cfg_hosts=$(grep -oE '^[[:space:]]*Host[[:space:]]+[a-zA-Z0-9_.-]+' ~/.ssh/config 2>/dev/null | awk '{print $NF}')
  nodes=$(ts_nodes 2>/dev/null | awk -F'\t' '{print $2"\t"$1}')

  local hit_cfg=0 hit_node=0
  if [ "$host" != "$name" ]; then
    :                                    # 命中别名
  else
    printf '%s\n' "$cfg_hosts" | grep -qx -- "$name" && hit_cfg=1
    printf '%s\n' "$nodes" | cut -f1 | grep -qx -- "$name" && hit_node=1
    # 大小写不敏感命中（`hb Desktop-SGL-4` 也该认）：节点名是 Tailscale 起的，
    # 而主机名在各个系统上大小写并不一致。命中后仍用网内那份原样名字。
    if [ $hit_node -eq 0 ]; then
      local _ci; _ci=$(printf '%s\n' "$nodes" | cut -f1 | awk -v n="$name" 'tolower($0)==tolower(n){print; exit}')
      [ -n "$_ci" ] && { name="$_ci"; host="$_ci"; hit_node=1; }
    fi
    # 纯 IP 永远是可调用的目标 —— 不该要求"先起个别名"或"先入 DNS"。
    if printf '%s' "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
      hit_node=1
    fi
    if ! getent hosts "$host" >/dev/null 2>&1; then
      if [ $hit_cfg -eq 0 ] && [ $hit_node -eq 0 ]; then
        bad "不认识「$name」—— 既不是别名，也不是 ssh Host，网内也没这台"
        echo "    别名：$SELF hosts list   （加一个：$SELF hosts add $name <IP>）"
        echo "    网内节点：$SELF list"
        echo "    也可以直接写 IP 或网内节点名：$SELF <IP|节点名> \"命令\""
        # 打错的子命令最容易发生在这里：把拼错的词当主机名去 ssh 会静默超时，
        # 所以直接给"你是不是想运行子命令"这条最可能的原因。
        echo "    如果你是想运行子命令，可用：$HB_SUBCMDS"
        return 2
      fi
    fi
  fi

  # 节点名 → IP：`hb yahboom8 "uptime"` 能直接用，不必先查 IP 再记别名。
  # 注意先定 sshr，再判 IP —— 顺序反了会让节点名这条路悄悄退化成裸 ssh。
  local sshr="$name"
  if [ $hit_node -eq 1 ] && [ $hit_cfg -eq 0 ]; then
    local ip; ip=$(printf '%s\n' "$nodes" | awk -F'\t' -v n="$name" '$1==n{print $2; exit}')
    [ -n "$ip" ] && { host=$ip; sshr=$name; }
  fi

  # 最终目标是 IP 时，必须把 ssh 参数补齐。裸 `ssh 100.x.y.z` 会从 config 开头
  # 匹配第一条生效的 Host（本项目的机器配置都挂在具体 Host 名下），于是：
  #   ① 丢掉 ProxyCommand → 直连超时，报 "Connection timed out"；
  #   ② 用户变成 root → 报 "Permission denied (publickey)"。
  # 两个报错都指向"机器不通/没授权"，而链路其实是好的。实测踩过，别再简化。
  #
  # 用户名的来源按可信度排：名字前缀（sgl2 → sgl）→ 候选名里出现的已知前缀
  # （网内如果有 jetson27，就有账号 jetson）→ sgl（本环境唯一被授权的常规账号）。
  # 别用 `${name%%[0-9]*}` 一把梭：`desktop-sgl-4` 会变成 `desktop-sgl-`。
  # 目标解析成 IP 时，ssh 不知道该用哪个账号、走不走隧道 —— 参数得由 hb 补齐。
  # 裸 `ssh 100.x.y.z` 会从 config 开头匹配第一条生效的 Host，于是：
  #   ① 丢掉 ProxyCommand → 直连超时，报 "Connection timed out"；
  #   ② 用户变成 root → 报 "Permission denied (publickey)"。
  # 两个报错都指向"机器不通/没授权"，而链路其实是好的。实测踩过，别再简化。
  if printf '%s' "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    # 账号优先从 config 抄：HostName 等于这个 IP 的那条 Host 用的是哪个 User，
    # 这个 IP 就用哪个。抄比猜强 —— 猜错报的是 "Permission denied"，
    # 看着像"密钥没授权"，实际只是用了别人的账号（实测踩过一次）。
    local ssh_user="" pref
    ssh_user="$host_user"
    [ -n "$ssh_user" ] || ssh_user=$(awk -v ip="$host" '
      tolower($1)=="host"              { h=$2; u=""; next }
      tolower($1)=="hostname" && $2==ip { hh=h; next }
      tolower($1)=="user"              { u=$2; next }
      END { if (hh!="" && u!="") print u }' "$SSH_DIR/config" 2>/dev/null)
    if [ -z "$ssh_user" ]; then
      # 没有现成的 Host 可比：只信「名字前缀」（sgl2 → sgl）。
      # 不从别的节点猜 —— 网内第一个带数字的节点是沙箱 e8a313c69199（前缀 "e"），
      # 下一个减版本号得到 "desktop-sgl"，两个都不是账号。
      pref="${sshr%%[0-9]*}"; pref="${pref%-}"
      [ "$pref" != "$sshr" ] && printf '%s' "$pref" | grep -qE '^[a-zA-Z][a-zA-Z0-9_.]*$' && ssh_user="$pref"
    fi
    ssh_user="${ssh_user:-sgl}"
    # 先直连试一次，再穿隧道。理由：真机（Jetson、sgl）是内核 tun，
    # 直连本来就能通且更快；沙箱是用户态，直连秒失败再回落到代理，
    # 代价只有一次极短的失败。反过来（只走代理）会把两端都拖慢。
    set -- -o "ProxyCommand=$(ssh_proxy_cmd)" \
           -o "IdentityFile=$SSH_DIR/$SSH_KEY_NAME" \
           -o "User=$ssh_user" "$@"
  fi

  # 解析到哪台要说出来，但不占 stdout：stdout 是远端命令的输出，被一行提示
  # 污染后 `out=$(hb sgl cat file)` 就不干净了。
  if [ "$host" != "$name" ]; then
    [ $hit_node -eq 1 ] && why=节点名 || why=别名
    printf '\033[2m# %s → %s（%s）\033[0m\n' "$name" "$host" "$why" >&2
  fi
  if ! net_up; then
    warn "网络未就绪，先修复"
    cmd_up quiet || { hb_diagnose "$host" 1; die "修复失败"; }
  fi
  # 记住"这台"：第一台叫 sgl（老习惯，退化成默认），之后每台都用它的节点名。
  # 不记的话，下一次还是只能靠 IP 或长名字，而人记住的永远是简称。
  if [ "$host" != "$name" ] || printf '%s' "$host" | grep -qE '^[0-9]+\.'; then
    hosts_remember "$name" "$host" >/dev/null 2>&1 || true
  fi
  # ssh 自己会重试，但"失败"必须带上诊断 —— 否则调用者只拿到 exit 255，
  # 得自己去猜是隧道、私钥还是对端没开机。
  local rc=0
  ssh -o BatchMode=yes "$host" "$@" || rc=$?
  [ $rc -eq 255 ] && hb_diagnose "$host" 255
  return $rc
}

cmd_ts() { exec tailscale --socket="$SOCK" "$@"; }

# ══════ 区 1b：Tailscale 控制面（API）══════════════════════════════════
# 为什么要这个区：节点能"广播"子网路由（tailscale set --advertise-routes），
# 但**批准**是改 tailnet 策略，属于 admin 动作，节点自己批不了自己。
# 以前遇到这种情况只能让人去后台点两下；现在用 API token 一条命令搞定。
#   token 从哪来：$TS_API_KEY，或 credentials.json 里的 ts_api_key
#   （tskey-api-… 与 authkey tskey-auth-… 不是一回事：前者能改整个 tailnet）
_ts_api_token() {
  if [ -n "${TS_API_KEY:-}" ]; then printf '%s' "$TS_API_KEY"; return 0; fi
  local f k
  for f in "$HB_STATE_DIR/credentials.json" "$HB_HOME/credentials.json"; do
    [ -s "$f" ] || continue
    k=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("ts_api_key","") or "")' "$f" 2>/dev/null)
    [ -n "$k" ] && { printf '%s' "$k"; return 0; }
  done
  return 1
}

_ts_api() {   # <METHOD> <path> [json body]
  local tok; tok=$(_ts_api_token) || return 1
  if [ -n "${3:-}" ]; then
    curl -sS -m 30 -u "$tok:" -X "$1" "https://api.tailscale.com/api/v2$2" \
      -H 'Content-Type: application/json' -d "$3"
  else
    curl -sS -m 30 -u "$tok:" -X "$1" "https://api.tailscale.com/api/v2$2"
  fi
}

_route_id_of() {  # <机器名> → deviceId（精确或前缀匹配，唯一才算）
  _ts_api GET "/tailnet/-/devices" | python3 -c '
import json, sys
want = sys.argv[1].lower()
d = json.load(sys.stdin)
hits = [x for x in d.get("devices", []) if x.get("hostname", "").lower() == want] \
    or [x for x in d.get("devices", []) if x.get("hostname", "").lower().startswith(want)]
if len(hits) == 1:
    print(hits[0]["id"])
elif not hits:
    sys.exit("找不到节点：" + want)
else:
    sys.exit("匹配到多台，写全名：" + ", ".join(x["hostname"] for x in hits))
' "$1"
}

cmd_route() {
  local sub="${1:-ls}"; [ $# -gt 0 ] && shift
  _ts_api_token >/dev/null 2>&1 || die "没有 API token。把 tskey-api-… 写进 credentials.json 的 ts_api_key，或 export TS_API_KEY"
  case "$sub" in
    ls|list)
      # 注意：/tailnet/-/devices 列表接口**不返回** advertisedRoutes / enabledRoutes，
      # 只有 /device/{id}?fields=all 才有。所以先列 id，再逐台取详情。
      local ids id hn
      ids=$(_ts_api GET "/tailnet/-/devices" | python3 -c '
import json,sys
for x in json.load(sys.stdin).get("devices", []):
    print(x["id"] + "\t" + x.get("hostname", "?"))
')
      printf '%-18s %-8s %s\n' "节点" "状态" "路由（广播 → 已批准）"
      while IFS=$'\t' read -r id hn; do
        [ -n "$id" ] || continue
        _ts_api GET "/device/$id?fields=all" | python3 -c '
import json, sys
d = json.load(sys.stdin)
adv = d.get("advertisedRoutes") or []
en  = d.get("enabledRoutes") or []
if not adv:
    sys.exit(0)
pend = [r for r in adv if r not in en]
print("%-18s %-8s %s  →  %s" % (d.get("hostname", "?"), "待批准" if pend else "已批准",
                                ",".join(adv), ",".join(en) or "-"))
if pend:
    print("%-18s %-8s   待批准: %s" % ("", "", ",".join(pend)))
'
      done <<< "$ids" ;;
    approve|revoke)
      local host="${1:-}"; [ -n "$host" ] || die "用法：hb route approve <机器> [cidr...]"
      shift || true
      local id adv en want
      id=$(_route_id_of "$host") || die "找不到节点 $host"
      adv=$(_ts_api GET "/device/$id?fields=all" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(" ".join(d.get("advertisedRoutes") or []))')
      en=$(_ts_api GET "/device/$id?fields=all" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(" ".join(d.get("enabledRoutes") or []))')
      [ -n "$adv" ] || die "$host 没有广播任何路由。先在那台机器上：tailscale set --advertise-routes=<CIDR>"
      if [ $# -gt 0 ]; then want="$*"; else want="$adv"; fi
      local new
      if [ "$sub" = "approve" ]; then
        new=$(python3 -c 'import sys;a=set(sys.argv[1].split());b=set(" ".join(sys.argv[2:]).split());print(" ".join(sorted(a|b)))' "$en" $want)
      else
        new=$(python3 -c 'import sys;a=set(sys.argv[1].split());b=set(" ".join(sys.argv[2:]).split());print(" ".join(sorted(a-b)))' "$en" $want)
      fi
      local body
      body=$(python3 -c 'import json,sys;print(json.dumps({"routes": [x for x in sys.argv[1].split() if x]}))' "$new")
      _ts_api POST "/device/$id/routes" "$body" | python3 -c '
import json,sys
d=json.load(sys.stdin)
if "enabledRoutes" in d:
    print("  ✓ 已批准: " + (",".join(d["enabledRoutes"]) or "(空)"))
else:
    print("  失败: " + json.dumps(d, ensure_ascii=False)[:200])
' ;;
    *)
      die "用法：hb route [ls | approve <机器> [cidr...] | revoke <机器> [cidr...]]" ;;
  esac
}

cmd_vendor() {
  say "归档二进制到项目目录"
  mkdir -p "$TS_VENDOR"
  if command -v tailscaled >/dev/null; then
    tar -czf "$TS_VENDOR/$TS_PKG" -C /usr/local/bin tailscale tailscaled
    # 摘要必须跟包放一起：否则下次换沙箱，本地包要么被在线清单否掉，
    # 要么无据可验。写在这里，跟包一起进网盘。
    ( cd "$TS_VENDOR" && sha256sum "$TS_PKG" > "$TS_PKG.sha256" ) 2>/dev/null
    ok "$TS_VENDOR/$TS_PKG  ($(du -h "$TS_VENDOR/$TS_PKG" | cut -f1))"
    [ -s "$TS_VENDOR/$TS_PKG.sha256" ] && ok "摘要已写入 $(basename "$TS_PKG").sha256"
    echo "    记得同步到网盘备份（两个文件一起），换沙箱后才能离线自举"
  else
    bad "本机没装 tailscale，无从归档"; return 1
  fi
}


# 借道：沙箱直连 GitHub 会间歇性被掐，用 ssh -L 借 sgl 上的 Clash。
# 手动排障用：只建隧道，不碰仓库。

# ── 拉仓库：把「借道 + 凭据」收成一条 ──────────────────────────────
# 2026-11-02 恢复实测：直连 GitHub 超时 → hb proxy on → clone 卡在
# could not read Username（文件在，git 不读）→ 手工 -c credential.helper=store。
# 三步每一步都合理，拼起来就是"绕开 hb 干活"。它们本该是这一条命令里的三行。

# ── 重建内嵌载荷 ───────────────────────────────────────────────────
# 只在「换了私钥 / 轮换了 authkey」时需要。编辑脚本正文**不需要** pack ——
# 载荷在 `exit 0` 之后，编辑器改不到它。

# ── 出错时先自诊，再交回给人 ────────────────────────────────────────
# 契约：hb 报错必须带上「哪里坏了 + 怎么修」。只说 "ssh 失败" 等于把
# 排查工作退回给调用者，而调用者（另一个 AI）没有本机上下文。
hb_diagnose() {
  local host=$1 rc=$2
  echo
  say "自诊（$host 调用失败，exit=$rc）"
  if is_windows; then
    printf '  %-20s %s\n' "本机角色" "Windows：隧道不归本机修；本机 Clash 7897 供别人借道"
    command -v tailscale >/dev/null 2>&1 && [ -z "$("${TS[@]}" ip -4 2>/dev/null | tr -d '\r')" ] \
      && printf '  %-20s %s\n' "tailscale" "未入网 → tailscale up（需管理员）"
    [ -s "$SSH_DIR/$SSH_KEY_NAME" ] || [ -s "$HB_HOME/hb_key.enc" ] \
      || printf '  %-20s %s\n' "SSH 私钥" "无 → $SELF up"
  else
    if ! pgrep -f 'tailscaled.*--tun=userspace' >/dev/null 2>&1; then
      printf '  %-20s %s\n' "tailscaled" "未运行 → $SELF up"
    fi
    if ! port_open 127.0.0.1 1055 5; then
      printf '  %-20s %s\n' "SOCKS5 :1055" "未监听 → $SELF up"
    fi
    [ -s "$SSH_DIR/$SSH_KEY_NAME" ] || printf '  %-20s %s\n' "SSH 私钥" "无 → $SELF up（会从载荷解出）"
  fi
  local ping
  ping=$("${TS[@]}" ping -c 1 --timeout 5s "$host" 2>&1 | tr -d '\r' | tail -1)
  case "$ping" in
    *pong*) printf '  %-20s %s\n' "网络到 $host" "通（问题在认证或远端 shell）" ;;
    *)      # 网络层通、但 22 端口没在听（沙箱就是这种）：这和"没开机"是两回事。
            # 说成"机器没开机"会让人去查 Tailscale，查半天也查不出东西。
            if port_open "$host" 22 5; then
              # 22 端口在听就等于 sshd 在跑。这时候再报「SSH 服务没在听」是自相矛盾，
              # 而且把排查方向指反了 —— 2026-11-16 实测：那台 Jetson 的账号是 root，
              # hb 默认拿当前用户名（sgl）去登，回 Permission denied，却被诊断成
              # 「SSH 服务没在听」，下一步该看账号还是看 sshd，屏幕上一个字都没说。
              printf '  %-20s %s\n' "网络到 $host" "通；22 端口在听 → 问题在认证（账号/公钥），不是服务没起"
              echo "    常见原因：这台机器上没有这个账号（JetPack 镜像常是 root / ubuntu），或公钥没埋进去"
              echo "    试：$SELF hosts add <名字> $host user=root   # 或 user=ubuntu，把账号记进别名"
            else
              printf '  %-20s %s\n' "网络到 $host" "不通 —— 可能没开机/不在 tailnet；也可能这台本就不接受入站 SSH（没跑 sshd）"
              echo "    判据：上面 ①–④ 若是 ✓，说明本机网络是好的，问题在对端或这条链路"
              echo "    沙箱这类机器默认不跑 sshd，只能被调用方主动连出去 —— 这是环境设定，不是故障"
            fi ;;
  esac
  echo "    下一步：$SELF doctor 看全量；$SELF up 直接修（幂等）。"
  echo "    ⚠️ 如果 doctor 指出的问题 hb 自己修不了，那是 hb 的缺口 ——"
  echo "       改 hb 的判据，别在会话里手工绕。绕一次，下一个人还得再踩一次。"
}

# ── 设备总览：hb list ──────────────────────────────────────────────
# 为什么不是 status 加几个过滤：AI 拿到的是「现在该不该动手、先动哪」，
# 而不是一张要自己读懂的节点表。所以这里只回答三个问题：
#   ① 我这台是什么平台（沙箱 / Windows）—— 平台只决定做法，不决定权限
#   ② 网络和身份齐不齐（能不能 ssh 出去、能不能拉代码）
#   ③ 对端在不在线（逐个列，离线的要说清"不是配置错"）
#
# 输出两种：
#   默认  一屏人看的表，每行末尾给状态词
#   --json  给程序/AI 读的稳定结构（字段改名要同步改 AGENTS.md 与这里）
# 退出码：0 全绿；1 有红项。stdout 只放结果，诊断一律 stderr。
ts_nodes() {
  "${TS[@]}" status 2>/dev/null | tr -d '\r' | awk '
    /^[0-9]+\./ {
      ip=$1; name=$2;
      # 判据只能看整词：「offline,」「active;」都带标点，纯 == 比较永远落空，
    # 于是一排节点全被当成 idle，而列表还会把它们显示成 offline（真实踩到）。
      st="online"; for(i=3;i<=NF;i++){ if($i ~ /^offline/){ st="offline"; break } }
      printf "%s\t%s\t%s\n", ip, name, st
    }'
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

cmd_list() {
  local json=0
  case "${1:-}" in
    --json) json=1 ;;
    "") ;;
    *) bad "用法：$SELF list [--json]"; return 2 ;;
  esac

  if ! "${TS[@]}" status >/dev/null 2>&1; then
    if [ $json -eq 1 ]; then
      printf '{"ok":false,"role":"%s","error":"tailscale 不可用（未安装或未入网）","next":"hb up"}\n' \
        "$(is_windows && echo exit || echo sandbox)"
    else
      bad "tailscale 不可用 —— $SELF up"
    fi
    return 1
  fi

  # 本机 IP 直接问 tailscale ip -4，不从 status 文本里猜。
  # 旧写法拿 hostname 去匹配 status 第二列：沙箱上 Self 恰好排第一行还能蒙对，
  # sgl 上它排第六行，而 status 里叫 desktop-sgl-4、hostname 是 DESKTOP-SGL，
  # 匹配不上就回落到「最后一行的 IP」—— 于是把 yahboom8 当成自己，
  # 真正的 sgl 被列成「对端 offline」，整屏都是假的。
  local node_ip="" tsraw line p_ip p_name p_st p_seen
  node_ip=$("${TS[@]}" ip -4 2>/dev/null | head -1 | tr -d '\r')
  tsraw=$("${TS[@]}" status 2>/dev/null | tr -d '\r')

  # 对端：netmap 每个节点一行 ip|name|state|last_seen
  # 判据三处都是踩出来的：
  #   ① 状态看整行：离线行是 `offline, last seen 140d ago`，用字段 == 比较
  #      （`$5=="offline"`）永远落空，一排节点全被骗成在线；
  #   ② last seen 用 sed 取整段，别按空格切 —— 版本不同列数会变；
  #   ③ 只有「status 说在线」的才值得 ping。对离线节点 ping 会一路等到超时，
  #      list 从 0.3s 变成 14s（实测），而结论一个字都不会变。
  local peers="" online_n=0 total_n=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    p_ip=$(printf '%s' "$line" | awk '{print $1}')
    p_name=$(printf '%s' "$line" | awk '{print $2}')
    p_seen=""
    case "$line" in
      *"last seen "*) p_seen=$(printf '%s' "$line" | sed -n 's/.*last seen \(.*\)$/\1/p' \
                        | sed 's/[[:space:]]*$//') ;;
    esac
    p_st=online
    case "$line" in *offline*) p_st=offline ;; esac
    total_n=$((total_n + 1))
    [ "$p_st" = "online" ] && online_n=$((online_n + 1))
    peers="${peers}${p_ip}|${p_name}|${p_st}|${p_seen}"$'\n'
  done <<< "$(printf '%s\n' "$tsraw" | grep -E '^[0-9]+\.')"

  # 在线但 ping 不通 = 对方开着机、服务/防火墙出事。status 看不出来，只有 ping 看得见。
  # 判据：tailscale ping 成功也返回 exit=1（§5），只能看输出里的 pong。
  # 写法：先存进变量再 case 匹配；`cmd 2>&1 | grep -q pong && p=1` 在 pipefail 下
  # 会静默判 0（实测），那正是上一版把在线节点全标成离线的元凶。
  # ping 两端都做：Windows 的 `tailscale ping` 同样可用，之前跳过了，
  # 于是 sgl 上的 list 永远不区分"在线"和"在线但不可达"。
  if true; then
    local peers2="" pout
    while IFS='|' read -r p_ip p_name p_st p_seen; do
      [ -z "$p_ip" ] && continue
      if [ "$p_ip" != "$node_ip" ] && [ "$p_st" = "online" ]; then
        pout=$(timeout 8 "${TS[@]}" ping -c 1 --timeout 3s "$p_ip" 2>&1)
        case "$pout" in *pong*) ;; *) p_st="unreachable" ;; esac
      fi
      peers2="${peers2}${p_ip}|${p_name}|${p_st}|${p_seen}"$'\n'
    done <<< "$peers"
    peers="$peers2"
  fi

  local socks=0 key=0 cred=0 creds_store=0 sshok=0
  port_open 127.0.0.1 1055 5 && socks=1
  [ -s "$SSH_DIR/$SSH_KEY_NAME" ] && key=1
  [ -s "$HOME/.git-credentials" ] && cred=1
  # 看得见的那份凭据不算数：git 实际读不读它才算。
  # 顺带覆盖"git 拿空值"这种隐形状��（缓存对象说读得到，实际读不到）。
  if [ $cred -eq 1 ] && _git_sees_credential; then creds_store=1; fi

  # ssh 探针放后台，和下面的 ping 并行。sgl 的 sshd 每次登录要起 PowerShell 并加载
  # profile，实测 6~9s（链路走 relay 更慢），串行叠在 ping 上 list 就要 9s ——
  # 一条"看一眼"的命令不该让人等这么久。
  local sshpid=""
  if [ $socks -eq 1 ] && ! is_windows; then
    timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=8 sgl "exit 0" >/dev/null 2>&1 &
    sshpid=$!
  fi

  if [ -n "$sshpid" ]; then wait "$sshpid" && sshok=1; fi

  # 在线数只数对端：本机永远在线，算进去会让"1 台在线"看起来像"2 台"，
  # 而这个数字是给人看的第一印象。
  local peers_online=0
  while IFS='|' read -r p_ip p_name p_st p_seen; do
    [ -z "$p_ip" ] && continue
    [ "$p_ip" = "$node_ip" ] && continue
    [ "$p_st" = "online" ] && peers_online=$((peers_online + 1))
  done <<< "$peers"

  # 打分：只有**这台机器自己就不需要**的东西才不计分，而不是按角色一刀切。
  # SOCKS5：只有沙箱自己绕出去时要用；ssh <默认机器>：本机就是那台时不测。
  # 其余（私钥、git 凭据）两端一样要求 —— 因为两端都会 `hb <别的机器> "…"`。
  local rc=0
  [ -z "$node_ip" ] && rc=1
  [ $key -eq 0 ] && rc=1
  [ $creds_store -eq 0 ] && rc=1
  if ! is_windows; then
    [ $socks -eq 0 ] && rc=1
    [ $sshok -eq 0 ] && rc=1
  fi

  if [ $json -eq 1 ]; then
    local role; if is_windows; then role=win; else role=sandbox; fi
    jb() { [ "$1" = "1" ] && printf 'true' || printf 'false'; }
    # 不适用的项给 null，不给 false —— false 是"坏了"，null 是"这里不涉及"。
    # 只有两项属于"本机自己不用"：socks1055（本机不绕自己）、sgl_ssh（本机就是它）。
    # 私钥 / git 凭据两端都要，一律给布尔 —— 别再用 role 去猜。
    js() { if is_windows; then printf 'null'; else printf '%s' "$(jb "$1")"; fi; }
    printf '{\n'
    printf '  "ok": %s,\n' "$([ $rc -eq 0 ] && echo true || echo false)"
    printf '  "role": "%s",\n' "$role"
    printf '  "host": "%s",\n' "$(json_escape "$(hostname)")"
    printf '  "tailscale_ip": "%s",\n' "${node_ip:-}"
    printf '  "netmap_nodes": %s,\n' "${total_n:-0}"
    printf '  "checks": {\n'
    printf '    "netmap": %s,\n' "$([ -n "$node_ip" ] && echo true || echo false)"
    printf '    "socks1055": %s,\n' "$(js $socks)"
    printf '    "ssh_key": %s,\n' "$(jb $key)"
    printf '    "git_credentials": %s,\n' "$(jb $cred)"
    printf '    "git_helper_store": %s,\n' "$(jb $creds_store)"
    printf '    "default_ssh": %s\n' "$(js $sshok)"
    printf '  },\n'
    printf '  "peers": ['
    local first=1
    while IFS='|' read -r p_ip p_name p_st p_seen; do
      [ -z "$p_ip" ] && continue
      [ $first -eq 0 ] && printf ','
      first=0
      printf '{"ip":"%s","name":"%s","state":"%s","last_seen":"%s","self":%s}' \
        "$p_ip" "$(json_escape "$p_name")" "$p_st" "$(json_escape "$p_seen")" \
        "$([ "$p_ip" = "$node_ip" ] && echo true || echo false)"
    done <<< "$peers"
    printf ']\n}\n'
    return $rc
  fi

  local role_txt; if is_windows; then role_txt="Windows 工作站"; else role_txt="沙箱"; fi
  say "本机  $(hostname)  ·  $role_txt"
  if [ -n "$node_ip" ]; then
    ok "tailscale ${node_ip}  网内 ${total_n} 台（含本机）"
    # 有 IP 不等于连着：netmap 只有自己时，最常见的原因是到协调面的 TCP 死了，
    # 而进程还活着。这里先说出来，省得人把它当成"别人都没开机"去查对端。
    if [ "$total_n" -le 1 ] && ! ts_coord_ok; then
      warn "只看得见自己：与协调服务器断连 → $SELF up（会重启 tailscaled）"
    fi
  else
    bad "未入网 → $SELF up"
  fi
  if is_windows; then
    printf '  \033[2m-\033[0m SOCKS5 本机不用（不绕自己；别的机器可以借这台出网）\n'
    [ $key -eq 1 ] && ok "SSH 私钥就位（调得动网内其他机器）" \
                   || bad "缺 SSH 私钥 → $SELF up（会从载荷解出明文，600）"
    if [ $creds_store -eq 1 ]; then ok "git 凭据可用（store 生效）"
    elif [ $cred -eq 1 ]; then bad "git 凭据文件在，但 helper 读不到 → $SELF up"
    else printf '  \033[2m-\033[0m git 凭据 未配（要在本机 push/pull 才需要，见 AGENTS §6）\n'; fi
  else
    [ $socks -eq 1 ] && ok "SOCKS5 :1055 监听中" || bad "SOCKS5 未监听 → $SELF up"
    [ $key -eq 1 ] && ok "SSH 私钥就位" || bad "缺 SSH 私钥 → $SELF up"
    if [ $creds_store -eq 1 ]; then ok "git 凭据可用（store 生效）"
    elif [ $cred -eq 1 ]; then bad "git 凭据文件在，但 helper 读不到 → $SELF up"
    else bad "无 git 凭据 → $SELF up"; fi
    [ $sshok -eq 1 ] && ok "ssh sgl 通" || bad "ssh sgl 不通 → $SELF up"
  fi

  echo
  say "对端  ${peers_online} 在线 / $((total_n - 1)) 台"
  if [ "$total_n" -le 1 ]; then printf '  （netmap 里没有其他节点）\n'; fi
  while IFS='|' read -r p_ip p_name p_st p_seen; do
    [ -z "$p_ip" ] && continue
    [ "$p_ip" = "$node_ip" ] && continue          # 本机不在"对端"里重复出现
    case "$p_st" in
      online)
        printf '  \033[32m●\033[0m %-16s %-14s online\n' "$p_ip" "$p_name" ;;
      unreachable)
        printf '  \033[33m!\033[0m %-16s %-14s 在线但 ping 不通（服务或防火墙）\n' "$p_ip" "$p_name" ;;
      *)
        # 长期离线要说清楚：140 天没上线跟"今天关机"是两件事，
        # 前者该去删设备/换机器，后者只需要等 —— 混成一句话会让人白折腾。
        local _hint=""
        case "$p_seen" in
          *d\ ago) [ "${p_seen%%d*}" -ge 30 ] 2>/dev/null && _hint="（长期离线，可能已下线）" ;;
        esac
        printf '  \033[31m○\033[0m %-16s %-14s offline  %s%s\n' "$p_ip" "$p_name" "${p_seen:-?}" "$_hint" ;;
    esac
  done <<< "$peers"

  echo
  [ $rc -eq 0 ] && ok "全绿" || { bad "有红项"; echo "    下一步：$SELF up（幂等）；只想看本机细节：$SELF doctor"; }
  return $rc
}

# ── 两端自证：本地 hb / AGENTS.md 与 sgl 上那份是不是同一份 ─────────
# 为什么值得单独一条命令：换沙箱后最高频的动作之一就是「核对两端脚本同版」。
# 手工做要拼 ssh + 中文目录 + 至少两层引号，实测会一路退到 base64、
# 再退到 UTF-16LE EncodedCommand，四轮才成 —— 而每一轮失败都长得像别的问题。
# 复杂度该关在工具里，外面只剩一句 hb diff。
# ── 戴帽子：任何一台机器临时当分发服务器 ──────────────────────────
# 需求原话（2026-11-05）：「我希望每一台机器在需要添加一个新的机器的时候，
# 都能来暂时戴这顶帽子，充当服务器」。没有多余的机器专门做这件事。
#
# 所以「帽子」不是一台机器，是一个**身份**：谁戴上，谁就把 hostname 改成
# hb-hub，域名随之变成 hb-hub.<tailnet>.ts.net，发出去装完就摘下来。
#
# 三条边界，都是实测出来的：
#   · 域名跟节点走，不跟帽子走。同一时刻只有一台能叫 hb-hub，第二台会拿到
#     hb-hub-1。所以「戴上时域名固定、摘下后还原」是能做到的最接近的效果。
#   · 改名不会断现有连接（实测：改名后 ssh sgl 照常回 OK），所以随时可戴可摘。
#   · funnel 配置绑的是「改名那一刻的域名」。改名后旧配置还在、旧域名还能通，
#     看起来一切正常其实是个幽灵 —— 所以戴上时必须先 funnel reset。
_HUB_NAME="hb-hub"
_HUB_ORIG=""
_HUB_SAVED=""

# 当前 hostname（prefs 里的，不是 DNS 的第一段 —— 后缀 -1 是协调面加的）
_hub_cur_name() {
  local n
  n=$("${TS[@]}" debug prefs 2>/dev/null | tr -d '\r' \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("Hostname") or "")' 2>/dev/null)
  [ -n "$n" ] && { printf '%s' "$n"; return; }
  # 老版本没有 debug prefs 时退化为用 DNSName 第一段
  "${TS[@]}" status --json 2>/dev/null | tr -d '\r' \
    | python3 -c 'import sys,json;print((json.load(sys.stdin)["Self"]["DNSName"]).split(".")[0])' 2>/dev/null
}

# 摘下帽子用：把它写进文件，--off 时即使进程重启也知道该还原成什么
_HUB_STATE="${HOME}/.hb/hub-name"

# 戴帽子前的占用检查。返回 0 = 帽子空着，可以戴；1 = 被占（已打印是谁、怎么办）。
# 判据是「netmap 里有没有 HostName 精确等于 hb-hub 的节点」，**不看在线状态** ——
# 协调面判重名只看名字，不管那台机器死活：昨天关机的机器照样占着 hb-hub，
# 你今天戴就只会拿到 hb-hub-1。所以离线节点也必须当占用处理。
_hub_check_free() {
  local out
  out=$("${TS[@]}" status --json 2>/dev/null | tr -d '\r' \
    | python3 -c '
import sys, json
want = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    print("err|-|-")
    raise SystemExit
selfd = d.get("Self") or {}
if (selfd.get("HostName") or "") == want:
    print("self|%s|%s" % (((selfd.get("TailscaleIPs") or ["-"])[0]), (selfd.get("OS") or "?")))
    raise SystemExit
for v in (d.get("Peer") or {}).values():
    if (v.get("HostName") or "") == want:
        print("%s|%s|%s" % (
            "online" if v.get("Online") else "offline",
            (v.get("TailscaleIPs") or ["-"])[0],
            (v.get("OS") or "?")))
        raise SystemExit
' "$_HUB_NAME" 2>/dev/null)

  case "$out" in
    "")      return 0 ;;
    err*)
      warn "读不到 netmap，无法确认帽子是否空着（先 hb up 把网络修好）"
      return 1 ;;
    self*)
      warn "本机现在就戴着这顶帽子（hostname 已经是 $_HUB_NAME）"
      if [ -s "$_HUB_STATE" ]; then
        echo "    原名记在 $_HUB_STATE：$(cat "$_HUB_STATE")"
        echo "    先 hb lend --off 摘干净，再重新戴"
      else
        echo "    但摘帽记录不见了（多半是 kill -9 之后状态文件丢了）"
        echo "    手工还原：tailscale set --hostname=<你原来的机器名>"
      fi
      return 1 ;;
    online*)
      local info="${out#online|}"
      warn "帽子正被戴着：${info%%|*}（在线）"
      echo "    同一时刻只能有一台叫 $_HUB_NAME。你再戴会拿到 ${_HUB_NAME}-1，"
      echo "    域名跟着变，之前发出去的短链就对不上了。"
      echo "    办法：让对方执行 hb lend --off，或等它的 --timeout 到点自动摘。"
      return 1 ;;
    offline*)
      local info="${out#offline|}"
      warn "这个名字被一台离线的机器占着：${info%%|*}（离线）"
      echo "    协调面不管节点死活都占着名字，你现在戴只会拿到 ${_HUB_NAME}-1。"
      echo "    办法：https://login.tailscale.com/admin/machines 删掉那台机器，"
      echo "          删完立刻重跑 hb lend。"
      return 1 ;;
  esac
  return 0
}

cmd_lend() {
  local timeout=900 port=8890 do_off=0 script=""
  local -a extras=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --off|off)    do_off=1; shift ;;
      --timeout)    timeout="$2"; shift 2 ;;
      --port)       port="$2"; shift 2 ;;
      --script)     script="$2"; shift 2 ;;
      --extra)      extras+=("$2"); shift 2 ;;
      -h|--help)
        echo "用法: hb lend [--timeout 秒] [--port N] [--extra 文件]... [--script 文件]"
        echo "      hb lend --off"
        echo
        echo "  能力层：把本机临时变成分发服务器（「戴帽子」）——hostname 改成 $_HUB_NAME，"
        echo "  短链固定成 https://$_HUB_NAME.<tailnet>.ts.net，到点或 Ctrl-C 自动摘帽、名字还原。"
        echo "  它只负责「变成服务器」，等谁上线是 hb enroll 的事：hb enroll 默认就调它。"
        echo
        echo "  --timeout 秒   戴多久（默认 900 = 15 分钟）"
        echo "  --extra 文件   额外资产（透传给分发流程），大文件用它带上"
        echo "  --script 文件  指定分发的安装脚本（透传）"
        echo "  --off          立刻摘帽子并把 hostname 改回去（进程被 kill -9 后用它收尾）"
        return 0 ;;
      *) die "不认识的参数：$1（hb lend --help）" ;;
    esac
  done

  if [ $do_off -eq 1 ]; then
    _hub_take_off
    return 0
  fi

  say "戴帽子：本机临时充当分发服务器"
  net_up || { warn "网络未就绪，先修"; cmd_up quiet || die "修复失败"; }

  local cur; cur=$(_hub_cur_name)
  [ -n "$cur" ] || die "读不出当前 hostname（tailscale debug prefs 无输出）"
  ok "本机原名  $cur"

  # 帽子是唯一资源：同一个 tailnet 里只能有一个 hb-hub。
  # 戴之前必须确认没人戴 —— 否则协调面会给 hb-hub-1，短链就跟着变。
  # 这条要放在状态文件检查之前：本机正戴着帽子时，状态文件当然存在，
  # 先查文件会误报成「上次没摘干净」，把「现在就有进程在服务」说成残局。
  _hub_check_free || return 1

  # 名字已经还原、状态文件却还在 → 这才是真的没摘干净（多半是 kill -9 跳过 trap）
  if [ -s "$_HUB_STATE" ] && [ "$(cat "$_HUB_STATE")" != "$cur" ]; then
    warn "上次戴帽子没摘干净，原始名字记在 $_HUB_STATE：$(cat "$_HUB_STATE")"
    echo "    先 hb lend --off 还原，再重新戴"
    return 1
  fi

  mkdir -p "$(dirname "$_HUB_STATE")"
  printf '%s' "$cur" > "$_HUB_STATE"
  # 双保险：同名全局变量存一份。状态文件负责跨进程（kill -9 之后 --off 用），
  # 这个变量负责本次执行内的 EXIT 收尾 —— 不依赖磁盘，不会被谁误删。
  _HUB_ORIG="$cur"

  _lend_restore() {
    [ -n "$_HUB_SAVED" ] && [ "$_HUB_SAVED" = "1" ] || return 0
    # 先认账再动手：PIPE 会连续来，重入时不能把已经还原的名字再"还原"一遍
    _HUB_SAVED=0
    # 锁不属于本进程 = 已经有新一轮在跑，别替它摘帽子（否则它的 funnel 立刻失效）
    if [ -n "$_ENROLL_LOCK" ] && [ -s "$_ENROLL_LOCK" ]; then
      local _o; _o=$(cat "$_ENROLL_LOCK" 2>/dev/null)
      if [ -n "$_o" ] && [ "$_o" != "$$" ]; then return 0; fi
    fi
    # 优先用内存里的原名；拿不到再退回状态文件（--off 跨进程时才需要）。
    local orig="${_HUB_ORIG:-}"
    [ -n "$orig" ] || orig=$(cat "$_HUB_STATE" 2>/dev/null)
    [ -n "$orig" ] || { warn "摘帽失败：既没有 _HUB_ORIG 也读不到 $_HUB_STATE"; return 1; }
    "${TS[@]}" funnel --https=443 off >/dev/null 2>&1
    "${TS[@]}" set --hostname="$orig" >/dev/null 2>&1
    rm -f "$_HUB_STATE"
    # 改完立刻报「已还原」是撒谎：prefs 变了，协调面到 status 还有延迟。
    # 2026-11-16 实测：prefs 已经是 desktop-sgl-4，status --json 仍回 hb-hub，
    # 而屏幕已经打出「名字还原为 desktop-sgl-4」—— 下一个人去 hb list 会当场懵。
    # 判据改成「status 里真的是原名」，最多等 12 秒，超时就明说，不假装成功。
    local i dn=""
    for i in 1 2 3 4 5 6; do
      dn=$("${TS[@]}" status --json 2>/dev/null | tr -d '\r' \
        | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))
except Exception: print("")' 2>/dev/null)
      [ "${dn%%.*}" = "$orig" ] && break
      sleep 2
    done
    if [ "${dn%%.*}" = "$orig" ]; then
      printf '  \033[32m✓\033[0m 已摘帽子，名字还原为 %s\n' "$orig" 2>/dev/null || true
    else
      warn "名字还没生效：status 里仍是 ${dn:-?}（prefs 已改成 $orig）"
      echo "    协调面有延迟，过一会儿 hb list 确认；一直不生效就手动：tailscale set --hostname=$orig"
    fi
  }
  _HUB_SAVED=1
  # 不在这里 trap：cmd_enroll 内部会再注册 EXIT，后注册的会覆盖这里。
  # 改成把摘帽动作挂到 _ENROLL_WRAP 上，由 enroll 的 trap 一起调用。
  _ENROLL_WRAP='_lend_restore'
  # 改名前后这一段也得有保护：名字改完、还没进 cmd_enroll 时被 SIGPIPE
  # 打断（`hb lend | head`），帽子就留在头上了。这里先挂一次，
  # cmd_enroll 内部会挂同样的内容，覆盖无害。
  trap '_enroll_cleanup; eval "${_ENROLL_WRAP:-}"' EXIT INT TERM
  trap '_enroll_cleanup; eval "${_ENROLL_WRAP:-}"; exit 1' PIPE

  # 先清幽灵配置，再改名 —— 顺序不能反：funnel 配置绑的是改名那一刻的域名
  "${TS[@]}" funnel reset >/dev/null 2>&1
  "${TS[@]}" set --hostname="$_HUB_NAME" >/dev/null 2>&1 \
    || die "改名失败（tailscale set --hostname=$_HUB_NAME）"
  sleep 3
  local dns
  dns=$("${TS[@]}" status --json 2>/dev/null | tr -d '\r' \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null)
  [ -n "$dns" ] || die "改名后读不到 DNSName"

  # 硬校验：名字必须精确是 hb-hub。带 -1/-2 后缀说明协调面判了重名，
  # 域名就不是约定的那条短链了。宁可当场摘掉，也不发一条明天会变味的链接。
  local got=${dns%%.*}
  if [ "$got" != "$_HUB_NAME" ]; then
    warn "协调面给了 ${got}，不是 ${_HUB_NAME} —— 名字确实被别人占着"
    _lend_restore
    return 1
  fi
  ok "戴上帽子  $dns"
  echo "    这条链接是固定的：https://$dns/ —— 摘帽期间打不开，下次再戴还是同一条，不用重发"

  # 帽子戴好了，活交给原语：白名单服务 + funnel + 等上线 + trap 清理。
  # 注意方向：这里调的是 _dist_serve（原语），不是 cmd_enroll（业务）——
  # 业务调能力，而不是能力调业务。反过来的话，第一次接手的人只会挑字面像
  # 「加设备」的那个，拿到随本机名走的链接（2026-11-16 踩过）。
  local -a _e=()
  local _x
  if [ ${#extras[@]} -gt 0 ]; then
    for _x in "${extras[@]}"; do _e+=(--extra "$_x"); done
  fi
  [ -n "$script" ] && _e+=(--script "$script")
  _dist_serve --timeout "$timeout" --port "$port" ${_e[@]+"${_e[@]}"}
}

_hub_take_off() {
  local cur saved
  cur=$(_hub_cur_name)
  saved=$(cat "$_HUB_STATE" 2>/dev/null)
  say "摘帽子"
  [ -n "$saved" ] || { warn "没有戴帽子的记录（$_HUB_STATE 不存在）"; echo "    如果你确定名字被改了，手工：tailscale set --hostname=<原名>"; return 1; }
  echo "    当前 $cur → 还原 $saved"
  "${TS[@]}" funnel reset >/dev/null 2>&1 && ok "funnel 配置已清"
  "${TS[@]}" set --hostname="$saved" >/dev/null 2>&1 || die "还原失败"
  rm -f "$_HUB_STATE"
  sleep 2
  ok "名字已还原：$(_hub_cur_name)"
  echo
  echo "  注意：摘帽后本机不再叫 $_HUB_NAME，那个域名暂时解析不到，"
  echo "        短链在这一段时间里打不开。"
  echo "        下次再戴、名字还是 $_HUB_NAME，短链原样复活，不用重新发。"
}

# ── 添加设备：起服务 → 打印安装命令 → 等它上线 ──────────────────────
# 一条命令替掉「make.py → serve.py → tailscale funnel → 手工发链接 →
# 肉眼盯控制台看有没有上线」这一串。等待是真的等：轮询 netmap 比对基线，
# 出现新节点就报出名字/IP/耗时 —— 不是打印个链接就结束。
#
# 判据都落在行为上：
#   · URL 取到 200 才算通（funnel 首次注册要几十秒，DNS 解析了不代表边缘挂上）
#   · 新设备 = netmap 里出现基线之外的节点 ID（不是"用户说装好了"）
#
# 一个必须知道的前提：本机自测不通**不代表**别人取不到。沙箱常有出站限制，
# 而新机器在真实网络上。所以自测失败只降级成提示，不中止。
_ENROLL_PID=""
# 分发服务的"所有权"锁。只放 PID，作用是让**清理**知道自己还算不算主人。
# 2026-11-13 实测的坑：换脚本时"停旧的、起新的"，旧进程收到 TERM 后 trap 照常跑，
# 于是它把**新进程**刚挂好的 funnel 关掉、把主机名也改回去 —— 屏幕上新窗口一片 ✓，
# 公网却 404。加锁之后，清理只在"锁还是我的 PID"时才动全局状态。
_ENROLL_LOCK=""
_ENROLL_TMPD=""
_ENROLL_FUNNEL=0

_enroll_cleanup() {
  # 先把锁看一遍：锁已经属于另一个进程（新一轮的分发），就**什么都别碰** ——
  # 尤其别关 funnel、别删别人的 tmpd。只收自己 fork 出去的那个 server。
  if [ -n "$_ENROLL_LOCK" ] && [ -s "$_ENROLL_LOCK" ]; then
    local _owner; _owner=$(cat "$_ENROLL_LOCK" 2>/dev/null)
    if [ -n "$_owner" ] && [ "$_owner" != "$$" ]; then
      [ -n "$_ENROLL_PID" ] && kill "$_ENROLL_PID" 2>/dev/null
      return 0
    fi
  fi
  [ -n "$_ENROLL_PID" ] && kill "$_ENROLL_PID" 2>/dev/null
  [ "$_ENROLL_FUNNEL" = "1" ] && "${TS[@]}" funnel --https=443 off >/dev/null 2>&1
  [ -n "$_ENROLL_TMPD" ] && rm -rf "$_ENROLL_TMPD"
  [ -n "$_ENROLL_LOCK" ] && rm -f "$_ENROLL_LOCK" 2>/dev/null
}

#
# ══════ 区 5 命令：分发（enroll / lend） ══════
#
# 分三层，方向固定，别再反过来（2026-11-16）：
#   _dist_serve  原语：起白名单服务 + Funnel + 打印命令 + 等上线。不认帽子、不改名。
#   cmd_lend     能力：把自己临时变成分发服务器（改名 hb-hub）→ _dist_serve → 摘帽
#   cmd_enroll   业务：加设备。默认转给 cmd_lend（短链才固定）；--no-hub 才裸调原语
#
# 上一版是反的：lend 调 enroll。于是「能力」里塞着整条业务流，而 enroll 对 lend
# 一无所知 —— 第一次接手的人只能按字面挑「加设备」，拿到随本机名走的链接
# （实测发出 desktop-sgl-4…，机器一改名就死）。方向反了，discoverability 就没救。
_dist_serve() {
  local port=8890 timeout=900 no_funnel=0 script=""
  local -a extras=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --port)      port="$2"; shift 2 ;;
      --timeout)   timeout="$2"; shift 2 ;;
      --script)    script="$2"; shift 2 ;;
      --extra)     extras+=("$2"); shift 2 ;;
      --no-funnel) no_funnel=1; shift ;;
      -h|--help)
        echo "用法（内部原语，日常请用 hb enroll / hb lend）"
        echo "      _dist_serve [--port N] [--timeout 秒] [--script 文件] [--extra 文件]... [--no-funnel]"
        echo
        echo "  起一个白名单 HTTP 服务（只发安装脚本、hb 自己和 --extra 指定的文件），用"
        echo "  Tailscale Funnel 挂到公网，打印几条安装命令，然后轮询 netmap 等新设备上线。"
        echo
        echo "  --port N        本地监听端口（默认 8890，Funnel 固定转发到 443）"
        echo "  --timeout 秒    最长等待（默认 900 = 15 分钟）"
        echo "  --script 文件   指定要分发的安装脚本（默认找 hb 旁边的 dist/setup.ps1）"
        echo "  --extra 文件    额外资产，可重复。挂在 /x/<文件名>，并在 /i 里自动指给安装脚本"
        echo "                  典型用途：把 37 MB 的 tailscale msi 带上，别让新机器去赌出网"
        echo "  --no-funnel     只起本地服务，不开公网（给 tailnet 内已有节点用）"
        return 0 ;;
      *) die "不认识的参数：$1（hb enroll --help）" ;;
    esac
  done

  command -v python3 >/dev/null 2>&1 || die "需要 python3 起本地服务（本机没有）"

  # 走到这里却没有帽子（--no-hub，或被内部直接调）：地址就绑在本机名上。
  # 它仍然能用，但会过期 —— 说清楚，别让人以为这就是标准做法。
  if [ -z "${_HUB_ORIG:-}" ] && [ "$no_funnel" -eq 0 ]; then
    warn "没戴帽子：短链绑在本机名上（https://<本机名>.<tailnet>.ts.net），本机改名即失效"
    echo "    想要固定的 https://${_HUB_NAME}.<tailnet>.ts.net：去掉 --no-hub 重跑"
  fi

  # 同一时刻只允许一个分发服务。两个并存时，先退出的那个会替后一个清场
  # （funnel off + 主机名还原），屏幕上看不出来，公网却直接 404。
  _ENROLL_LOCK="$HOME/.hb/enroll.lock"
  mkdir -p "$(dirname "$_ENROLL_LOCK")" 2>/dev/null
  if [ -s "$_ENROLL_LOCK" ]; then
    local _lp; _lp=$(cat "$_ENROLL_LOCK" 2>/dev/null)
    if [ -n "$_lp" ] && [ "$_lp" != "$$" ] && kill -0 "$_lp" 2>/dev/null; then
      die "已经有一个分发服务在跑（pid $_lp）。先 hb lend --off，或等它结束"
    fi
    warn "清掉上一轮的锁（pid ${_lp:-?} 已不在）"
  fi
  printf '%s' "$$" > "$_ENROLL_LOCK"

  # 清理从第一行输出就生效，不能等到起完服务。
  # 理由：`hb enroll | head -8` 里 head 读够就退出，我们下一次写 stdout 会收到
  # SIGPIPE。trap 注册得越晚，越可能死在"还没注册"的那一段 —— 2026-11-08 实测：
  # 它原本在 _enroll_serve_start 之后，而 `添加设备`/`没找到 setup.ps1` 都在它
  # 前面，head -8 正好在中间截断，于是 funnel 没关、hostname 留在帽子上。
  # PIPE 必须显式收：默认动作是直接终止，一条 EXIT 都不会跑。
  trap '_enroll_cleanup; eval "${_ENROLL_WRAP:-}"' EXIT INT TERM
  trap '_enroll_cleanup; eval "${_ENROLL_WRAP:-}"; exit 1' PIPE

  say "添加设备"
  net_up || { warn "网络未就绪，先修"; cmd_up quiet || die "修复失败"; }

  # ① 准备分发的文件
  local here win_src="" hb_src
  here=$(cd "$(dirname "$HB_SELF")" && pwd)
  hb_src="$HB_SELF"
  if [ -n "$script" ]; then
    win_src="$script"
  else
    # 给 Windows 新机器分发用的安装脚本：只看 hb 旁边和上一级，别去猜目录结构。
    # 找不到也能跑 —— 那就只分发 hb 自己（Linux / macOS 够用）。
    local c
    for c in "$here/dist/setup.ps1" \
             "$here/assets/setup.ps1" \
             "$here/../assets/setup.ps1" \
             "$here/setup.ps1"; do
      [ -s "$c" ] && { win_src="$c"; break; }
    done
  fi

  _ENROLL_TMPD=$(mktemp -d) || die "建不了临时目录"
  # MSYS：bash 的 /tmp 是 %TEMP%，而 Windows 版 python 把 "/tmp/x" 按**当前盘符**
  # 解析成 D:/tmp/x —— 同一个字符串指向两个不同目录，serve.py 必然 "No such file"。
  # 转成 C:/… 驱动路径后两边才指同一处。2026-11-16 实测：不转，enroll 连试 5 个
  # 端口全报 can't open file 'd:\tmp\tmp.xxx\serve.py'，而目录里文件是存在的。
  if hb_is_msys && command -v cygpath >/dev/null 2>&1; then
    _ENROLL_TMPD=$(cygpath -m "$_ENROLL_TMPD")
  fi
  local tmpd="$_ENROLL_TMPD"

  cp "$hb_src" "$tmpd/hb" 2>/dev/null || die "拷不出 hb 自身"
  chmod 644 "$tmpd/hb"

  # 把本机公钥一起放进分发包。作用是给 /l 脚本"预埋"授权 ——
  # 新机器拿到脚本的那一刻就把这把钥写进它自己的 authorized_keys，
  # 不再依赖"它能不能顺利跑完 hb up"。用户的原话是"让 hb-hub 代劳复制一份过去"，
  # 但代劳的通道不能是 ssh（那时新机器还没授权，ssh 根本进不去），
  # 只能是**它自己来取的这份脚本**。
  local _pk=""
  _pk=$(cat "$SSH_DIR/$SSH_KEY_NAME.pub" 2>/dev/null | head -1)
  [ -n "$_pk" ] || _pk=$(ssh-keygen -y -f "$SSH_DIR/$SSH_KEY_NAME" 2>/dev/null | head -1)
  if [ -n "$_pk" ]; then
    printf '%s\n' "$_pk" > "$tmpd/pubkey"
    chmod 644 "$tmpd/pubkey"
  fi
  if [ -n "$win_src" ] && [ -s "$win_src" ]; then
    cp "$win_src" "$tmpd/setup.ps1" && chmod 644 "$tmpd/setup.ps1"
    ok "Windows 安装脚本  $(stat -c%s "$tmpd/setup.ps1" 2>/dev/null || echo '?') 字节  ← $win_src"
  else
    warn "没找到 setup.ps1 —— 只分发 hb 自己（Linux / macOS 够用）"
    printf '%s' "404" > "$tmpd/setup.ps1.missing"
  fi
  ok "hb 自身  $(stat -c%s "$tmpd/hb") 字节（新机器拿到它就能 hb up）"

  # ③ 额外资产（--extra）。
  # 存在的理由：2026-11-13 那台新机器装不上 Tailscale —— 官方 37 MB 包在它那儿
  # 卡在「取响应头 30 秒超时」，而它其实能出网（同机浏览器下到了 1.3 MB 的 exe）。
  # 当时的出路是人肉：本机下包 → 手工 `tailscale funnel --set-path` → 手工改脚本。
  # 那是一次性的，换台机器、换个版本就得重来一遍。
  # 做成参数之后，「给新机器带一个包」是一条命令：包由分发端提供，新机器不用出网。
  local _x _bn
  if [ ${#extras[@]} -gt 0 ]; then
    mkdir -p "$tmpd/pkg" || die "建不了 pkg 目录"
    for _x in "${extras[@]}"; do
      [ -f "$_x" ] || die "额外文件不存在：$_x"
      _bn=$(basename "$_x")
      cp "$_x" "$tmpd/pkg/$_bn" || die "拷不进 $_x"
      chmod 644 "$tmpd/pkg/$_bn" 2>/dev/null || true
      ok "额外资产  $_bn  $(stat -c%s "$tmpd/pkg/$_bn" 2>/dev/null || echo '?') 字节  → /x/$_bn"
    done
  fi

  # ② 白名单服务。不用 `python3 -m http.server`：它会列目录、
  #    不声明 charset（PS 5.1 的 irm 会按 Latin-1 解码，中文注释立刻乱码）。
  cat > "$tmpd/serve.py" <<'PY'
import http.server, os, re, sys

root, port = sys.argv[1], int(sys.argv[2])

def blob(name):
    p = os.path.join(root, name)
    try:
        return open(p, "rb").read()
    except OSError:
        return None

class H(http.server.BaseHTTPRequestHandler):
    server_version = "hb-enroll/1.0"
    def log_message(self, *a):
        pass
    def _send(self, body, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            # 客户端（或它前面的 curl --max-time）半路走了。这是正常现象，
            # 不是错误 —— 但默认实现会打一整段 traceback，把短链本身冲掉。
            pass
    def _send_file(self, path):
        # 大文件按块发，别把 37 MB 读进内存再写一遍；慢速客户端也不会把进程撑爆。
        # 支持 Range：这条链路经常跑在慢速/抖动的网络上，断了能续才谈得上"长期"。
        # 不支持 Range 也不致命 —— 客户端的判据是状态码（200 就从头来），不会写坏。
        size = os.path.getsize(path)
        start, end = 0, size - 1
        rng = self.headers.get("Range") or ""
        partial = False
        m = re.match(r"bytes=(\d*)-(\d*)$", rng.strip())
        if m and size > 0:
            if m.group(1):
                start = int(m.group(1))
                if m.group(2):
                    end = min(int(m.group(2)), size - 1)
            elif m.group(2):                      # bytes=-N：最后 N 字节
                start = max(0, size - int(m.group(2)))
            if start <= end and start < size:
                partial = True
            else:
                self.send_error(416, "range not satisfiable")
                return
        length = end - start + 1
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        if partial:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            with open(path, "rb") as f:
                f.seek(start)
                left = length
                while left > 0:
                    chunk = f.read(min(262144, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass
    def do_HEAD(self):
        # curl -I 是最常用来判"通不通"的动作，而 BaseHTTPRequestHandler 默认
        # 对它回 501 —— 屏幕上是「501 Unsupported method」，看着像资产坏了。
        # 这里按 GET 的白名单回头部长度，不发送 body。
        name = self.path.lstrip("/").split("?")[0]
        p = None
        if name.startswith("x/"):
            fn = os.path.basename(name.split("/", 1)[1])
            cand = os.path.join(root, "pkg", fn)
            if fn and os.path.isfile(cand):
                p = cand
        elif name in ("hb", "hb.bin"):
            p = os.path.join(root, "hb")
            if not os.path.isfile(p):
                p = None
        elif name in ("", "a", "w", "win", "setup.ps1"):
            p = os.path.join(root, "setup.ps1")
            if not os.path.isfile(p):
                p = None
        if p:
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(os.path.getsize(p)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return
        if name in ("i", "install", "l", "linux", "ubuntu", "debian", "sh"):
            self.send_response(200)
            self.end_headers()
            return
        self.send_error(404, "not in whitelist")
    def do_GET(self):
        name = self.path.lstrip("/").split("?")[0]
        # 短别名是为了让人手打：/w Windows、/l Linux，各一个字母
        if name in ("", "a", "w", "win", "setup.ps1"):
            data = blob("setup.ps1")
            if data is None:
                self.send_error(404, "no setup.ps1 staged")
                return
            return self._send(data, "text/plain; charset=utf-8")
        if name in ("hb", "hb.bin"):
            data = blob("hb")
            if data is None:
                self.send_error(404, "hb not staged")
                return
            return self._send(data, "application/octet-stream")
        if name in ("id", "hb-id"):
            # 就绪判据：把 hb 写进来的 nonce 原样吐回去。
            # 「端口有人应答」不等于「这次的服务起来了」—— 旧进程会替你应答。
            data = blob("id")
            if data is None:
                self.send_error(404, "no id")
                return
            return self._send(data, "text/plain; charset=utf-8")
        if name.startswith("x/"):
            # --extra 的资产。只认 pkg/ 下的**文件名**：basename 兜住路径穿越，
            # 白名单是"启动时拷进 pkg/ 的那些"，不是"磁盘上任意文件"。
            fn = os.path.basename(name.split("/", 1)[1])
            p = os.path.join(root, "pkg", fn)
            if not fn or not os.path.isfile(p):
                self.send_error(404, "no such asset")
                return
            return self._send_file(p)
        if name in ("i", "install", "is", "ws"):
            # 四条引导，区别只在"大文件从哪来"和"要不要先装 7"：
            #   /i  = 包走本机（funnel），含 PowerShell 7
            #   /is = 包走本机，跳过 7
            #   /ws = 包走公网（新机器自己的带宽），跳过 7
            # 为什么要有 /ws：2026-11-13 实测这条 Funnel 只有约 40 KB/s
            # （7.6 MB 传了三分多钟），37 MB 要十几分钟、104 MB 更不用提。
            # 与其把大文件挤进这根管子，不如只发 17 KB 的脚本，包让它自己下 ——
            # 脚本里的 curl 腿带断点续传和停滞判死，比"发不出去"强。
            skip_ps    = name in ("is", "ws")
            use_mirror = name != "ws"
            # /i = /w 的"带镜像"版本：先把安装包的地址指到本机，再拉原始脚本执行。
            # 为什么要有这一层：新机器的出网靠不住（37 MB 卡 30 秒），而它到
            # 分发端的链路已经证明是通的（它刚取过 /w）。所以大文件走这条链路，
            # 短链依旧只有一条、依旧好念。
            try:
                base = open(os.path.join(root, "base_url")).read().strip()
            except OSError:
                self.send_error(503, "base url not ready")
                return
            msi = ""
            psh = ""
            pkgdir = os.path.join(root, "pkg")
            if use_mirror and os.path.isdir(pkgdir):
                for f in sorted(os.listdir(pkgdir)):
                    if not f.lower().endswith(".msi"):
                        continue
                    # 按文件名分流：7 的包装给 TS_PWSH_MSI_URL，其余当 tailscale 包。
                    # 两个都带上时，新机器两样都不用出网。
                    low = f.lower()
                    if "powershell" in low or "pwsh" in low or low.startswith("ps7"):
                        psh = "%s/x/%s" % (base, f)
                    elif not msi:
                        msi = "%s/x/%s" % (base, f)
            if use_mirror and not msi and not psh:
                self.send_error(404, "没有 msi 资产：hb enroll --extra <tailscale.msi>（或改用 /ws，包走公网）")
                return
            lines = ["# hb: 分发端生成的引导 —— 设好环境变量，再把原始安装脚本拉下来执行"]
            if use_mirror:
                lines.append("# 大文件走本机，新机器不需要对外下载")
            else:
                lines.append("# 大文件走公网（新机器自己的带宽）；本机只发 17 KB 的脚本")
            if msi:
                lines.append("$env:TS_MSI_URL = '%s'" % msi)
                lines.append("Write-Host \"  tailscale 包: $env:TS_MSI_URL\" -ForegroundColor DarkGray")
            if psh:
                lines.append("$env:TS_PWSH_MSI_URL = '%s'" % psh)
                lines.append("Write-Host \"  PowerShell 7 包: $env:TS_PWSH_MSI_URL\" -ForegroundColor DarkGray")
            if skip_ps:
                lines.append("$env:TS_PWSH_SKIP = '1'")
                lines.append("Write-Host '  本次跳过 PowerShell 7（先把网通上；事后可 winget 补）' -ForegroundColor Yellow")
            # 取正文这一步**先走 curl.exe**：新机器上实测过 curl 能拿到 200，
            # 而 PowerShell 的 irm/HttpWebRequest 在 5.1 上对同一条链路报过
            # 「基础连接已经关闭」。既然整条链已经用 curl 取到本文件了，
            # 就别在最后一步换回那个不靠谱的栈。
            lines.append("$w = Join-Path $env:TEMP 'hb-w.ps1'")
            lines.append("$curl = Join-Path $env:SystemRoot 'System32\\curl.exe'")
            lines.append("if (Test-Path $curl) { & $curl -fsSL '%s/w' -o $w }" % base)
            lines.append("if (-not (Test-Path $w)) { Invoke-RestMethod '%s/w' -OutFile $w }" % base)
            lines.append("$src = Get-Content -Raw $w")
            lines.append("& ([scriptblock]::Create($src))")
            body = ("\n".join(lines) + "\n").encode()
            return self._send(body, "text/plain; charset=utf-8")
        if name in ("l", "linux", "ubuntu", "debian", "sh"):
            # Ubuntu / Debian / Jetson 的引导脚本。和 Windows 那条不是同一件事：
            # Windows 给一段 PowerShell（irm | iex），Linux 给一段 sh（curl | sudo bash），
            # 走同一个端口、用路径区分系统 —— 两条链接可以同时挂在外面。
            # base_url 由 hb 在 funnel 通了之后写进来；没写就说明还没就绪
            try:
                base = open(os.path.join(root, "base_url")).read().strip()
            except OSError:
                self.send_error(503, "base url not ready")
                return
            # 分发：把 hb 的公钥**预埋**进新机器。这段跑在 hb 之前，
            # 所以哪怕后面下载 hb 失败、hb up 半路中断，这台机器的
            # root（和 sudo 用户）也已经可以被网内其他节点 ssh 进来了。
            # 这是唯一不依赖"新机器先能 ssh"的通道 —— 别处的推送都要先登进去，
            # 而它此刻还没授权，鸡生蛋。
            try:
                pk = " ".join(open(os.path.join(root, "pubkey")).read().split()[:2])
            except OSError:
                pk = ""
            pk_block = ""
            if pk:
                pk_block = (
                    "PK='%s'\n" % pk
                    + 'if [ -n "$PK" ]; then\n'
                    # $HOME 是 root（脚本由 sudo bash 跑）；SUDO_USER 的家目录
                    # 也写一份 —— Jetson 官方镜像是 ubuntu 用户，人不一定用 root 登。
                    + '  for H in "$HOME" "$(getent passwd "${SUDO_USER:-root}" 2>/dev/null | cut -d: -f6)"; do\n'
                    + '    [ -n "$H" ] && [ -d "$H" ] || continue\n'
                    + '    mkdir -p "$H/.ssh" 2>/dev/null || continue\n'
                    + '    chmod 700 "$H/.ssh" 2>/dev/null || true\n'
                    + '    touch "$H/.ssh/authorized_keys" 2>/dev/null || continue\n'
                    + '    chmod 600 "$H/.ssh/authorized_keys" 2>/dev/null || true\n'
                    + '    grep -qxF "$PK" "$H/.ssh/authorized_keys" 2>/dev/null || echo "$PK" >> "$H/.ssh/authorized_keys"\n'
                    + '  done\n'
                    + '  echo "  已埋入公钥：网内其他节点可直接 ssh 进这台"\n'
                    + 'fi\n'
                )
            body = (
                "#!/bin/sh\n"
                "# 新设备入网 —— Ubuntu / Debian / Jetson\n"
                "# 需要 root：curl -fsSL <本地址> | sudo bash\n"
                "set -eu\n"
                # 这一步必须在 hb 之前做：hb 的官方安装脚本与包管理器都依赖
                # 源可用。Jetson 上常见到"能 ping 通、但 apt 是坏的"，
                # 而报错会落在 tailscale 安装上，看着像 tailscale 的问题。
                "if [ \"$(id -u)\" -ne 0 ]; then\n"
                '  echo "  要 root：curl -fsSL <本地址> | sudo bash" >&2\n'
                "  exit 1\n"
                "fi\n"
                "for c in curl tar gzip; do\n"
                "  command -v $c >/dev/null 2>&1 && continue\n"
                '  echo "  缺 $c，用 apt 补"\n'
                "  if command -v apt-get >/dev/null 2>&1; then\n"
                "    apt-get update -qq && apt-get install -y $c || {\n"
                '      echo "  apt 装 $c 失败 —— 先修源：sudo apt-get update" >&2; exit 1; }\n'
                "  else\n"
                '    echo "  这台不是 apt 系统，缺 $c 请手工装" >&2; exit 1\n'
                "  fi\n"
                "done\n"
                'BASE="%s"\n' % base
                + pk_block
                + 'echo "  系统 $(uname -sr)   架构 $(uname -m)"\n'
                'curl -fsSL "$BASE/hb" -o /tmp/hb\n'
                "chmod +x /tmp/hb\n"
                "exec /tmp/hb up\n"
            ).encode()
            return self._send(body, "text/plain; charset=utf-8")
        self.send_error(404, "not in whitelist")

# 绑定地址由 hb 传：默认只给本机（funnel 是 tailscaled 从本机代理进来的，
# 127.0.0.1 就够，也少一层暴露）；--no-funnel 时必须 0.0.0.0，否则网内别的
# 机器连 100.x:port 会被直接拒 —— 而屏幕上打印的地址看起来完全正常。
bind = sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1"
# 线程版：单线程 HTTPServer 在有人慢速下载时会把后面的请求全堵住，
# 而短链一出问题最可能的表现就是"连上了但一直转圈"。
# daemon_threads 让 Ctrl-C 时不被残留连接卡住退出。
class S(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


S((bind, port), H).serve_forever()
PY

  # 起服务并等它就绪；绑哪个地址由调用方决定
  _enroll_serve_start() {
    local bindaddr="$1" j got
    python3 "$tmpd/serve.py" "$tmpd" "$port" "$bindaddr" &
    _ENROLL_PID=$!
    for j in $(seq 1 20); do
      got=$(curl -sS --max-time 2 "http://127.0.0.1:$port/id" 2>/dev/null)
      # 判据不是「端口有人应答」，是「应答的是我这次起的进程」。
      # 只看 /hb 会骗人：上一轮没清干净的 server 也回 200，于是 bind 失败被
      # 判成"起好了"，funnel 指过去、新的 /i /x 一律 404 —— 2026-11-13 就这么踩的。
      [ "$got" = "$_ENROLL_NONCE" ] && return 0
      if [ -n "$got" ]; then
        warn "端口 $port 上应答的不是本次服务（旧进程没清干净）"
        return 1
      fi
      sleep 0.5
    done
    return 1
  }
  # funnel 模式绑 127.0.0.1 就够（tailscaled 从本机代理进来）。
  # --no-funnel 必须绑 0.0.0.0 —— 2026-11-03 在 sgl 实测：绑 127.0.0.1 时，
  # 打印出去的 http://100.x.y.z:port 连本机自己都连不上（curl 7，
  # netstat 只有 127.0.0.1:8890 LISTENING），而界面上看不出任何异常。
  local bind=127.0.0.1 i
  [ $no_funnel -eq 1 ] && bind=0.0.0.0
  # nonce：写进服务目录，由 /id 原样吐回来。有了它，"起好了"才有判据 ——
  # 否则端口被上一轮的旧 server 占着时，屏幕上看不出任何异常。
  _ENROLL_NONCE="hb-$(date +%s)-$$"
  printf '%s' "$_ENROLL_NONCE" > "$tmpd/id"
  local _tries=0
  while :; do
    if _enroll_serve_start "$bind"; then break; fi
    kill "$_ENROLL_PID" 2>/dev/null
    wait "$_ENROLL_PID" 2>/dev/null
    _tries=$((_tries + 1))
    if [ $_tries -ge 5 ]; then
      die "起服务失败（连试 5 个端口）。查占用：netstat -ano | findstr :889"
    fi
    warn "换成端口 $((port + 1)) 再试"
    port=$((port + 1))
  done
  # 别直接 `trap _enroll_cleanup EXIT`：trap 是覆盖而不是叠加，外层（hb lend）
  # 先注册的收尾会被这一句顶掉。2026-11-05 实测：lend 退出后 funnel 关了、
  # 服务停了，hostname 却停在 hb-hub 没还原 —— 就是因为这个覆盖。
  # 用 _ENROLL_WRAP 记着外层要补跑的收尾，退出时一起跑。
  # （trap 本身已在函数开头注册，这里不再重复 —— 见上面那段注释。）

  kill -0 "$_ENROLL_PID" 2>/dev/null || die "本地服务没起来（端口 $port 被占？）"
  ok "本地服务  http://127.0.0.1:$port  (pid $_ENROLL_PID)"

  # ③ 挂公网
  local base="" dnsname=""
  if [ $no_funnel -eq 0 ]; then
    if "${TS[@]}" funnel --bg "$port" >/dev/null 2>&1; then
      _ENROLL_FUNNEL=1
      dnsname=$("${TS[@]}" status --json 2>/dev/null | tr -d '\r' \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null)
      [ -n "$dnsname" ] && base="https://$dnsname"
      # 节点名是 12 位 hex（如 5d5a385d1b37）时，funnel 域名就是这串哈希。
      # 新注册的沙箱节点会因为报不上有意义的主机名而被 tailscale 这样命名，
      # 短链地址每次都变。这不是 bug，但发给人很像 bug —— 直说，并给改名的法子。
      case "${dnsname%%.*}" in
        *[!0-9a-f]*|"") : ;;
        *)
          warn "本机在 tailnet 里叫 ${dnsname%%.*}（哈希），所以短链域名是这串数字"
          echo "    tailnet 里的名字决定域名，不是你装的时候起的名字。想让地址稳定好认："
          echo "      tailscale set --hostname=<名字>     # 改名后域名变成 <名字>.${dnsname#*.}"
          echo "    或者用 tailscale admin 控制台改这台机器的 Machine name"
          ;;
      esac
      # 域名和 funnel 配置是绑死的：改了 hostname 之后，tailscaled 里那条
      # serve 配置仍然指向旧域名，旧域名还能通（所以看起来"没事"），
      # 而新域名要等证书签发。2026-11-05 实测：改名后旧域名 200、新域名 000。
      # 所以这里比对「配置里写的域名」与「当前 Self 的域名」，不一致就提示，
      # 并给出清配置重挂的一行命令 —— 不然人会以为新域名坏了。
      local _cfg_dns
      _cfg_dns=$("${TS[@]}" funnel status 2>/dev/null | tr -d '\r' | grep -o 'https://[^ ]*\.ts\.net' | head -1 | sed 's#https://##')
      if [ -n "$_cfg_dns" ] && [ "$_cfg_dns" != "$dnsname" ]; then
        warn "funnel 配置里写的还是旧域名 $_cfg_dns（本机已改名成 $dnsname）"
        echo "    旧域名现在还通，但它是历史残留；要换成新域名："
        echo "      tailscale funnel reset && hb enroll"
      fi
    else
      warn "funnel 开不起来（tailnet 未启用 Funnel，或本机无权限）→ 退回 tailnet 内地址"
    fi
  fi
  if [ -z "$base" ]; then
    # 退回网内地址。如果刚才绑的是 127.0.0.1（funnel 模式的默认），必须重绑：
    # 否则下面打印的地址只有本机能连，而屏幕上看起来一切正常。
    if [ "$bind" = "127.0.0.1" ]; then
      kill "$_ENROLL_PID" 2>/dev/null
      wait "$_ENROLL_PID" 2>/dev/null
      bind=0.0.0.0
      _enroll_serve_start "$bind" || die "重绑 0.0.0.0 失败（端口 $port 被占？）"
    fi
    local tsip
    tsip=$("${TS[@]}" ip -4 2>/dev/null | tr -d '\r' | head -1)
    base="http://${tsip:-127.0.0.1}:$port"
    printf '%s' "$base" > "$tmpd/base_url"
    warn "只在本 tailnet 内可达 —— 新机器还没入网，够不着"
    echo "    想给未入网的机器用，需要 Funnel；或者用现有短链指向 $base/a"
    # 自测必须打这个地址，不是 127.0.0.1：绑错或被防火墙拦，只有这一步看得出来
    local pc
    pc=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 4 "$base/hb" 2>/dev/null)
    if [ "$pc" = "200" ]; then
      echo "    自测：本机从 $base 取到 200"
    elif ! ip -4 addr 2>/dev/null | grep -q -- "$tsip"; then
      # 用户态 tailscale（沙箱就是这样）：100.x 不在任何网卡上，连本机都连不到自己。
      # 这时 --no-funnel 没有意义，硬打会把人引去查防火墙。
      warn "本机是用户态 tailscale —— $tsip 不在任何网卡上，网内地址连自己都连不到"
      echo "    这台机器只能走 Funnel：去掉 --no-funnel 重跑"
    else
      warn "本机从 $base 取不到（http=${pc:-000}）—— 网内别的机器多半也取不到"
      echo "    常见原因：防火墙拦入站（Windows 首次监听常被静默拦掉），或该 IP 不是本机"
    fi
  else
    printf '%s' "$base" > "$tmpd/base_url"
    # 本机 DNS 若把这个域名解析进 198.18.0.0/15（Clash / Mihomo 的 fake-ip 段），
    # 本机自测**永远**拿不到 200：TUN 先本地 accept、再向上游拨，TLS 当场断。
    # 2026-11-16 实测：desktop-sgl-4…ts.net → 198.18.0.116，000，白等 45 轮 ≈ 5 分钟，
    # 而且那句"本机自测取不到"会让人以为服务坏了 —— 判据错了，不是环境坏了。
    # 现在的口径：能自测才自测；不能就借网内一台节点验；都验不了就明说"给不出判据"。
    local hij=""
    hij=$(python3 -c 'import socket,sys
try: print(socket.gethostbyname(sys.argv[1]))
except Exception: print("")' "${base#*//}" 2>/dev/null | tr -d '\r')
    case "$hij" in
      198.18.*|198.19.*) : ;;
      *) hij="" ;;
    esac

    # 借另一台在线节点验一次 —— 本机 DNS 被劫持时，这是唯一可信的判据。
    # 两条经验都来自 2026-11-16 的实测：
    #   ① 不用 _peer_list：它按 status 文本第 5 列要求 *idle*/*active*，而 tailscale
    #      经常把在线节点写成 "-"（没有活跃会话），于是整张表被滤空，报"没人能代验"
    #      —— 又一次假阴性。这里直接用 status --json 的 Online 字段。
    #   ② 账号要走 host_ssh_target（别名和 user= 记在 hosts 文件里），
    #      不然会拼出 "@100.108.73.56" 这种必然失败的地址。
    #   ③ Funnel 边缘挂载要几十秒，一次不成不代表不通 —— 少量重试，别急着下结论。
    _enroll_peer_code() {
      local nm ip tgt out u try
      local -a SO=(); while IFS= read -r l; do SO+=("$l"); done < <(_ssh_opts 8)
      local peers
      peers=$("${TS[@]}" status --json 2>/dev/null | tr -d '\r' | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
selfd = d.get("Self") or {}
self_ip = (selfd.get("TailscaleIPs") or [""])[0]
for v in (d.get("Peer") or {}).values():
    if not v.get("Online"): continue
    ips = v.get("TailscaleIPs") or [""]
    if ips[0] == self_ip: continue
    if v.get("OS") != "linux": continue      # 只借能跑 POSIX shell 的节点
    print("%s %s" % (v.get("HostName") or "", ips[0]))
' 2>/dev/null)
      for try in 1 2 3 4 5 6 7 8 9 10; do
        while read -r nm ip; do
          [ -n "$nm" ] || continue
          case " $_ENROLL_TRIED " in *" $nm "*) ;; *) _ENROLL_TRIED="$_ENROLL_TRIED $nm" ;; esac
          tgt=$(host_ssh_target "$nm" 2>/dev/null) || tgt=""
          if [ -z "$tgt" ]; then
            u=$(_ssh_user_of "$nm" 2>/dev/null); [ -n "$u" ] || u=root
            tgt="$u@$ip"
          fi
          out=$(ssh ${SO[@]+"${SO[@]}"} "$tgt" \
            "curl -sS -o /dev/null -w '%{http_code}' --max-time 8 '$base/hb'" 2>/dev/null \
            | tr -d '\r' | tail -1)
          [ "$out" = "200" ] && { printf '%s' "$nm"; return 0; }
        done <<< "$peers"
        [ -n "$peers" ] || return 1
        [ "$try" -lt 3 ] && sleep 6
      done
      return 1
    }

    local code="" peer=""
    _ENROLL_TRIED=""      # set -u：没初始化时第一次拼接就报 unbound（2026-11-16 实测）
    if [ -n "$hij" ]; then
      printf '    本机自测无意义（fake-ip），改用网内节点验证，等 Funnel 边缘挂载…\n'
      peer=$(_enroll_peer_code) || peer=""
      if [ -n "$peer" ]; then
        ok "公网可达  $base  （本机 DNS 被劫持成 $hij，改用 $peer 验证：200）"
        code=200
      else
        warn "本机把 $base 的域名解析成 $hij（代理 fake-ip）—— 本机自测不可能通"
        if [ -n "${_ENROLL_TRIED// /}" ]; then
          echo "    已借网内节点验证（${_ENROLL_TRIED# }，共 10 轮）仍未取到 200"
          echo "    本轮改由外部判据：从任意外网设备 curl -I $base/hb"
        else
          echo "    也没有别的在线节点可以代验，外部到不到这里给不出判据"
          echo "    想确认：从任意外网设备 curl -I $base/hb"
        fi
        code="skip"
      fi
    fi
    if [ -z "$code" ]; then
      # 首次注册要几十秒：DNS 解析了不代表边缘挂上（pitfalls 记过 8 次只有 1 次成功）
      for i in $(seq 1 45); do
        code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$base/hb" 2>/dev/null)
        [ "$code" = "200" ] && break
        sleep 2
      done
      if [ "$code" = "200" ]; then
        ok "公网可达  $base  （自测 200）"
      else
        # 自测失败也可能只是本机出站被限 —— 交给节点复验，别急着说"取不到"
        peer=$(_enroll_peer_code) || peer=""
        if [ -n "$peer" ]; then
          ok "公网可达  $base  （本机 $code，改用 $peer 验证：200）"
        else
          warn "本机自测取不到（最后一次 $code），也没有节点能代验"
          echo "    Funnel 首次注册要几十秒；本机出站常被限，不影响外部访问"
          echo "    想确认：从任意外网设备 curl -I $base/hb"
        fi
      fi
    fi
  fi

  # ④ 三种形态的安装命令
  echo
  say "发这几条给新机器"
  if [ -s "$tmpd/setup.ps1" ]; then
    local _msi=""
    [ -d "$tmpd/pkg" ] && _msi=$(ls "$tmpd/pkg" 2>/dev/null | grep -i '\.msi$' | head -1)
    if [ -n "$_msi" ]; then
      printf '  Windows（管理员 PowerShell）—— 带镜像，安装包走本机，不赌新机器的出网\n'
      printf '    irm %s/i | iex\n\n' "$base"
      printf '  安装包直链（对方要手工装时用）\n'
      local _fa
      for _fa in $(ls "$tmpd/pkg" 2>/dev/null | grep -i '\.msi$'); do
        printf '    %s/x/%s\n' "$base" "$_fa"
      done
      printf '\n'
    else
      printf '  Windows（管理员 PowerShell）\n'
      printf '    irm %s/w | iex\n\n' "$base"
    fi
  fi
  printf '  Ubuntu / Debian / Jetson（root，一条命令）\n'
  printf '    curl -fsSL %s/l | sudo bash\n\n' "$base"
  printf '  只验通不通（不装任何东西）\n'
  printf '    curl -I %s/hb\n' "$base"

  # ④½ 顺手把公钥名单同步一轮。注册时这台就是"当时在线的机器"，
  # 新机器之后 `hb up` 会从这里拿到它缺的那几把 —— 用户说的"让 hb-hub 代劳"。
  if net_up 2>/dev/null; then
    cmd_sync_keys >/dev/null 2>&1 && ok "公钥名单已同步（新机器可从本机取）" || true
  fi

  # ⑤ 基线快照，然后真的等
  local base_ids newinfo deadline t0
  base_ids=$("${TS[@]}" status --json 2>/dev/null | tr -d '\r' | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
print(" ".join((d.get("Peer") or {}).keys()))' 2>/dev/null)
  t0=$(date +%s)
  deadline=$(( t0 + timeout ))

  echo
  local limit_txt
  if [ "$timeout" -ge 60 ]; then limit_txt="$((timeout / 60)) 分钟"; else limit_txt="${timeout} 秒"; fi
  local reported=" "
  say "等新设备上线（最多 $limit_txt，Ctrl-C 退出并清理）"
  echo "    判据：netmap 里出现基线之外的节点，不是「你说装好了」"
  printf '    '
  while [ "$(date +%s)" -lt "$deadline" ]; do
    newinfo=$("${TS[@]}" status --json 2>/dev/null | tr -d '\r' | python3 -c '
import sys, json
base = set(sys.argv[1].split())
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
for k, v in (d.get("Peer") or {}).items():
    if k in base:
        continue
    ips = v.get("TailscaleIPs") or ["?"]
    print("%s|%s|%s|%s" % (v.get("HostName", "?"), ips[0], v.get("OS", "?"), v.get("Online")))
' "$base_ids" 2>/dev/null)
    if [ -n "$newinfo" ]; then
      echo
      local hn ip os on el
      hn=$(printf '%s' "$newinfo" | head -1 | cut -d'|' -f1)
      ip=$(printf '%s' "$newinfo" | head -1 | cut -d'|' -f2)
      os=$(printf '%s' "$newinfo" | head -1 | cut -d'|' -f3)
      on=$(printf '%s' "$newinfo" | head -1 | cut -d'|' -f4)
      el=$(( $(date +%s) - t0 ))
      # 已经报过、但还没打通授权的，不要每 4 秒刷一遍
      if printf '%s' "$reported" | grep -qF " $ip "; then
        printf '.'; sleep 4; continue
      fi
      ok "新设备上线  $hn  $ip  $os  用时 ${el}s"
      [ "$on" = "True" ] || warn "它已入网但当前显示离线 —— 可能刚断，或 netmap 还没刷新"

      # 摘帽之前把名单交出去 —— 摘了之后再推，就等于让新机器自己去猜谁在线。
      if _push_keys_to_new "$ip" "$hn"; then
        echo
        echo "  下一步："
        echo "    hb $hn \"hostname\"            # 直接调它"
        echo "    hb hosts add $hn $ip         # 起个别名，以后不用记 IP"
        return 0
      fi

      # 推不进去 = 它还没被授权（跑的多半是旧版 hb）。这时候**不能摘帽子**：
      # 帽子是它唯一还能拿到授权脚本的地方，一摘就断在"入网了但进不去"。
      # 所以记住它，继续等剩余时间，并把该跑的那条命令给出来。
      reported="$reported $ip "
      echo
      echo "  它在网内了，但 ssh 进不去 —— 说明它本地还没有这把公钥。"
      echo "  帽子继续戴着。在它上面跑这一条（会先埋公钥，再下载 hb）："
      echo
      printf '    curl -fsSL %s/l | sudo bash\n' "$base"
      echo
      echo "  跑完本机会自动发现并退出；想强制结束：Ctrl-C（会自动摘帽）"
      printf '    '
      sleep 4
      continue
    fi
    printf '.'
    sleep 4
  done
  echo
  bad "等了 $limit_txt 没有新设备上线"
  echo "    可能：① 命令没发出去 / 发错了 URL"
  echo "          ② 新机器上 tailscale 装失败（看它那边的报错）"
  echo "          ③ 它入网了但用了别的 tailnet（authkey 对不上）"
  echo "    想延长：hb enroll --timeout 1800；只想查现有节点：hb list"
  return 1
}

# ── 业务：加设备（enroll） ──────────────────────────────────────────
# 这一层只决定一件事：要不要帽子，然后把活交给下面那层。
#   默认 → cmd_lend（能力层）：先改名 hb-hub、挂 funnel，再分发 —— 短链才固定
#   --no-hub → 裸调 _dist_serve：地址绑本机名，能用但会过期
#   --no-funnel 隐含 --no-hub：没开公网就没有公网地址，白改一次名纯属副作用
# 这样"第一次接手的人按字面挑加设备"也能拿到稳定链接 —— 稳定性不靠人记得，
# 靠默认值。
cmd_enroll() {
  local no_hub=0
  local -a pass=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-hub)    no_hub=1; shift ;;
      --no-funnel) no_hub=1; pass+=(--no-funnel); shift ;;
      --port|--timeout|--script|--extra) pass+=("$1" "$2"); shift 2 ;;
      -h|--help)
        echo "用法: hb enroll [--timeout 秒] [--port N] [--extra 文件]... [--no-hub]"
        echo "      hb enroll --no-hub --no-funnel      # 只给 tailnet 内已有节点用"
        echo
        echo "  加设备：起白名单服务 + 挂公网 + 打印安装命令 + 等它上线。"
        echo
        echo "  默认先 hb lend 戴上帽子（本机改名 hb-hub），所以短链是固定的"
        echo "  https://$_HUB_NAME.<tailnet>.ts.net —— 发一次，以后换机器也不变。"
        echo "  帽子被占（别人正戴着、或一台离线机器占着名字）时会明确报出来，不会静默降级。"
        echo
        echo "  --timeout 秒    等多久（默认 900 = 15 分钟）"
        echo "  --port N        本地监听端口（默认 8890）"
        echo "  --extra 文件    额外资产，可重复（典型：tailscale 的 msi，别让新机赌出网）"
        echo "  --no-hub        不戴帽子：短链绑本机名，改名即失效"
        echo "  --no-funnel     只起本地服务（隐含 --no-hub）"
        return 0 ;;
      --off)       cmd_lend --off; return 0 ;;
      *) die "不认识的参数：$1（hb enroll --help）" ;;
    esac
  done

  if [ "$no_hub" -eq 1 ]; then
    _dist_serve ${pass[@]+"${pass[@]}"}
    return $?
  fi
  cmd_lend ${pass[@]+"${pass[@]}"}
}
# ══════ 区 6 命令：公钥名单同步 ══════
#
# ══ 公钥同步：不在线的机器开机后，从当时在线的机器补齐 ════════════
#
# 场景（用户原话）："注册机器时不在线的机子，只能从其他当时在线的机器获得密钥"。
# 所以做不做这件事，取决于**现在还在不在帽子/在不在线**，不是凭空定时跑。
#
# 一个必须处理的死结：新机器的 sgl 不通，是因为它的 authkey 是**单次的**，
# 谁先把它用掉，谁就挤占了它。用户的做法是"让 hb-hub 代劳"：
# 戴帽子那台是注册时唯一被信任的中间人，它把新机器的公钥带到全网。
# 所以同步的**发起方**永远选一台在线且 ssh 得通的（自己就是 hb-hub 时就用自己）。
HB_KEYS_TAG='# managed by hb sync-keys'

# ssh 的公共选项：不交互、不卡死、代理走能用的那条
_ssh_opts() {
  local ct=${1:-25}
  local o=(-o BatchMode=yes -o "ConnectTimeout=$ct" -o StrictHostKeyChecking=accept-new)
  if ! is_windows; then
    o+=(-o "ProxyCommand=$(ssh_proxy_cmd)")
  fi
  printf '%s\n' "${o[@]}"
}

_peer_list() {
  # 账号从 ~/.ssh/config 的同名 Host 里取（hosts add 生成时就写对了 user）。
  # 取不到才按名字前缀猜 —— 直接拿主机名当账号会在 sgl 上翻车：
  # 它的节点名是 desktop-sgl-4，而账号是 sgl。
  local self_ip; self_ip=$(tailscale_ip_of)
  # 整行过滤 offline，不只看状态列。踩过的原话长这样：
  #   100.113.237.37  desktop-sgl-4   singularity23187@  windows  active; relay "sin"; offline, last seen 12m ago
  # 第 5 列是 "active;"（因为它指的是"有过活跃连接尝试"），于是关机的机器
  # 被算成在线，后面每台都要等一次 ConnectTimeout，最后报"一台也没取到"。
  "${TS[@]}" status 2>/dev/null | tr -d '\r' | awk '/^100\./ && $0 !~ /offline/ {print $1, $2, $5}' \
  | while read -r ip name state; do
      [ "$ip" = "$self_ip" ] && continue
      case "$state" in *idle*|*active*) ;; *) continue ;; esac
      local u
      u=$(_ssh_user_of "$name")
      printf '%s %s\n' "$name" "${u:+$u}@$ip"
    done
}

# 找一台机器该用什么账号登。
# 两步，缺一不可：
#   ① ~/.ssh/config 里名字完全相同的 Host（sgl、ubuntu 这些人工/自动写的短名）
#   ② 上面没有时，按 HostName 反查 —— 节点名是 desktop-sgl-4，config 里那段的
#      名字却是 sgl，只按名字匹配会一无所获，然后拿主机名当账号去登，
#      报的是 Permission denied，看着像密钥没授权。
_ssh_user_of() {
  local n=$1 ip=""
  local u
  u=$(awk -v n="$n" '$1=="Host"{inh=($2==n)} inh && $1=="User"{print $2; exit}' \
        "$SSH_DIR/config" 2>/dev/null)
  [ -n "$u" ] && { printf '%s' "$u"; return 0; }
  ip=$("${TS[@]}" status 2>/dev/null | tr -d '\r' | awk -v n="$n" '$2==n{print $1}' | head -1)
  [ -n "$ip" ] || return 0
  awk -v ip="$ip" '
    $1=="Host" {h=$2; next}
    $1=="HostName" && $2==ip {found=h}
    $1=="User" && found==h {print $2; exit}
  ' "$SSH_DIR/config" 2>/dev/null
}

# 从一台机器取回它的公钥：先 scp 式取文件，失败就让它 cat 出来
_fetch_pubkey() {
  local name=$1 dest=$2 tmo=${3:-90} out
  local ct=$tmo; [ "$ct" -gt 25 ] && ct=25
  local -a SO=(); while IFS= read -r l; do SO+=("$l"); done < <(_ssh_opts "$ct")
  # 必须经 `bash -ls` 中转：sgl 的默认 shell 是 PowerShell，
  # 直接送一段带 ~ 和 2>/dev/null 的命令会变成
  # "Out-File: Could not find a part of the path 'C:\dev\null'" ——
  # 看着像文件不存在，其实是 PowerShell 在解析 bash 语法。
  # 挑公钥的顺序是固定的（hb 落的那把优先），`for f in *.pub` 在有多把钥的
  # 机器上会随机给一把别人的，名单里就混进不相干的身份。
  out=$(timeout "$tmo" ssh "${SO[@]}" "$dest" "bash -ls" 2>/dev/null <<'SH' | tr -d '\r' | grep -E '^(ssh-|ecdsa-)' | head -1
for f in ~/.ssh/id_ed25519.pub ~/.ssh/hb_key.pub; do [ -s "$f" ] && cat "$f" && exit 0; done
ssh-keygen -y -f ~/.ssh/id_ed25519 2>/dev/null && exit 0
ssh-keygen -y -f ~/.ssh/hb_key 2>/dev/null && exit 0
for f in ~/.ssh/*.pub; do [ -s "$f" ] && cat "$f" && exit 0; done
SH
  )
  [ -n "$out" ] && { printf '%s\n' "$out" > "$HB_PUBKEYS_DIR/${name}.pub"; return 0; }
  return 1
}

# 把本地名单推到一台机器：让**对端**自己追加，而不是本地拼 ssh 命令。
# 理由同 git 凭据那一步：对端是 Windows 时，引号和路径会被 PowerShell 吃掉。
_push_pubkeys() {
  local dest=$1 tmo=${2:-120} ct=${3:-25} b64
  [ -s "$AUTHKEYS_FILE" ] || return 1
  b64=$(base64 -w0 < "$AUTHKEYS_FILE" 2>/dev/null || base64 < "$AUTHKEYS_FILE" | tr -d '\n')
  [ -n "$b64" ] || return 1
  local -a SO=(); while IFS= read -r l; do SO+=("$l"); done < <(_ssh_opts "$ct")
  # 为什么整份走 base64，而不是每行套引号 echo：
  #   ① 公钥行直接进 heredoc 会被 shell 再展开一次（$、反引号、反斜杠），
  #      注释里带个 $ 就把末尾吃掉了，而 authorized_keys 看起来"写进去了"；
  #   ② 对端是 Windows（sgl）时，命令行要穿 PowerShell → cmd → bash 三层，
  #      引号每过一层都掉一颗，逐行套引号这条路实测掉进过
  #      "ssh-ed25519: command not found"（公钥被当命令执行）。
  # base64 只有 [A-Za-z0-9+/=]，套多少层都不变形；解码在远端做。
  timeout "$tmo" ssh "${SO[@]}" "$dest" "bash -ls" <<EOF >/dev/null 2>&1
set -e
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
printf '%s' '$b64' | base64 -d >> ~/.ssh/authorized_keys
sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys
echo PUSHED
EOF
}

# 对"已经在网内、也已经能 ssh"的机器，把名单补推一份。
#
# 注意它**不是**新机器拿到第一把钥的途径：那台还没授权，ssh 根本进不去，
# 推是推不动的（鸡生蛋）。第一把钥由 /l 引导脚本预埋 —— 见 serve.py 里
# 的 pk_block，它跑在 hb 之前，不依赖任何认证。
#
# 这里解决的是另一半：老机器（比如 sgl）名单停在一把，新节点上来后
# 它也该知道新节点。摘帽之前推一轮，省得新机器再去挨个找。
#
# 账号只能挨个试：它还没进 hosts，没有任何地方写着它用哪个账号。
# 顺序按真实机器的常态排（Jetson 官方镜像是 ubuntu，hb 用 sudo 跑是 root）。
_push_keys_to_new() {
  local ip=$1 hn=$2 u
  [ -n "$ip" ] || return 0
  [ -s "$AUTHKEYS_FILE" ] || ensure_authorized >/dev/null 2>&1 || true
  [ -s "$AUTHKEYS_FILE" ] || return 0
  for u in root ubuntu nvidia jetson "$(id -un)"; do
    if _push_pubkeys "$u@$ip" 20 6 >/dev/null 2>&1; then
      ok "已把 $(grep -c '^ssh-\|^ecdsa-' "$AUTHKEYS_FILE" 2>/dev/null || echo "?") 把公钥推给 $u@$ip"
      echo "    这台以后能直接 ssh 进去；其它机器要进来，跑一次 hb sync-keys 即可"
      return 0
    fi
  done
  warn "公钥没推成（$hn 上 sshd 未开，或账号都不匹配）"
  echo "    不影响它入网。它自己下次跑 hb up 会从在线节点取一遍（⑥½）。"
  return 1
}

# ── 轻量版：hb up 每次启动都跑，但不许把它拖成五分钟 ────────────────
#
# 用户的要求是"每次启动 hb，都去 online 的机子把密钥复制过来"。
# 照字面全量跑是不行的：hb up 本身已经在等 netmap 下发、等 ssh 登录，
# 再叠 6 台 × 25 秒的 SSH 就是四分钟，没人受得了，最后一定会被注释掉。
#
# 判据从"每次"改成"齐不齐"：本地已知公钥数 ≥ 在线节点数+自己 就跳过。
# 不齐才取，且最多 3 台、每台 12 秒 —— 够覆盖"新机器第一次上来"的场景
# （它缺的其实就一把，取到任意一台就齐了）。
HB_QUICK_MAX=3
HB_QUICK_TMO=12
sync_keys_quiet() {
  mkdir -p "$HB_PUBKEYS_DIR" 2>/dev/null
  [ -s "$AUTHKEYS_FILE" ] || ensure_authorized >/dev/null 2>&1 || true
  local have need peers name dest n=0 got=0
  have=$(grep -c '^ssh-\|^ecdsa-' "$AUTHKEYS_FILE" 2>/dev/null)
  have=${have:-0}
  peers=$(_peer_list)
  need=$(( $(printf '%s\n' "$peers" | grep -c . ) + 1 ))
  if [ "$have" -ge "$need" ] && [ "$have" -gt 0 ]; then
    ok "公钥名单已齐（$have 把，在线 $((need-1)) 台）"
    return 0
  fi
  while read -r name dest; do
    [ -n "$dest" ] || continue
    n=$((n+1))
    [ "$n" -gt "$HB_QUICK_MAX" ] && break
    _fetch_pubkey "$name" "$dest" "$HB_QUICK_TMO" >/dev/null 2>&1 && got=$((got+1))
  done <<< "$peers"
  if [ "$got" -eq 0 ]; then
    warn "公钥名单只有 $have 把（在线 $((need-1)) 台），但一台也没取到"
    echo "    对端没 sshd、或账号不对都会这样；不影响本机联网，只影响远程执行。"
    echo "    等它们上线后跑一次：$SELF sync-keys"
    return 0
  fi
  ensure_authorized >/dev/null 2>&1 || true
  ok "公钥名单：从 $got 台取回，现有 $(grep -c '^ssh-\|^ecdsa-' "$AUTHKEYS_FILE" 2>/dev/null || echo "?") 把"
  return 0
}

cmd_sync_keys() {
  case "${1:-}" in -h|--help)
    echo "用法: $SELF sync-keys [--dry]"
    echo
    echo "  从所有在线节点收集公钥，汇总进本机的 authorized_keys，"
    echo "  再把完整名单推回这些节点。已戴着 hb-hub 帽子时，本机就是中间人。"
    return 0 ;;
  esac
  command -v python3 >/dev/null 2>&1 || die "需要 python3"
  net_up || { warn "网络未就绪"; cmd_up quiet || die "修复失败"; }
  mkdir -p "$HB_PUBKEYS_DIR"

  say "公钥同步"
  local peers; peers=$(_peer_list)
  if [ -z "$peers" ]; then
    warn "没有其他在线节点 —— 没什么可同步的（不是错）"
    return 0
  fi
  local got=0 total=0 name dest
  while read -r name dest; do
    [ -z "$dest" ] && continue
    total=$((total+1))
    if _fetch_pubkey "$name" "$dest"; then got=$((got+1)); else
      printf '     %-18s 取不到（ssh 不通或没在跑 sshd）\n' "$name"
    fi
  done <<< "$peers"
  ok "取到 $got / $total 台的公钥"

  ensure_authorized || true

  # 推回去：这一步是"每台机器一份完整名单"的关键，少了它只是本地变全
  local pushed=0
  while read -r name dest; do
    [ -z "$dest" ] && continue
    [ -s "$HB_PUBKEYS_DIR/${name}.pub" ] || continue
    if _push_pubkeys "$dest"; then pushed=$((pushed+1)); fi
  done <<< "$peers"
  ok "名单已推到 $pushed 台（共 $(grep -c '^ssh-\|^ecdsa-' "$AUTHKEYS_FILE" 2>/dev/null || echo 0) 把公钥）"
  echo "    以后 hb up / hb enroll 都会顺带做这一步，不用单独跑。"

  # ── 名单分完了，把中间人的特殊身份收起来 ──────────────────────────
  # 分发（enroll）和同步（sync-keys）都是"临时借用 hb-hub 这个名字"，
  # 分完就该还回去。不自动摘的话，下一个人想戴帽子会被告知"被占着"，
  # 然后去人工 kill 进程 —— 而那个进程根本不存在了。
  if _hub_cur_name 2>/dev/null | grep -qx "$_HUB_NAME"; then
    if [ -s "$_HUB_STATE" ]; then
      _HUB_ORIG=$(cat "$_HUB_STATE"); _HUB_SAVED=1
      _lend_restore 2>/dev/null || "${TS[@]}" set --hostname="$_HUB_ORIG" >/dev/null 2>&1
      ok "名单已分完，帽子摘了（名字还原为 $_HUB_ORIG）"
    fi
  fi
}


# ── 分派 ───────────────────────────────────────────────────────────
# 帮助只输出「这是什么 + 命令表」：实施细节（为什么这么判）留给读源码的人。
# 命令清单来自 HB_CMDS —— 一处定义，两处使用，不会漂。
show_help() {
  printf 'hb —— 把「连上、修好、干活」收进一个文件\n\n'
  printf '  裸调用 hb = 只读体检。它回答三个问题：这台机器能不能连出去、\n'
  printf '  缺什么、下一步该敲哪条命令。\n\n'
  printf '  命令\n'
  local e name fn desc
  for e in "${HB_CMDS[@]}"; do
    IFS='|' read -r name fn desc <<< "$e"
    printf '    hb %-11s %s\n' "$name" "$desc"
  done
  printf '\n'
  printf '  别名  status → ts status，host → hosts\n'
  printf '  远程  hb <机器> <命令...>   机器 = 别名 | ssh Host | 网内节点名 | IP\n\n'
  printf '  身份  不自带密钥：依次找 $HB_KEY_FILE、$HB_HOME/hb_key、~/.ssh/<key>\n'
  printf '  凭据  不自带入网凭据：$HB_STATE_DIR/credentials.json 或 $TAILSCALE_AUTHKEY\n'
}

# 裸调用 = doctor：只读、无副作用。想不起子命令时敲一下也有有效输出。
[ $# -eq 0 ] && { cmd_doctor; exit $?; }

# 别名先展开（status → ts status），再查命令表
for _al in "${HB_ALIASES[@]}"; do
  IFS='|' read -r _an _at <<< "$_al"
  if [ "$1" = "$_an" ]; then
    shift
    set -- $_at "$@"
    break
  fi
done

case "$1" in
  -*) show_help; exit 2 ;;
esac

for _cm in "${HB_CMDS[@]}"; do
  IFS='|' read -r _cn _cf _cd <<< "$_cm"
  if [ "$1" = "$_cn" ]; then
    shift
    "$_cf" "$@"
    exit $?
  fi
done

# 兜底：首参不是已知子命令，才当成机器名（hb box "uptime"）。
# 子命令永远优先；hosts add 时也拦了重名，这里再判一次是防手改 hosts 文件。
cmd_run "$@"
exit $?
