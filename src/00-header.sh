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

# ~/.ssh 与私钥名：**必须在这里赋值**。
# 2026-11-16 冷启动实测：这两个变量跟着被删掉的载荷模块一起消失了，
# 于是 -o IdentityFile=$SSH_DIR/$SSH_KEY_NAME 变成 -o IdentityFile=/，
# ssh 报 "Load key "/": Is a directory" + Permission denied ——
# 而 hb 自己的诊断说"账号不对/公钥没埋"，把方向指到了远端。空变量不报错，最难查。
SSH_DIR="${HB_SSH_DIR:-$HOME/.ssh}"
SSH_KEY_NAME="${HB_SSH_KEY:-id_ed25519}"

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
  "version|cmd_version|我是哪一份：路径 + 指纹（PATH 有同名 hb 时用它自证）"
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
