#!/usr/bin/env bash
#
# Browser Panel + RuyiPage 一键修复脚本（修订版）
#
# 相对原版的改动：
#  1. [2/7] 自动给 panel-start.sh 补上 PROOT_ENV / PROOT_NO_SECCOMP 导出。
#     原版只写 /etc/profile.d，非 login shell 启动（比如开机自启、bash script.sh）
#     根本不会加载它，变量送不到 panel 进程，补丁直接失效——这是原版最大的坑。
#  2. [4/7] 补丁改写：对着 browser-panel 实际代码的精确特征串打补丁；
#     幂等（重复跑不会打坏）；特征串对不上时明确报错退出，而不是静默跳过。
#  3. [6/7] 不再无条件 pkill 所有 Firefox：2828 已有监听时默认跳过破坏性测试，
#     避免杀掉正在跑任务的浏览器；确实需要干净重测时用 --force。
#
# 用法：
#   bash fix_browser.sh              # 安全模式：不杀已有浏览器
#   bash fix_browser.sh --force      # 强制模式：杀掉已有 Firefox 后完整重测
#   bash fix_browser.sh --patch-only # 仅重打 PRoot 补丁（跳过 Firefox 测试，供开服自愈调用）
#
set -euo pipefail

FORCE=0
PATCH_ONLY=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
elif [[ "${1:-}" == "--patch-only" ]]; then
  PATCH_ONLY=1
fi

FIREFOX="/opt/ruyipage-firefox/firefox"
PANEL="/opt/browser-panel"
LAUNCHER="$PANEL/server/runtime/browser-launcher.js"
PANEL_START="/root/panel-start.sh"
ENV_FILE="/etc/profile.d/browser-panel-proot.sh"
PYTHON_BIN="$(command -v python3 || true)"

echo "=================================================="
echo " Browser Panel + RuyiPage 一键修复脚本（修订版）"
echo "=================================================="
[[ "$FORCE" == "1" ]] && echo "(--force 模式：允许杀掉已有 Firefox 进程)"

# ============================================================
# 1. 检查环境
# ============================================================
echo
echo "[1/7] 检查环境..."
if [ ! -f "$FIREFOX" ]; then
  echo "⚠️ 找不到魔改 Firefox: $FIREFOX"
  echo "   先继续打 PRoot 补丁（不影响面板启动），只跳过最后的冒烟测试。"
  echo "   补 Firefox 的办法：把 ruyipage-firefox.tar.gz 传到"
  echo "   MyWorlds/Ubuntu24/root/，下次开服会自动解压到 /opt/；"
  echo "   然后再建一个空文件 .refix-browser 开服一次，会重跑本脚本补测。"
  NO_FIREFOX=1
else
  echo "✅ Firefox: $FIREFOX"
  NO_FIREFOX=0
fi

if [ ! -f "$LAUNCHER" ]; then
  echo "❌ 找不到 browser-launcher.js: $LAUNCHER"
  exit 1
fi
echo "✅ Browser launcher: $LAUNCHER"

# ============================================================
# 2. PRoot 环境变量（profile.d + panel-start.sh 双保险）
# ============================================================
echo
echo "[2/7] 配置 PRoot 环境..."

# 2a. profile.d：给 login shell / SSH 用
cat > "$ENV_FILE" <<'EOF'
export PROOT_NO_SECCOMP=1
export PROOT_ENV=1
EOF
chmod 644 "$ENV_FILE"
echo "✅ 已写入: $ENV_FILE"

# 2b. panel-start.sh：给非 login shell / 开机自启用（关键！）
#     只靠 profile.d 的话，bash panel-start.sh 这类启动方式拿不到变量，
#     launcher 里的 PROOT 判断直接失效，Firefox 照样起不来。
if [ -f "$PANEL_START" ]; then
  if grep -q "PROOT_ENV" "$PANEL_START" 2>/dev/null; then
    echo "✅ panel-start.sh 已有 PROOT_ENV（跳过）"
  else
    cp "$PANEL_START" "$PANEL_START.bak.$(date +%Y%m%d_%H%M%S)"
    "$PYTHON_BIN" - "$PANEL_START" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
