#!/usr/bin/env bash
# 把 src/*.sh 拼成单文件 hb（分发物就是这一个文件）
#
# 设计约束（别破坏）：
#   · 拼接顺序 = 文件名字典序：00-header → 10-net → … → 90-main → 99-tail-payload
#     最后那个 99 是「内嵌载荷」的尾巴（标记 + base64 数据），必须是文件最末
#   · 产物必须是 hb（不是 dist/hb）—— hb.cmd、hb enroll、AGENTS.md 都按这个名字找
#   · 自检：拼完先 bash -n，再确认载荷标记在最后 10 行内，否则不替换原文件
set -euo pipefail
cd "$(dirname "$0")"

OUT=hb
TMP=$(mktemp "${TMPDIR:-/tmp}/hb.build.XXXXXX")
trap 'rm -f "$TMP"' EXIT

for f in src/*.sh; do
  [ -s "$f" ] || { echo "空模块: $f" >&2; exit 1; }
  cat "$f" >> "$TMP"
done

bash -n "$TMP" || { echo "语法检查失败，未替换 $OUT" >&2; exit 1; }

# 自检：分发器必须真的在文件末尾（少一个模块就会「命令存在但敲不动」）
tail -5 "$TMP" | grep -q '^cmd_run "\$@"$' || {
  echo "分发器不在文件尾部（少了模块？），未替换 $OUT" >&2; exit 1; }

# ── 覆盖前留档：保护"直接改产物"的那类工作 ──────────────────────────
# 2026-11-14 事故：有人直接改了 hb（没改 src/），另一个人跑 build.sh 把改动无声覆盖。
# 现在只要新旧内容不同就先另存，并在 git 显示该文件被修改时明确警告。
if [ -f "$OUT" ] && ! cmp -s "$TMP" "$OUT"; then
  STAMP=$(date +%Y%m%d-%H%M%S)
  BAK="hb.bak-$STAMP"
  cp -p "$OUT" "$BAK"
  echo "⚠️  产物与 src/ 不一致，旧版已另存：$BAK"
  if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    if [ -n "$(git status --porcelain -- "$OUT" 2>/dev/null)" ]; then
      echo "⚠️  git 显示 $OUT 有未提交改动 —— 这些改动很可能只存在于产物里，"
      echo "    把逻辑搬进 src/ 再重跑，否则下次 build 还会覆盖。备份：$BAK"
    fi
  fi
  ls -1t hb.bak-* 2>/dev/null | tail -n +6 | xargs -r rm -f
fi

chmod +x "$TMP"
mv "$TMP" "$OUT"
trap - EXIT
printf '✓ %s  %s 行 / %s\n' "$OUT" "$(wc -l < "$OUT")" "$(du -h "$OUT" | cut -f1)"
