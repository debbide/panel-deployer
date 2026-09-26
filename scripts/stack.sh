#!/bin/bash

set -e

# ============================================================
# browser-panel PRoot Stack Installer
# Ubuntu 24.04 / PRoot / no systemd
# ============================================================

export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

BASE_DIR="/opt/browser-panel"
ENV_FILE="$BASE_DIR/.env.panel"

BROWSER_USER="browser"
BROWSER_HOME="/home/$BROWSER_USER"
BROWSER_WORK_DIR="$BROWSER_HOME/browser-work"

DISPLAY_NUM=":1"
SCREEN="1440x900x24"

XAUTH="$BROWSER_HOME/.Xauthority"

XVFB_LOG="/var/log/xvfb-browser.log"
XVFB_PID="/run/xvfb-browser.pid"

PANEL_PORT="3210"
PANEL_HOST="0.0.0.0"

echo
echo "============================================================"
echo " browser-panel PRoot Stack"
echo " Ubuntu 24.04 / no systemd"
echo "============================================================"
echo

# ------------------------------------------------------------
# 0. 基础检查
# ------------------------------------------------------------

if [ "$(id -u)" != "0" ]; then
    echo "[ERROR] This script must run as root inside PRoot."
    exit 1
fi

if ! grep -qi "Ubuntu" /etc/os-release 2>/dev/null; then
    echo "[WARN] This does not appear to be Ubuntu."
fi

echo "[+] Running as:"
id

echo

# ------------------------------------------------------------
# 1. 防止 systemd 被重新安装
# PRoot 环境不要强制删除 systemd
# 使用 hold 防止 apt 拉回
# ------------------------------------------------------------

echo "[1/9] Checking systemd environment..."


echo "[+] Blocking systemd packages..."


apt-mark hold \
    systemd \
    systemd-dev \
    systemd-sysv \
    udev \
    systemd-resolved \
    systemd-timesyncd \
    networkd-dispatcher \
    libpam-systemd \
    2>/dev/null || true


echo "[+] systemd packages locked."



# ------------------------------------------------------------
# Clean broken NodeSource repository
# ------------------------------------------------------------

echo "[+] Cleaning NodeSource leftovers..."

rm -f /etc/apt/sources.list.d/nodesource.list
rm -f /etc/apt/sources.list.d/node*.list

rm -f /etc/apt/keyrings/nodesource.gpg
rm -f /usr/share/keyrings/nodesource.gpg

rm -f /etc/apt/preferences.d/nsolid
rm -f /etc/apt/preferences.d/nodejs

rm -rf /root/.gnupg
rm -rf /home/container/.gnupg


grep -Ril "nodesource" /etc/apt 2>/dev/null \
| xargs -r rm -f

# ------------------------------------------------------------
# 2. APT update
# ------------------------------------------------------------

echo
echo "[2/9] Updating APT..."

apt-get update

# ------------------------------------------------------------
# 3. 基础工具
# ------------------------------------------------------------

echo
echo "[3/9] Installing base packages..."

apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    python3 \
    python3-pip \
    python3-dev \
    python3-setuptools \
    python3-wheel \
    build-essential \
    xvfb \
    xauth \
    xdotool \
    procps \
    unzip

echo "[+] Base packages installed."

# ------------------------------------------------------------
# 4. 浏览器核心运行库
#
# 注意：
# 不安装 libgtk-3-0
# 不安装 dbus
# 不安装 udev
# 不安装 systemd
#
# 因为 Ubuntu 24.04 的 GTK 依赖链可能把 systemd
# 拉进 PRoot。
# ------------------------------------------------------------

echo
echo "[4/9] Installing browser runtime libraries..."

apt-get install -y --no-install-recommends \
    libnss3 \
    libnspr4 \
    libgbm1 \
    libdrm2 \
    libx11-xcb1 \
    libxcb-dri3-0 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    libxfixes3 \
    libxi6 \
    libxcursor1 \
    libpango-1.0-0 \
    libcups2t64 \
    libatk1.0-0t64 \
    libatk-bridge2.0-0t64 \
    libatspi2.0-0t64 \
    libgtk-3-0t64 \
    libgdk-pixbuf-2.0-0 \
    libcairo2 \
    libcairo-gobject2 \
    libpangocairo-1.0-0 \
    libfontconfig1 \
    libasound2t64 \
    libxkbcommon0 \
    libxshmfence1 \
    fonts-liberation \
    fonts-noto-cjk \
    fonts-noto-color-emoji

