# hb

把「连上、修好、干活」收进一个文件。

`hb` 是一个约 3000 行的 bash 脚本，用来管理一小组机器之间的**互通与远程执行**：它不替代 ssh，也不替代 Tailscale——它把两者的判断逻辑收在一处，让「为什么连不上、下一步该做什么」变成可以打印出来的东西。

```
$ hb                    # 裸调用 = 只读体检
▸ 体检
  SSH 私钥            OK  /root/.ssh/id_ed25519
  tailscale 二进制     OK  1.104.4
  Tailscale 服务       OK  运行中
  netmap 节点数        5
  出口连通             OK  CDN 200 · 协调面 302
  ✓ 全部通过
```

## 它解决什么

远程开发环境最常见的三种坏法：

1. **机器换了个网络**（NAT / 无线客户端隔离），ssh 不通，而「修网络」本身需要网络 —— 死锁。
2. **新设备要接进来**，手头没有现成安装包，也不想教人一串手工步骤。
3. **排障全靠猜**，报错指向错误的方向（「没私钥」被报成「网络不通」，「账号不对」被报成「服务没起」）。

`hb` 的答案是：把判据写进命令里。每条命令都自己回答「哪里坏了、下一步敲什么」。

## 安装

```bash
git clone https://github.com/SGL23187/hb.git
ln -s "$PWD/hb/hb" ~/.local/bin/hb      # 或把仓库目录加进 PATH
hb
```

要求：bash 4+，`ssh`、`curl`。Windows 上用 Git Bash（`hb.cmd` 也可用）。

## 30 秒上手

```bash
hb                                   # 体检：先看这台机器缺什么
hb hosts add box 100.64.0.5 user=me  # 起个别名，以后不用记 IP
hb box "hostname; uptime"            # 远程执行（与 ssh 等价，但掉线会先自修）
hb put  box ./data.csv /tmp/         # 传文件
hb get  box /var/log/syslog .        # 取文件
hb list                              # 网内每台 + 本机状态一屏看完
```

加一台新设备（对方跑一条命令即可）：

```bash
hb enroll            # 打一个公网可访问的分发点，打印安装命令
# 新机器上：curl -fsSL https://hb-hub.<tailnet>.ts.net/l | sudo bash
```

## 命令

| 命令 | 作用 |
|---|---|
| `hb` / `hb doctor` | 本机体检（只读） |
| `hb list [--json]` | 设备总览，`--json` 给程序读 |
| `hb up` | 一次修到底，幂等 |
| `hb <机器> <命令...>` | 远程执行 |
| `hb put` / `hb get` | 传文件 / 取文件 |
| `hb hosts [add\|rm]` | 别名（第一个是默认机器） |
| `hb enroll` | 加设备：默认经 `hb lend` 戴帽子，短链固定 |
| `hb lend [--off]` | 能力层：把自己临时变成分发服务器 |
| `hb sync-keys` | 向在线节点同步公钥名单 |
| `hb route ls\|approve` | 子网路由（需要 API token） |
| `hb ts ...` | 透传 tailscale 命令 |
| `hb vendor` | 把 tailscale 二进制归档到目录（离线自举） |

## 三个概念

**① doctor 是判据收集器，不是仪表盘。**
每行都在回答「这一环能不能过」，失败的都自带一行怎么修。设计上裸调用就是它，因为想不起子命令时最自然的动作就是敲个名字——那个动作必须安全、必须有信息量。

**② 别名不是 ssh config。**
`hb hosts` 维护的是一张「名字 → 地址 + 账号」的表，与 `~/.ssh/config` 分开。解析顺序是**别名 → ssh config → 节点名 → IP**，所以别名可以覆盖一个同名的、指向别处的 ssh Host（这在有 WSL 或历史配置的机器上很常见）。

**③ 加设备 = 戴帽子 + 分发。**
`hb enroll` 默认调 `hb lend`：本机临时改名 `hb-hub`，短链固定为 `https://hb-hub.<tailnet>.ts.net`，发一次以后一直有效；退出时自动摘帽、名字还原。不想改名就 `--no-hub`（短链随本机名走，机器一改名就失效）。

## 身份与凭据

**`hb` 不自带任何密钥或凭据。** 它按顺序找：

| 需要什么 | 从哪来 |
|---|---|
| SSH 私钥 | `$HB_KEY_FILE` → `$HB_HOME/hb_key` → `~/.ssh/id_ed25519` |
| 入网 authkey | `$TAILSCALE_AUTHKEY` → `$HB_STATE_DIR/credentials.json` → `~/.config/tailscale/authkey` |
| Tailscale API token | `$TS_API_KEY` → `credentials.json` 里的 `ts_api_key` |

都没有就明说缺什么、怎么补，不会生成新钥（新钥对方不认，报出来是 `Permission denied`，看着像网络问题——这个坑踩过）。

状态目录 `~/.hb/`：别名表、公钥名单、凭据、戴帽子期间的原名。

## 设计约定（为了能被 AI 用）

- 裸调用 = 只读体检，不写磁盘
- 机器要读的用 JSON：`hb list --json`，字段稳定
- 只用退出码表达失败：`0` 成功，非 `0` 有问题
- 每个失败都有一条「下一步」，因为调用方往往没有本机上下文
- 端口探测统一走 `port_open`：Git Bash 没有 `nc`，`nc -z ... 2>/dev/null` 会把「在监听」静默判成「未监听」
- 平台判断只看 `hb_is_msys` / `hb_is_windows`，不散写 `uname`

## 它不做什么

- 不内嵌密钥、凭据、authkey
- 不代你登录 Tailscale（Windows 交给官方客户端）
- 不改系统配置：写动作只有 `~/.ssh/config`（可关）、`~/.hb/`、别名表

## 构建

源码在 `src/*.sh`，按文件名字典序拼成单文件：

```bash
bash build.sh            # 拼出 hb
bash tests/run.sh        # 离线护栏（36 项）
python3 check_fn_order.py hb
```

改行为请改 `src/`，不要直接改 `hb`——`build.sh` 会覆盖，并留一份 `hb.bak-*`。详见 [CONTRACT.md](CONTRACT.md)。

## License

MIT
