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


# 借道：沙箱直连 GitHub 会间歇性被掐，用 ssh -L 借 box 上的 Clash。
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
              # hb 默认拿当前用户名（box）去登，回 Permission denied，却被诊断成
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
  # box 上它排第六行，而 status 里叫 desktop-box-4、hostname 是 DESKTOP-SGL，
  # 匹配不上就回落到「最后一行的 IP」—— 于是把 yahboom8 当成自己，
  # 真正的 box 被列成「对端 offline」，整屏都是假的。
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
  # 于是 box 上的 list 永远不区分"在线"和"在线但不可达"。
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

  # ssh 探针放后台，和下面的 ping 并行。box 的 sshd 每次登录要起 PowerShell 并加载
  # profile，实测 6~9s（链路走 relay 更慢），串行叠在 ping 上 list 就要 9s ——
  # 一条"看一眼"的命令不该让人等这么久。
  local sshpid=""
  if [ $socks -eq 1 ] && ! is_windows; then
    timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=8 box "exit 0" >/dev/null 2>&1 &
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
    # 只有两项属于"本机自己不用"：socks1055（本机不绕自己）、default_ssh（本机就是它）。
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
    [ $sshok -eq 1 ] && ok "ssh box 通" || bad "ssh box 不通 → $SELF up"
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

# ── 两端自证：本地 hb / AGENTS.md 与 box 上那份是不是同一份 ─────────
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
#   · 改名不会断现有连接（实测：改名后 ssh box 照常回 OK），所以随时可戴可摘。
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
    # 2026-11-16 实测：prefs 已经是 desktop-box-4，status --json 仍回 hb-hub，
    # 而屏幕已经打出「名字还原为 desktop-box-4」—— 下一个人去 hb list 会当场懵。
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