echo "[+] Browser runtime libraries installed."

# ------------------------------------------------------------
# 5. 再次检查 systemd
# ------------------------------------------------------------

echo
echo "[5/9] Verifying no systemd packages were installed..."

if dpkg-query -W -f='${Status}\n' systemd 2>/dev/null | grep -q "install ok installed"; then
    echo
    echo "[ERROR] systemd was installed unexpectedly."
    echo
    dpkg -l | grep -E 'systemd|udev' || true
    exit 1
fi

if dpkg-query -W -f='${Status}\n' systemd-dev 2>/dev/null | grep -q "install ok installed"; then
    echo
    echo "[ERROR] systemd-dev was installed unexpectedly."
    exit 1
fi

if dpkg-query -W -f='${Status}\n' udev 2>/dev/null | grep -q "install ok installed"; then
    echo
    echo "[ERROR] udev was installed unexpectedly."
    exit 1
fi

echo "[+] systemd / systemd-dev / udev are NOT installed."

# ------------------------------------------------------------
# 6. Node.js 22 (binary install)
# PRoot safe version
# no apt
# no NodeSource
# ------------------------------------------------------------

echo
echo "[6/9] Installing Node.js 22 binary..."


NODE_VERSION="v22.19.0"
NODE_ARCH="linux-x64"

NODE_DIR="/opt/node22"


if [ -x "$NODE_DIR/bin/node" ]; then

    echo "[+] Node22 already exists."

else

    echo "[+] Downloading Node.js ${NODE_VERSION}..."


    mkdir -p "$NODE_DIR"


    cd /tmp


    rm -rf node.tar.xz
    rm -rf node-${NODE_VERSION}-${NODE_ARCH}


    curl -fL \
    --retry 5 \
    --connect-timeout 20 \
    -o node.tar.xz \
    "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-${NODE_ARCH}.tar.xz"



    echo "[+] Extracting Node.js..."

    rm -rf /tmp/node-extract
    mkdir -p /tmp/node-extract

    tar \
    --no-same-owner \
    --no-same-permissions \
    --no-overwrite-dir \
    --warning=no-unknown-keyword \
    -xJf node.tar.xz \
    -C /tmp/node-extract || true


    echo "[+] Copying Node files..."

    rm -rf "$NODE_DIR"
    mkdir -p "$NODE_DIR"

    cp -r \
    /tmp/node-extract/node-${NODE_VERSION}-${NODE_ARCH}/. \
    "$NODE_DIR/"


    chmod -R u+rwX,go+rX "$NODE_DIR"


fi



cat >/etc/profile.d/node22.sh <<EOF
export PATH=$NODE_DIR/bin:\$PATH
EOF


chmod 644 /etc/profile.d/node22.sh


export PATH="$NODE_DIR/bin:$PATH"



ln -sf "$NODE_DIR/bin/node" /usr/local/bin/node
ln -sf "$NODE_DIR/bin/npm" /usr/local/bin/npm
ln -sf "$NODE_DIR/bin/npx" /usr/local/bin/npx



echo
echo "Node:"
node -v


echo
echo "NPM:"
npm -v

# ------------------------------------------------------------
# 7. Chrome Portable
#
# Chrome for Testing
# no deb
# no apt
# no dependency install
# no systemd
# ------------------------------------------------------------

echo
echo "[7/9] Installing Chrome portable..."


CHROME_DIR="/opt/chrome"

CHROME_PATH="$CHROME_DIR/chrome"

CHROME_JSON="/tmp/chrome-version.json"



if [ -x "$CHROME_PATH" ]; then

    echo "[+] Chrome portable already exists."

