#!/bin/bash
###############################################################################
# proot 内 VNC/noVNC 启动脚本。
#
# 链路：Xvfb(:1) → x11vnc(:1 → 5901) → websockify(noVNC 网页 → VNC_PORT)
# 由 panel-start.sh 在 Xvfb 就绪后调用。幂等：重复开服先杀旧进程再起。
#
# 环境变量（从 jar 经 start.sh → proot 透传进来）：
#   VNC_PASSWORD  必填。为空则本脚本直接退出（不启用 VNC）。
#   VNC_PORT      noVNC 网页端口，默认 6080。
#
# 密码处理：x11vnc -storepasswd 加密落盘到 /root/.vnc/passwd（600），
# 明文密码只在 storepasswd 的 argv 里出现一瞬间，不进日志文件。
###############################################################################

# 不设 -e：任何一步失败只跳过 VNC，绝不能炸掉 panel-start.sh 主流程
set -uo pipefail

VNC_PORT="${VNC_PORT:-6080}"
RFB_PORT=5901
APP=/opt/browser-panel
LOGDIR="$APP/logs"
PASSWD_FILE="/root/.vnc/passwd"

if [ -z "${VNC_PASSWORD:-}" ]; then
  echo "[VNC] 未设置 VNC_PASSWORD，跳过 VNC/noVNC"
  exit 0
fi

echo "[VNC] 启动 noVNC 栈（web :$VNC_PORT ← rfb :$RFB_PORT ← X :1）..."

# ---- 1. 依赖：缺啥装啥（装过一次以后开服直接跳过） ----
if ! command -v x11vnc >/dev/null 2>&1 || ! command -v websockify >/dev/null 2>&1 \
    || [ ! -d /usr/share/novnc ]; then
  echo "[VNC] 安装 novnc/websockify/x11vnc..."
  export DEBIAN_FRONTEND=noninteractive
  if ! apt-get update -qq >>"$LOGDIR/vnc-install.log" 2>&1 \
      || ! apt-get install -y -qq novnc websockify x11vnc >>"$LOGDIR/vnc-install.log" 2>&1; then
    echo "[VNC] ERROR: apt 安装失败，详见 $LOGDIR/vnc-install.log，本次跳过 VNC（面板不受影响）"
    exit 0
  fi
  echo "[VNC] 依赖安装完成"
else
  echo "[VNC] 依赖已存在，跳过安装"
fi

# ---- 2. 清理旧进程（重复开服时） ----
pkill -f "[x]11vnc.*-rfbport $RFB_PORT" 2>/dev/null || true
pkill -f "[w]ebsockify.*$RFB_PORT" 2>/dev/null || true
sleep 1

# ---- 3. 密码文件 ----
mkdir -p /root/.vnc
x11vnc -storepasswd "$VNC_PASSWORD" "$PASSWD_FILE" >/dev/null 2>&1
chmod 600 "$PASSWD_FILE"

# ---- 4. x11vnc：把 :1 的画面推到 5901 ----
x11vnc -display :1 -forever -shared \
  -rfbport "$RFB_PORT" -rfbauth "$PASSWD_FILE" \
  -bg -o "$LOGDIR/x11vnc.log"
echo "[VNC] x11vnc 已启动（:1 → 127.0.0.1:$RFB_PORT）"

# ---- 5. websockify：noVNC 网页服务 ----
nohup websockify --web /usr/share/novnc/ "$VNC_PORT" "localhost:$RFB_PORT" \
  >>"$LOGDIR/websockify.log" 2>&1 &
echo $! > "$APP/pids/websockify.pid"
sleep 1
if kill -0 "$(cat "$APP/pids/websockify.pid")" 2>/dev/null; then
  echo "[VNC] noVNC 已启动：http://0.0.0.0:$VNC_PORT/vnc.html（用 VNC 密码登录）"
else
  echo "[VNC] ERROR: websockify 启动失败，详见 $LOGDIR/websockify.log（面板不受影响）"
fi
