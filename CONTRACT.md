# hb 的工程契约

> 这份文档回答：hb 现在怎么组织、怎么改、怎么验收。
> 目标：**换语言（Go/Rust）那天，只需要照抄这里的契约，不用重新猜行为。**

## 1. 目录与产物

```
tools/
  hb                 ← 构建产物（分发物）。**不要直接改它**，改 src/
  build.sh           ← cat src/*.sh → hb，带语法/尾部自检
  hb.cmd             ← Windows cmd.exe 入口，指向 hb
  hosts              ← 机器别名（含敏感信息，.gitignore）
  credentials.json   ← 凭据（.gitignore）
  src/               ← 源码，按文件名顺序拼接
  tests/run.sh       ← 行为护栏（默认全离线）
  check_fn_order.py  ← 静态检查：函数定义顺序
```

**构建即验收的硬约束**：`build.sh` 必须能拼出 `hb`；如果一次重构没改任何逻辑，
产物应与旧文件 `cmp` 一致（2026-11-14 首次拆分就满足，这是"零改动搬迁"的判据）。

## 2. 模块顺序（文件名即拼接顺序）

| 文件 | 职责 | 不要放进这里 |
|---|---|---|
| 文件 | 职责 | 不要放进这里 |
|---|---|---|
| `00-header.sh` | 文件头注释、全局变量、`HB_CMDS` 表 | 函数实现 |
| `05-platform.sh` | **平台层**：MSYS/编码/路径/主机名/端口探针 | 业务逻辑 |
| `10-net.sh` | 网络、tailscale CLI 调用 | SSH |
| `20-bootstrap.sh` | 二进制从哪来、`ssh_proxy_cmd`、私钥定位 | 业务 |
| `30-ssh.sh` | SSH 身份、`hosts` 别名、ssh/scp 封装 | 业务 |
| `40-run.sh` | `hb <机器> <命令>`、doctor、up | 分发 |
| `50-ts-api.sh` | Tailscale 控制面 API、list、lend（帽子） | 别的 |
| `60-dist.sh` | enroll：白名单服务 + Funnel + 等上线 | 核对 |
| `70-sync.sh` | 公钥名单同步 | — |
| `90-main.sh` | 参数分派、别名展开、help 渲染 | 业务 |

## 3. 平台层规则（强约束）

- 判断平台**只能**用 `hb_is_msys / hb_is_windows / hb_is_macos`，不要再写 `uname -s`
- 主机名一律走 `hb_hostname`（去域后缀）
- **端口探测一律用 `port_open <host> <port> [超时]`**，禁止再写 `nc -z`。
  MSYS（Git Bash）没有 `nc`，`nc -z ... 2>/dev/null` 会**静默失败**，
  把"在监听"报成"未监听"（2026-11-14 现场：借道代理时假报未监听，
  连带 1055 的三处检查全部假阴性）。`port_open` 内部三级降级：
  bash `/dev/tcp` → `nc` → `python3`
- **ssh/scp 目标一律走 `host_ssh_target <名字>`**。别用 `alias_usable` 顶替 ——
  它只校验名字字符串合法，对"只在 hosts 文件里、ssh config 里没有"的名字
  也会返回真，于是 scp 发给不存在的 ssh 别名，报 `Connection closed`
- MSYS 路径改写防护在 `05-platform.sh` 顶部导出（`MSYS_NO_PATHCONV=1`、
  `MSYS2_ARG_CONV_EXCL=*`），**新代码不要自己再 export**，也不要绕开它
- 新增平台分支时，先在这一层加函数，再在调用点使用

## 4. 加一个命令（固定四步）

1. 在 `src/00-header.sh` 的 `HB_CMDS` 里加一行：`"名字|cmd_名字|一句话说明"`
   （help 和分派共用这张表，**一处定义两处使用**）
2. 在职责对应的 `src/XX-*.sh` 里写 `cmd_名字()`；职责不清就新建一个模块
3. 报错必须遵循错误契约：**"哪里坏了 + 怎么修"**（含可直接执行的命令）
4. 在 `tests/run.sh` 里加至少一条用例，跑通后再 build

## 5. 验收（必须全绿才提交）

```
bash build.sh            # 拼出 hb
bash tests/run.sh        # 离线护栏
python3 check_fn_order.py hb
bash tests/run.sh --online   # 可选：含真实 ssh
```

## 6. 错误契约

- 退出码：0 = 成功；非 0 = 失败。未知子命令必须非 0 且带"怎么修"
- 不要输出"ssh 失败"这种没有动作的报错；要写清是哪个别名、哪一步、怎么补
- 测试里专门有一条检查这个契约（`未知命令给了有用提示`）

## 7. 将来换语言时（Go/Rust）必须保持不变的

1. 命令名、参数形态、退出码
2. `hb <机器> <命令>` 的兜底语义（子命令优先于机器名）
3. `--json` 输出字段名
4. 错误契约："哪里坏了 + 怎么修"
5. 分发自包含：`hb enroll` 分发后对方只需要 hb 一个文件，不拉第二个

`tests/run.sh` 就是这些契约的可执行版本——**换语言时让它先跑起来**。