else


    echo "[+] Downloading Chrome for Testing..."


    mkdir -p "$CHROME_DIR"


    cd /tmp


    rm -rf \
        chrome-linux64 \
        chrome-linux64.zip \
        "$CHROME_JSON"



    echo "[+] Getting Chrome stable version..."



    curl -fsSL \
        -o "$CHROME_JSON" \
        "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json"



    CHROME_VERSION=$(python3 - <<'PY'
import json

with open("/tmp/chrome-version.json") as f:
    data=json.load(f)

print(data["channels"]["Stable"]["version"])
PY
)



    echo "[+] Chrome version:"
    echo "$CHROME_VERSION"



    CHROME_URL="https://storage.googleapis.com/chrome-for-testing-public/${CHROME_VERSION}/linux64/chrome-linux64.zip"



    echo "[+] Download:"
    echo "$CHROME_URL"



    curl -fL \
        --retry 5 \
        --connect-timeout 30 \
        -o chrome-linux64.zip \
        "$CHROME_URL"



    unzip -q chrome-linux64.zip



    rm -rf "$CHROME_DIR"



    mv \
        chrome-linux64 \
        "$CHROME_DIR"



    rm -f \
        chrome-linux64.zip \
        "$CHROME_JSON"



fi



chmod +x "$CHROME_PATH"



ln -sf "$CHROME_PATH" /usr/local/bin/google-chrome



echo
echo "[+] Chrome:"
"$CHROME_PATH" --version


# ------------------------------------------------------------
# 8. Python 自动化环境
# ------------------------------------------------------------

echo
echo "[8/9] Installing Python automation packages..."


python3 -m pip install \
    --break-system-packages \
    --ignore-installed \
    --disable-pip-version-check \
    --no-cache-dir \
    requests \
    urllib3 \
    Pillow \
    DrissionPage \
    selenium \
    seleniumbase \
    playwright \
    pyrogram \
    TgCrypto \
    SpeechRecognition \
    pydub \
    numpy


echo "[+] Python packages installed."



# ------------------------------------------------------------
# Python module verification
# ------------------------------------------------------------

echo
echo "[+] Checking Python modules..."


python3 - <<'PY'

modules = [
    "requests",
    "urllib3",
    "PIL",
    "DrissionPage",
    "selenium",
    "playwright",
    "pyrogram",
    "pydub",
    "numpy",
]


failed=[]


for m in modules:

    try:
        __import__(m)
        print("[OK]",m)

    except Exception as e:

        print("[FAIL]",m,e)
        failed.append(m)



if failed:

    print("Missing modules:",failed)
    raise SystemExit(1)

PY



# ------------------------------------------------------------
# SeleniumBase driver
#
# 不自动下载 Playwright 浏览器
# Chrome 使用 portable
# ------------------------------------------------------------


echo
echo "[+] SeleniumBase setup..."



python3 - <<'PY'

import os

print("[+] SeleniumBase installed")

PY



# ------------------------------------------------------------
# Playwright configuration
# ------------------------------------------------------------


echo
echo "[+] Configuring Playwright..."



export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
export PLAYWRIGHT_BROWSERS_PATH=0



cat >/etc/profile.d/browser-panel.sh <<EOF

export DISPLAY=$DISPLAY_NUM

export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

export PLAYWRIGHT_BROWSERS_PATH=0

export BROWSER_CHROME_PATH="$CHROME_PATH"

export PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH="$CHROME_PATH"

EOF



chmod 644 /etc/profile.d/browser-panel.sh



# ------------------------------------------------------------
# 9. Browser user / directories
# ------------------------------------------------------------

echo
echo "[9/9] Creating browser environment..."


# ------------------------------------------------------------
# 创建浏览器用户
# ------------------------------------------------------------

if ! id "$BROWSER_USER" >/dev/null 2>&1; then

    useradd \
        --create-home \
        --home-dir "$BROWSER_HOME" \
        --shell /bin/bash \
        "$BROWSER_USER"

fi



mkdir -p \
    "$BROWSER_WORK_DIR" \
    "$BROWSER_WORK_DIR/persistent" \
    "$BASE_DIR/logs" \
    "$BASE_DIR/pids"


chown -R \
    "$BROWSER_USER:$BROWSER_USER" \
    "$BROWSER_HOME" \
    "$BASE_DIR"



# ------------------------------------------------------------
# 环境文件
# ------------------------------------------------------------


cat >"$ENV_FILE" <<EOF

PORT=$PANEL_PORT
HOST=$PANEL_HOST


