# ══════ 区 6 命令：公钥名单同步 ══════
#
# ══ 公钥同步：不在线的机器开机后，从当时在线的机器补齐 ════════════
#
# 场景（用户原话）："注册机器时不在线的机子，只能从其他当时在线的机器获得密钥"。
# 所以做不做这件事，取决于**现在还在不在帽子/在不在线**，不是凭空定时跑。
#
# 一个必须处理的死结：新机器的 box 不通，是因为它的 authkey 是**单次的**，
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
  # 取不到才按名字前缀猜 —— 直接拿主机名当账号会在 box 上翻车：
  # 它的节点名是 desktop-box-4，而账号是 box。
  local self_ip; self_ip=$(tailscale_ip_of)
  # 整行过滤 offline，不只看状态列。踩过的原话长这样：
  #   100.64.0.5  desktop-box-4   singularity23187@  windows  active; relay "sin"; offline, last seen 12m ago
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
#   ① ~/.ssh/config 里名字完全相同的 Host（box、ubuntu 这些人工/自动写的短名）
#   ② 上面没有时，按 HostName 反查 —— 节点名是 desktop-box-4，config 里那段的
#      名字却是 box，只按名字匹配会一无所获，然后拿主机名当账号去登，
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
  # 必须经 `bash -ls` 中转：box 的默认 shell 是 PowerShell，
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
  #   ② 对端是 Windows（box）时，命令行要穿 PowerShell → cmd → bash 三层，
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
# 这里解决的是另一半：老机器（比如 box）名单停在一把，新节点上来后
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


