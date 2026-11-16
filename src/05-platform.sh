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

