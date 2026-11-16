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