t = p.read_text()
ins = 'export PROOT_NO_SECCOMP=1\nexport PROOT_ENV=1\n\n'
anchor = 'echo "[BP] stopping old processes..."'
if anchor in t:
    t = t.replace(anchor, ins + anchor, 1)
else:
    # 兜底：找不到锚点就插到 shebang 后面
    t = t.replace('#!/bin/bash\n', '#!/bin/bash\n' + ins, 1)
p.write_text(t)
print('✅ panel-start.sh 已补上 PROOT 环境变量')
PY
  fi
else
  echo "⚠️ 找不到 $PANEL_START，跳过（请手动确认启动脚本里 export 了 PROOT_ENV=1）"
fi

export PROOT_NO_SECCOMP=1
export PROOT_ENV=1
echo "   当前 shell: PROOT_ENV=1 PROOT_NO_SECCOMP=1"

# ============================================================
# 3. 备份 browser-launcher.js
# ============================================================
echo
echo "[3/7] 备份 browser-launcher.js..."
BACKUP="$LAUNCHER.bak.$(date +%Y%m%d_%H%M%S)"
cp "$LAUNCHER" "$BACKUP"
echo "✅ 备份: $BACKUP"

# ============================================================
# 4. 修复 PRoot 下的 setpriv / uid / gid
#    对着 browser-panel 实际代码打补丁（已按 f0dc828 版校验特征串），
#    幂等：重复执行不会重复打；特征串对不上则报错退出。
# ============================================================
echo
echo "[4/7] 修复 PRoot 下的 setpriv / uid / gid..."
"$PYTHON_BIN" - "$LAUNCHER" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

# 要 guard 的两个分支（4 空格缩进，与源码一致）：
patches = [
    ("setpriv 降权分支",
     "    if (Number.isFinite(runUid) && Number.isFinite(runGid)) {",
     "    if (process.env.PROOT_ENV !== '1' && Number.isFinite(runUid) && Number.isFinite(runGid)) {"),
    ("spawn uid/gid 分支",
     "    if ((!finalCmd.includes('setpriv')) && Number.isFinite(runUid) && Number.isFinite(runGid)) {",
     "    if (process.env.PROOT_ENV !== '1' && (!finalCmd.includes('setpriv')) && Number.isFinite(runUid) && Number.isFinite(runGid)) {"),
]

changed = 0
for name, old, new in patches:
    if new in text:
        print(f"  [跳过] {name}：已打过补丁")
        continue
    if old not in text:
        print(f"  [失败] {name}：在 launcher 中找不到特征代码")
        print("  面板版本可能已变化，请检查 browser-launcher.js 后手动处理。")
        sys.exit(2)
    text = text.replace(old, new, 1)
    changed += 1
    print(f"  [OK] {name}：已打补丁")

if changed:
    path.write_text(text)
    print("✅ browser-launcher.js 已修改")
else:
    print("✅ 无需修改（已是补丁状态）")
PY

# ============================================================
# 5. 检查 ruyipage Marionette 端口（--patch-only 跳过）
# ============================================================
if [[ "$PATCH_ONLY" == "0" ]]; then
echo
echo "[5/7] 检查 ruyipage Marionette..."
RUYI_PATH=""
if [ -n "$PYTHON_BIN" ]; then
  RUYI_PATH="$("$PYTHON_BIN" - <<'PY' 2>/dev/null || true
try:
    import ruyipage, os
    print(os.path.dirname(ruyipage.__file__))
except Exception:
    pass
PY
)"
fi

if [ -z "$RUYI_PATH" ]; then
  echo "⚠️ 无法找到 ruyipage Python 路径（跳过端口检查）"
