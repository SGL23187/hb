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