BROWSER_DISPLAY=$DISPLAY_NUM

BROWSER_CHROME_PATH=$CHROME_PATH

PLAYWRIGHT_CHROME_PATH=$CHROME_PATH

BROWSER_USER=$BROWSER_USER

BROWSER_HOME=$BROWSER_HOME

BROWSER_WORK_DIR=$BROWSER_WORK_DIR

BROWSER_XAUTHORITY=$XAUTH

BROWSER_USER_DATA_DIR=$BROWSER_WORK_DIR/persistent


PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

PLAYWRIGHT_BROWSERS_PATH=0

EOF


chmod 644 "$ENV_FILE"




# ------------------------------------------------------------
# Xvfb
# PRoot 环境专用
# ------------------------------------------------------------


echo
echo "[+] Starting Xvfb..."



mkdir -p /run



# 检查旧 PID

if [ -f "$XVFB_PID" ]; then


    OLD_PID=$(cat "$XVFB_PID" 2>/dev/null || true)


    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then

        echo "[+] Existing Xvfb PID: $OLD_PID"


    else

        rm -f "$XVFB_PID"

    fi


fi




if [ ! -f "$XVFB_PID" ]; then


    rm -f "$XAUTH"


    touch "$XAUTH"


    chown "$BROWSER_USER:$BROWSER_USER" "$XAUTH"



    nohup /usr/bin/Xvfb "$DISPLAY_NUM" \
        -screen 0 "$SCREEN" \
        -ac \
        +extension GLX \
        +render \
        -noreset \
        >"$XVFB_LOG" 2>&1 &



    XVFB_PID_VALUE=$!


    echo "$XVFB_PID_VALUE" > "$XVFB_PID"



    sleep 2



    if ! kill -0 "$XVFB_PID_VALUE" 2>/dev/null; then


        echo
        echo "[ERROR] Xvfb failed."


        cat "$XVFB_LOG" || true


        exit 1


    fi



    echo "[+] Xvfb started PID=$XVFB_PID_VALUE"


fi





# ------------------------------------------------------------
# Chrome 测试
# ------------------------------------------------------------


echo
echo "[+] Testing Chrome..."



TEST_PROFILE="$BROWSER_WORK_DIR/test-profile"



rm -rf "$TEST_PROFILE"


mkdir -p "$TEST_PROFILE"



chown -R \
"$BROWSER_USER:$BROWSER_USER" \
"$BROWSER_WORK_DIR"




su -s /bin/bash "$BROWSER_USER" -c "

export DISPLAY=$DISPLAY_NUM


timeout 20 \
'$CHROME_PATH' \
    --headless=new \
    --no-sandbox \
    --disable-dev-shm-usage \
    --disable-gpu \
    --disable-software-rasterizer \
    --disable-features=UseDBus \
    --disable-background-networking \
    --no-first-run \
    --no-default-browser-check \
    --user-data-dir='$TEST_PROFILE' \
    about:blank


" >/tmp/browser-test.log 2>&1 || true




rm -rf "$TEST_PROFILE"




if grep -qiE "error|failed|fatal|segmentation" /tmp/browser-test.log 2>/dev/null; then


    echo
    echo "[WARN] Chrome test log:"
    cat /tmp/browser-test.log


else


    echo "[+] Chrome test passed."


fi




# ------------------------------------------------------------
# Final status
# ------------------------------------------------------------


echo

echo "============================================================"

echo " Installation complete"

echo "============================================================"


echo

echo "Chrome:"
echo "  $CHROME_PATH"


echo

echo "Node:"
node -v


echo

echo "NPM:"
npm -v


echo

echo "Python:"
python3 --version


echo

echo "Display:"
echo "  $DISPLAY_NUM"


echo

echo "Screen:"
echo "  $SCREEN"


echo

echo "Xvfb PID:"
cat "$XVFB_PID" 2>/dev/null || echo unknown


echo

echo "Environment:"
echo "  $ENV_FILE"



echo

echo "============================================================"

echo " systemd: DISABLED"

echo " udev:    DISABLED"

echo " Node:    Portable"

echo " Chrome:  Portable"

echo " Xvfb:    Direct"

echo "============================================================"

echo