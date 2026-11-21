# ══════ 区 4 命令：运行与体检 ══════
#
cmd_up() {
  local quiet=${1:-}
  # 这里曾经写的是「box 侧不做自愈，它就是被连的那一头」。那句话在两个层面都错：
  #   · 事实层：box 也能 `hb <别的机器> "…"`，它不是"被连的一端"；
  #   · 工程层：把一个跨平台工具塞进"我修你 / 你被我修"的模型后，
  #     第一件事就是给某一端写死一个 no-op —— 而那正是故障藏身的地方。
  #
  # 但下面这些**平台差异是真的**，不修掉会真出事：
  #   在 box 上照搬 Linux 那套 → mkdir /var/lib/tailscale（被 MSYS 改写成
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
      echo "    这台不像 box：这里没有可用的系统服务，也没有下载链（Windows 版需要 MSI）"
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
  # 目标取自别名表（最多前两个）：公开版没有"预设主机"，硬编码只会指向别人的机器。
  # 一个别名都没有就跳过 —— 那不是故障，是还没配。
  local h out line got=0 targets=()
  while read -r _n _t _rest; do
    [ -n "$_n" ] || continue
    case "$_t" in [0-9]*.[0-9]*) targets+=("$_t") ;; esac
    [ ${#targets[@]} -ge 2 ] && break
  done < <(hosts_all 2>/dev/null)
  if [ ${#targets[@]} -eq 0 ]; then
    warn "没有可测的对端（别名表为空）—— 跳过；加一个：$SELF hosts add <名字> <IP>"
  fi
  for h in ${targets[@]+"${targets[@]}"}; do
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
  # 只做一次真连接验证：私钥对但 box 的 authorized_keys 没这把钥时，
  # 症状是 "Permission denied (publickey)"，与「网络不通」完全是两件事。
  #
  # 这里**不再** return 1。原来是"box 不通 = up 失败"，但 box 是台会关机的
  # Windows 台式机，一年里大半时间不在线；把它当唯一参照物，等于让"这台机器
  # 环境好不好"取决于另一台开没开机。而真正影响全网的只有"别人进不来"，
  # 那件事由 ⑥½ 用所有在线节点兜。
  if timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=12 box "exit 0" >/dev/null 2>&1; then
    ok "ssh box 可用"
  else
    warn "ssh box 不通 —— 忽略，下面改用所有在线节点"
    echo "    若别的机器也连不进这台，问题在本机授权；否则只是 box 没开机。"
  fi

  say "⑥½ 公钥名单"
  sync_keys_quiet

  # ⑦ 补上「能拉代码」这一环。
  # 沙箱被清空时 ~/.git-credentials 一并消失，于是 git clone 私有仓库失败；
  # 而 box 上那份一直是好的。缺了它，「环境恢复好了」只到能 ssh，还干不了活 ——
  # 上一个接手的人就是在这里折返的：先试直连（被掐）→ 想配代理（没凭据）→
  # 最后用 git bundle 从 box 打包含中转。凭据就在对端放着，取回来就完了。
  say "⑦ git 凭据"
  if [ -s "$HOME/.git-credentials" ]; then
    ok "已存在"
  else
    # 平台无关：box 上取不出就直说，别让 PowerShell 去拼 base64 再报个看不懂的错
    local _cred
    _cred=$(ssh -o BatchMode=yes -o ConnectTimeout=12 box \
              "bash -lc 'base64 -w0 < \"\$HOME/.git-credentials\" 2>/dev/null'" 2>/dev/null \
            | tr -d '\r\n')
    # 取回的是 base64 原文（远端只负责编码，解码在本地做）：
    # 让远端跑 `base64 -d | bash` 等于让对端执行一段看不懂的代码，
    # 而且 PowerShell 会吃掉 $HOME —— 这正是"手工绕行"的起点。
    if [ -n "$_cred" ] && printf '%s' "$_cred" | base64 -d > "$HOME/.git-credentials.hb" 2>/dev/null \
       && [ -s "$HOME/.git-credentials.hb" ]; then
      mv "$HOME/.git-credentials.hb" "$HOME/.git-credentials"
      chmod 600 "$HOME/.git-credentials"
      ok "已从 box 取回"
    else
      rm -f "$HOME/.git-credentials.hb"
      is_windows && { warn "本机即 box，无对端可取"; } || {
        warn "沙箱与 box 都没有 —— 拉私有仓库会失败"
        echo "     在 box 上执行 cat \$HOME/.git-credentials，粘到沙箱同名文件（chmod 600）"
      }
    fi
  fi
  # 文件在 ≠ git 能用：本次恢复就是「文件 69 字节、内容正确，clone 仍要账号」。
  # 所以判据放在这里，一次修到底。
  if [ -s "$HOME/.git-credentials" ]; then
    ensure_cred_helper || warn "git 凭据文件在，但 git 不会读它 —— 见上方提示"
  fi

  # 别在这里教人 `ssh box` —— 裸 ssh 不会先自修网络，掉线时给出的又是那句
  # 指向错误方向的 "Connection closed by UNKNOWN port 65535"。用 hb 自己。
  [ -z "$quiet" ] && { echo; ok "完成"; echo "   用法：$SELF box \"命令\"（与 ssh 等价，但掉线会先自修）"; }
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

  # Windows（box）是出口而不是客户端，下面这些「修隧道用的东西」它不需要，
  # 标成 —  而不是 ✗，否则 box 上永远显示体检失败，等于噪音。
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
  # `wc -l` 认不出来，box 上明明 6 个节点却报 0。改数「含 100. 的行」。
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
      echo "无 → hb up 会从 box 取回"; fail=1
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
    printf '  %-24s ' "box 可达"
    if port_open 127.0.0.1 1055 8 && \
       timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=10 box "exit 0" >/dev/null 2>&1; then
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
  local -a SO=()      # ssh 选项统一收在这里，必须全部排在 host 之前
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
  # 用户名的来源按可信度排：名字前缀（nas2 → nas）→ 候选名里出现的已知前缀
  # → 当前登录用户。
  # 别用 `${name%%[0-9]*}` 一把梭：`desktop-box-4` 会变成 `desktop-box-`。
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
    # IP 目标也要能拿到账号：hosts 表里可能早就有一条指向它的别名
    # （`hb hosts add yahboom 100.65.80.63 user=jetson` 留下的）。有就抄。
    # 2026-11-21 实测 `hb 100.65.80.63` 猜成 box → Permission denied，
    # 看着像密钥没授权，实际只是账号错 —— 又一个"判据指错方向"。
    [ -n "$ssh_user" ] || ssh_user=$(hosts_all 2>/dev/null | awk -v ip="$host" '$2==ip{for(i=3;i<=NF;i++) if ($i ~ /^user=/) { sub(/^user=/,"",$i); print $i; exit }}')
    [ -n "$ssh_user" ] || ssh_user=$(awk -v ip="$host" '
      tolower($1)=="host"              { h=$2; u=""; next }
      tolower($1)=="hostname" && $2==ip { hh=h; next }
      tolower($1)=="user"              { u=$2; next }
      END { if (hh!="" && u!="") print u }' "$SSH_DIR/config" 2>/dev/null)
    if [ -z "$ssh_user" ]; then
      # 没有现成的 Host 可比：只信「名字前缀」（nas2 → nas）。
      # 不从别的节点猜 —— 网内第一个带数字的节点是沙箱 e8a313c69199（前缀 "e"），
      # 下一个减版本号得到 "desktop-box"，两个都不是账号。
      pref="${sshr%%[0-9]*}"; pref="${pref%-}"
      [ "$pref" != "$sshr" ] && printf '%s' "$pref" | grep -qE '^[a-zA-Z][a-zA-Z0-9_.]*$' && ssh_user="$pref"
    fi
    ssh_user="${ssh_user:-box}"
    # 先直连试一次，再穿隧道。理由：真机（Jetson、box）是内核 tun，
    # 直连本来就能通且更快；沙箱是用户态，直连秒失败再回落到代理，
    # 代价只有一次极短的失败。反过来（只走代理）会把两端都拖慢。
    local _hb_key=""
    _hb_key=$(hb_key_path 2>/dev/null) || _hb_key=""
    SO+=(-o "User=$ssh_user")
    # ProxyCommand 只在「本机没有内核 tun」时才需要 —— 用户态沙箱直连必失败，
    # 才走 SOCKS/tailscale nc 兜底。Windows/macOS/真机 Linux 都有 tun，
    # 直连更快；硬加 ProxyCommand 反而会挂：Windows 上 `tailscale nc` 至今不可用，
    # ssh 收到空连接直接 `Connection closed by UNKNOWN port 65535`（2026-11-21 实测）。
    if ! port_open "$host" 22 2; then
      SO+=(-o "ProxyCommand=$(ssh_proxy_cmd)")
    fi
    # 有钥才显式指定：显式给了 IdentityFile，ssh 就不再尝试默认私钥 ——
    # 所以宁可漏传，也不能传空变量拼出来的 "/"（那会报 Load key "/": Is a directory）。
    [ -n "$_hb_key" ] && SO+=(-o "IdentityFile=$_hb_key")
  fi

  # 解析到哪台要说出来，但不占 stdout：stdout 是远端命令的输出，被一行提示
  # 污染后 `out=$(hb box cat file)` 就不干净了。
  if [ "$host" != "$name" ]; then
    [ $hit_node -eq 1 ] && why=节点名 || why=别名
    printf '\033[2m# %s → %s（%s）\033[0m\n' "$name" "$host" "$why" >&2
  fi
  if ! net_up; then
    warn "网络未就绪，先修复"
    cmd_up quiet || { hb_diagnose "$host" 1; die "修复失败"; }
  fi
  # 记住"这台"：第一台叫 box（老习惯，退化成默认），之后每台都用它的节点名。
  # 不记的话，下一次还是只能靠 IP 或长名字，而人记住的永远是简称。
  if [ "$host" != "$name" ] || printf '%s' "$host" | grep -qE '^[0-9]+\.'; then
    hosts_remember "$name" "$host" >/dev/null 2>&1 || true
  fi
  # ssh 自己会重试，但"失败"必须带上诊断 —— 否则调用者只拿到 exit 255，
  # 得自己去猜是隧道、私钥还是对端没开机。
  local rc=0
  ssh -o BatchMode=yes ${SO[@]+"${SO[@]}"} "$host" "$@" || rc=$?
  [ $rc -eq 255 ] && hb_diagnose "$host" 255
  return $rc
}

cmd_ts() { exec tailscale --socket="$SOCK" "$@"; }

