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
