#!/bin/bash

APP=/opt/browser-panel

NODE=/opt/node22/bin/node

FIREFOX=/opt/ruyipage-firefox/firefox

CHROME=/usr/bin/chromium-browser

# PRoot 环境变量（关键）：
# 只靠 /etc/profile.d 不够——非 login shell（开机自启、bash script.sh）
# 不会加载 profile.d，变量送不到 panel 进程，launcher 里的 PROOT 判断直接失效。
# 所以启动脚本里必须显式 export。
export PROOT_NO_SECCOMP=1
export PROOT_ENV=1

echo "[BP] stopping old processes..."

pkill -f '[X]vfb :1' 2>/dev/null || true

pkill -f 'server/index.js' 2>/dev/null || true

sleep 2

# 兜底：Xvfb 没杀干净、或上次崩溃残留的锁（/tmp 在 proot 里是持久化目录，
# stale 锁不会随重启消失），否则新 Xvfb 报 "Server is already active for display :1"
pkill -9 -f '[X]vfb :1' 2>/dev/null || true

rm -f /tmp/.X1-lock


echo "[BP] starting Xvfb..."

/usr/bin/Xvfb :1 \
-screen 0 1440x900x24 \
-ac \
+extension GLX \
+render \
-noreset \
>>$APP/logs/xvfb.log 2>&1 &

XVFB_PID=$!

echo $XVFB_PID > $APP/pids/xvfb.pid

sleep 2

echo "[BP] starting panel..."

cd $APP
export NODE_ENV=production
export DISPLAY=:1.0
export BROWSER_CHROME_PATH=$CHROME
export PLAYWRIGHT_CHROME_PATH=$CHROME
export RUYIPAGE_FIREFOX_PATH=$FIREFOX

nohup $NODE server/index.js \
>>$APP/logs/panel.log 2>&1 &

PID=$!

echo $PID > $APP/pids/panel.pid

echo "[BP] started"

echo "Xvfb PID: $XVFB_PID"

echo "Panel PID: $PID"

echo "http://0.0.0.0:3210"
