# ── 分派 ───────────────────────────────────────────────────────────
# 帮助只输出「这是什么 + 命令表」：实施细节（为什么这么判）留给读源码的人。
# 命令清单来自 HB_CMDS —— 一处定义，两处使用，不会漂。
show_help() {
  printf 'hb —— 把「连上、修好、干活」收进一个文件\n\n'
  printf '  裸调用 hb = 只读体检。它回答三个问题：这台机器能不能连出去、\n'
  printf '  缺什么、下一步该敲哪条命令。\n\n'
  printf '  命令\n'
  local e name fn desc
  for e in "${HB_CMDS[@]}"; do
    IFS='|' read -r name fn desc <<< "$e"
    printf '    hb %-11s %s\n' "$name" "$desc"
  done
  printf '\n'
  printf '  别名  status → ts status，host → hosts\n'
  printf '  远程  hb <机器> <命令...>   机器 = 别名 | ssh Host | 网内节点名 | IP\n\n'
  printf '  身份  不自带密钥：依次找 $HB_KEY_FILE、$HB_HOME/hb_key、~/.ssh/<key>\n'
  printf '  凭据  不自带入网凭据：$HB_STATE_DIR/credentials.json 或 $TAILSCALE_AUTHKEY\n'
}

# 裸调用 = doctor：只读、无副作用。想不起子命令时敲一下也有有效输出。
[ $# -eq 0 ] && { cmd_doctor; exit $?; }

# 别名先展开（status → ts status），再查命令表
for _al in "${HB_ALIASES[@]}"; do
  IFS='|' read -r _an _at <<< "$_al"
  if [ "$1" = "$_an" ]; then
    shift
    set -- $_at "$@"
    break
  fi
done

case "$1" in
  -h|--help|help) show_help; exit 0 ;;
  -*) show_help; exit 2 ;;
esac

for _cm in "${HB_CMDS[@]}"; do
  IFS='|' read -r _cn _cf _cd <<< "$_cm"
  if [ "$1" = "$_cn" ]; then
    shift
    "$_cf" "$@"
    exit $?
  fi
done

# 兜底：首参不是已知子命令，才当成机器名（hb box "uptime"）。
# 子命令永远优先；hosts add 时也拦了重名，这里再判一次是防手改 hosts 文件。
cmd_run "$@"
exit $?
