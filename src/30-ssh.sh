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
# 集中式（所有人写一个 box 的 authorized_keys）不行：box 一关，全网失联，
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

  # ① 私钥：已有 → 任一来源恢复 → 报错（不生成新的，新钥 box 不认）
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
# （否则 `hb box "ls"` 与 `hb status` 谁优先就成了运气问题）。
# 表里加一个词，别名那边自动就避让了 —— 这是它们唯一的耦合点。
HB_SUBCMDS="list status doctor up run ts vendor sync-keys hosts enroll lend route put get help"

# 别名文件：本机私有，不进 git、不进载荷。一行 `box 100.64.0.5`
# 第一行是默认主机（hb box "..." 里的 box 就到它）。
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

# 别名里显式写的账号（`box 100.64.0.5 user=box` 的第三段）
hosts_user() {
  hosts_all | awk -v n="$1" '$1==n{for(i=3;i<=NF;i++) if ($i ~ /^user=/) { sub(/^user=/,"",$i); print $i; exit }}'
}

# 一个 IP 该怎么登：先看 config 里 HostName 匹配的那条，再看 box 约定
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
      # 打印"登录账号：box"时人会以为自己看错，其实是根本没读到 root。
      if [ $# -gt 3 ]; then
        shift 2
        target="$*"
      fi
      if [ -z "$name" ] || [ -z "$target" ]; then
        bad "用法：$SELF hosts add <名字> <IP|ssh别名>"; return 2
      fi
      if ! alias_usable "$name"; then
        bad "「$name」不能用作机器别名"
        case " $HB_SUBCMDS " in *" $name "*) echo "    它已经是子命令。换一个名字，例如 box2 / boxlab。";; esac
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
      # "登录账号：root"，落盘的却是 `100.88.99.106 user=box` —— 因为 user=
      # 是在这条 IP 判据之后才被看的，此处重写了一遍 target，把人家写的参数吃掉，
      # 然后拿 _ssh_user_for 的兜底值 box 顶上去。现在先解析 user=，再补默认。
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
        echo "  （没有机器别名。加一个：$SELF hosts add box 100.64.0.5）"
        echo "  没有别名时，hb 也会认 ~/.ssh/config 里的 Host 和网内的节点名。"
        return 0
      fi
      local first=1 n t note
      say "机器别名  $HOSTS_FILE"
      while read -r n t; do
        [ -z "$n" ] && continue
        note=""
        [ $first -eq 1 ] && { note="  ← 默认（$SELF box 等同于 $SELF $n）"; first=0; }
        if ! alias_usable "$n"; then note="$note  ✗ 与子命令重名，会被忽略"; fi
        printf '  %-10s → %-16s%s\n' "$n" "$t" "$note"
      done <<< "$(hosts_all)"
      ;;
    *)
      bad "用法：$SELF hosts [list|add <名字> <地址>|rm <名字>]"; return 2 ;;
  esac
}

# 调过一次就记住它。规则只有一条：**同名不覆盖、默认位只有一次**。
# 第一台调到的机器记为 box（`hb box "…"` 的默认指向），之后各自用节点名。
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
  if [ -z "$first" ] && ! hosts_all | awk '$1=="box"{f=1} END{exit !f}'; then
    printf 'box %s user=%s\n' "$ip" "$(_ssh_user_for "$ip")" >> "$HOSTS_FILE"
    printf '  \033[2m# 记住了这台：以后 hb box "…" 就指它（要改指向：hb hosts add box <IP>）\033[0m\n' >&2
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
# 现象：hb up ⑦ 说「git 凭据 ✓ 已从 box 取回」，文件 69 字节、内容正确，
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
# 对 `peer-c` 这种只在 hosts 文件里存在、config 里没有的名字也会返回真，
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