else
  echo "✅ ruyipage: $RUYI_PATH"
  MARIONETTE_FILE="$RUYI_PATH/_adapter/marionette.py"
  if [ -f "$MARIONETTE_FILE" ]; then
    if grep -q "MARIONETTE_PORT = 2828" "$MARIONETTE_FILE"; then
      echo "✅ ruyipage Marionette 已经是 2828"
    else
      echo "⚠️ ruyipage Marionette 不是 2828，正在修改..."
      cp "$MARIONETTE_FILE" "$MARIONETTE_FILE.bak.$(date +%Y%m%d_%H%M%S)"
      sed -i -E "s/MARIONETTE_PORT[[:space:]]*=[[:space:]]*[0-9]+/MARIONETTE_PORT = 2828/" "$MARIONETTE_FILE"
      echo "✅ 已修改为 2828（注意：pip 升级 ruyipage 后会被还原，需重跑本脚本）"
    fi
  else
    echo "⚠️ 找不到: $MARIONETTE_FILE"
  fi
fi

# ============================================================
# 6. 测试 Firefox（安全模式：不误杀已有实例）
# ============================================================
echo
echo "[6/7] 检查魔改 Firefox..."
echo
"$FIREFOX" --version || true
echo

SKIP_TEST=0
if [[ "${NO_FIREFOX:-0}" == "1" ]]; then
  echo "⚠️ Firefox 缺失，跳过 Marionette 冒烟测试（PRoot 补丁已打，不影响面板启动）"
  SKIP_TEST=1
elif ss -lnt 2>/dev/null | grep -q "127.0.0.1:2828"; then
  if [[ "$FORCE" == "1" ]]; then
    echo "⚠️ 2828 已被占用，--force 模式：杀掉已有 Firefox 后重测"
    pkill -f "/opt/ruyipage-firefox/firefox" 2>/dev/null || true
    sleep 1
  else
    echo "✅ 127.0.0.1:2828 已有监听（应为已在跑的 Firefox/Marionette），跳过破坏性测试"
    echo "   如需杀掉重测：bash fix_browser.sh --force"
    SKIP_TEST=1
  fi
fi

if [[ "$SKIP_TEST" == "0" ]]; then
  echo "测试 Firefox Marionette..."
  TEST_PROFILE="/tmp/ruyi-fix-test-profile"
  rm -rf "$TEST_PROFILE"
  mkdir -p "$TEST_PROFILE"
  LOG="/tmp/ruyi-firefox-fix-test.log"
  "$FIREFOX" --headless --marionette --no-remote -profile "$TEST_PROFILE" > "$LOG" 2>&1 &
  FIREFOX_PID=$!
  echo "Firefox PID: $FIREFOX_PID"
  echo "等待 Marionette..."
  OK=0
  for _ in $(seq 1 15); do
    if ss -lnt 2>/dev/null | grep -q "127.0.0.1:2828"; then
      OK=1
      break
    fi
    sleep 1
  done
  kill "$FIREFOX_PID" 2>/dev/null || true
  rm -rf "$TEST_PROFILE"
  if [[ "$OK" == "1" ]]; then
    echo
    echo "✅ Firefox Marionette 2828 正常"
  else
    echo
    echo "❌ Firefox 没有监听 2828"
    echo
    echo "Firefox 日志:"
    cat "$LOG"
    exit 3
  fi
fi

fi # PATCH_ONLY 跳过 [5/7][6/7]

# ============================================================
# 7. 清理 + 总结
# ============================================================
echo
echo "=================================================="
echo " 修复完成"
echo "=================================================="
echo
echo "✅ 魔改 Firefox: $FIREFOX"
echo "✅ Marionette: 127.0.0.1:2828"
echo "✅ PRoot: PROOT_ENV=1 PROOT_NO_SECCOMP=1"
echo "✅ browser-launcher: PRoot 下跳过 setpriv / uid/gid 降权"
echo
echo "备份文件:"
echo "  $BACKUP"
echo
echo "现在可以重启 Browser Panel，然后测试任务："
echo "  bash /root/panel-start.sh"
echo
echo "⚠️ 两个需要记住的还原点："
echo "  1. 面板升级（bp.sh）会覆盖 browser-launcher.js，补丁消失 → 重跑本脚本"
echo "  2. pip 升级 ruyipage 会还原 marionette 端口修改 → 重跑本脚本"
echo "  3. 本方案为单实例设计：多开 Firefox 会抢 2828 端口，不支持并发"
echo
