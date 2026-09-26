#!/bin/bash
###############################################################################
# 翼龙(Pterodactyl) 开服启动脚本：proot Ubuntu 24.04 + browser-panel 一键拉起
#
# 用法：
#   1. 把本文件放到翼龙服的 /home/container/start.sh
#   2. 把 server.jar（启动跳板）也放到 /home/container/server.jar
#   3. 翼龙后台 Startup Command 保持默认的 java -jar server.jar 不用动
#   4. 首次开服会自动下载安装 Ubuntu 24.04 proot 环境（几分钟），
#      之后每次开服直接跳过安装、进环境启动面板
#
# 前置条件（只需做一次）：
#   a. proot 里放好修订版 /root/panel-start.sh（含 PROOT_ENV 导出），
#      或跑过一遍修订版 fix_browser.sh（它会自动补上）；
#   b. 面板装好且跑过 fix_browser.sh（launcher 补丁打一次永久有效，
#      文件在 /home/container 里持久化，重启不丢）。
#
# 整条链：翼龙 → java -jar server.jar → /bin/bash start.sh（本文件）
#          → proot → /root/panel-start.sh → browser-panel
###############################################################################

set -euo pipefail

# ---------------- 配置区（按需改） ----------------
CONTAINER_HOME="/home/container"          # 翼龙容器内持久化目录
MW="$CONTAINER_HOME/MyWorlds"             # proot 环境所在目录（和 toor.sh 约定一致；
                                          #  如果之前装在别处，把这里改成实际目录）
ROOTFS_DIR="$MW/Ubuntu24"                 # Ubuntu 根文件系统
TOOR="$ROOTFS_DIR/usr/local/bin/toor"     # PRoot 二进制

# 上游地址（和 toor.sh 保持一致；注意 proot 二进制是 x86_64 的，
# ARM 机器需要换对应架构的 proot 二进制）
ROOTFS_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/24.04.4/release/ubuntu-base-24.04.4-base-amd64.tar.gz"
PROOT_URL="https://raw.githubusercontent.com/kof96zip/MyWorlds/main/proot-x86_64"
# RuyiPage 专用 Firefox（版本固定，保证可复现；与 browser-panel README 一致）
FIREFOX_URL="https://github.com/LoseNine/ruyipage/releases/download/v1.2.66/firefox-155.0.en-US.linux-x86_64.tar.xz"
# --------------------------------------------------

# PRoot 必须的环境变量：
#   PROOT_NO_SECCOMP=1  关掉 seccomp 过滤，否则 proot 下很多系统调用直接被杀
#   PROOT_ENV=1         告诉 browser-panel 当前是 proot，跳过 setpriv 降权
export PROOT_NO_SECCOMP=1
export PROOT_ENV=1
# proot 里没有装 locale，设成 C 消掉 setlocale 警告（不影响功能）
export LC_ALL=C
export LANG=C

# ---------------- 首次运行：安装 proot 环境 ----------------
# 逻辑照搬 toor.sh 的安装部分。装完后 $ROOTFS_DIR/etc 存在，
# 以后每次开服直接跳过这里，不会重复下载。
install_proot() {
  echo "=================================================="
  echo " 首次运行：安装 Ubuntu 24.04 proot 环境"
  echo "=================================================="
  TMP_DIR="$MW/.ubuntu24-install-$$"
  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"

  echo "[1/4] 下载 Ubuntu 24.04.4 base..."
  curl -L --retry 3 -o "$TMP_DIR/ubuntu.tar.gz" "$ROOTFS_URL"

  echo "[2/4] 解压到 $ROOTFS_DIR ..."
  mkdir -p "$ROOTFS_DIR"
  tar -xzf "$TMP_DIR/ubuntu.tar.gz" -C "$ROOTFS_DIR"

  echo "[3/4] 下载 PRoot..."
  mkdir -p "$ROOTFS_DIR/usr/local/bin"
  curl -L --retry 3 -o "$TOOR" "$PROOT_URL"
  chmod +x "$TOOR"

  echo "[4/4] 基础配置（DNS / policy-rc.d / apt 源）..."
  mkdir -p "$ROOTFS_DIR/etc" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/dev" "$ROOTFS_DIR/root"
  if [ -f /etc/resolv.conf ]; then
    cp -L /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"
  fi
  # 禁止 apt 在装包时试图启动服务（proot 里没有 systemd，启动必挂）
  mkdir -p "$ROOTFS_DIR/usr/sbin"
  printf '#!/bin/sh\nexit 101\n' > "$ROOTFS_DIR/usr/sbin/policy-rc.d"
  chmod 755 "$ROOTFS_DIR/usr/sbin/policy-rc.d"
  # apt 源：trusted=yes 是无奈之举（proot 下 keyring 不好使），和 toor.sh 保持一致
  mkdir -p "$ROOTFS_DIR/etc/apt/apt.conf.d" "$ROOTFS_DIR/etc/apt/sources.list.d"
  rm -f "$ROOTFS_DIR/etc/apt/sources.list.d/"*.list "$ROOTFS_DIR/etc/apt/sources.list.d/"*.sources
  cat > "$ROOTFS_DIR/etc/apt/sources.list" <<'APTEOF'
deb [trusted=yes] http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb [trusted=yes] http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb [trusted=yes] http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
deb [trusted=yes] http://archive.ubuntu.com/ubuntu noble-backports main restricted universe multiverse
APTEOF
  cat > "$ROOTFS_DIR/etc/apt/apt.conf.d/99proot" <<'APTEOF'
APT::Sandbox::User "root";
APTEOF

  rm -rf "$TMP_DIR"
  echo "✅ proot 环境安装完成"
}

mkdir -p "$MW"
if [ ! -d "$ROOTFS_DIR/etc" ] || [ ! -x "$TOOR" ]; then
  install_proot
else
  echo "✅ proot 环境已存在，跳过安装"
fi

# 每次开服刷新一次 DNS（宿主机 DNS 可能变化，过期会导致 apt/面板连不上网）
if [ -f /etc/resolv.conf ]; then
  cp -L /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null || true
fi

# ---------------- Firefox 自动供给（宿主机侧，有 curl） ----------------
# RuyiPage 任务需要专用 Firefox 内核（proot 内 /opt/ruyipage-firefox/firefox）。
# 宿主机侧只负责下载（宿主机不一定有 xz，解压在 proot 内做）：
#   1. 用户手工上传的包优先（MyWorlds/Ubuntu24/root/ruyipage-firefox.tar.gz/.tgz/.tar.xz）
#   2. 否则从上游 release 自动下载到 MyWorlds/Ubuntu24/root/.firefox.tar.xz（版本固定）
# rootfs 持久化，下载只做一次；每次开服幂等检查。
provision_firefox() {
  local ff="$ROOTFS_DIR/opt/ruyipage-firefox/firefox"
  if [ -x "$ff" ]; then return 0; fi
  for c in "$ROOTFS_DIR/root/ruyipage-firefox.tar.gz" \
           "$ROOTFS_DIR/root/ruyipage-firefox.tgz" \
           "$ROOTFS_DIR/root/ruyipage-firefox.tar.xz"; do
    if [ -f "$c" ]; then echo "[firefox] 发现手工上传的安装包，proot 内解压"; return 0; fi
  done
  local tb="$ROOTFS_DIR/root/.firefox.tar.xz"
  if [ -f "$tb" ]; then echo "[firefox] 安装包已在本地，proot 内解压"; return 0; fi
  echo "[firefox] 未检测到 /opt/ruyipage-firefox，自动下载 RuyiPage 专用 Firefox..."
  if ! curl -L --retry 3 -o "$tb" "$FIREFOX_URL"; then
    echo "[firefox] ERROR: 下载失败，请检查网络后重启"
    rm -f "$tb"
    return 1
  fi
  echo "[firefox] 下载完成，proot 内解压"
}
provision_firefox

# ---------------- 脚本同步：jar 内嵌脚本是唯一可信来源 ----------------
# 每次开服把 jar 释放出来的脚本同步进 proot 的 /root/，保证里面跑的
# 永远是 jar 里那一套——不用再手动往文件管理里传脚本，也不会出现
# proot 里脚本版本和 jar 对不上的情况。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for s in panel-start.sh install-web.sh stack.sh bp.sh fix_browser.sh vnc-start.sh; do
  if [ -f "$SCRIPT_DIR/$s" ]; then
    cp -f "$SCRIPT_DIR/$s" "$ROOTFS_DIR/root/$s"
  fi
done

# 从翼龙文件管理上传的脚本可能带 Windows 换行符(CRLF)，
# 统一洗掉行尾的 \r（纯 LF 文件不受影响，是空操作）
for f in "$ROOTFS_DIR/root/panel-start.sh" \
         "$ROOTFS_DIR/root/install-web.sh" \
         "$ROOTFS_DIR/root/stack.sh" \
         "$ROOTFS_DIR/root/bp.sh" \
         "$ROOTFS_DIR/root/fix_browser.sh" \
         "$ROOTFS_DIR/root/vnc-start.sh"; do
  [ -f "$f" ] && sed -i 's/\r$//' "$f"
done

# ---------------- 进 proot 并启动面板 ----------------
# 绑定宿主机的 /dev /proc /sys（和 toor.sh 一致，否则里面很多命令不正常）
BIND_OPTS=""
if [ -d /dev ]; then BIND_OPTS="$BIND_OPTS -b /dev"; fi
if [ -d /proc ]; then BIND_OPTS="$BIND_OPTS -b /proc"; fi
if [ -d /sys ]; then BIND_OPTS="$BIND_OPTS -b /sys"; fi
if [ -f /etc/resolv.conf ]; then BIND_OPTS="$BIND_OPTS -b /etc/resolv.conf"; fi

echo "🚀 进入 proot 并启动面板..."

# 注意1：必须用 exec 把 proot 直接顶成当前进程。
#   toor.sh 结尾也是 exec——如果写成「bash toor.sh && 再干别的」，
#   exec 会替换掉整个进程，后面的命令永远跑不到。
# 注意2：proot 里要跑的命令直接跟在 proot 参数后面。
#   /root/panel-start.sh 会把 Xvfb 和 node 都 nohup 到后台然后自己退出，
#   所以最后必须挂一个前台进程（tail -F 盯面板日志），否则翼龙一看
#   启动命令退出了就判服务器离线。顺带还能在翼龙控制台直接看日志。
# 注意3：--kill-on-exit 保证里面的命令退出时 proot 跟着退出，
#   翼龙才能正确感知到关服，而不是留一个空壳进程占着。
# 注意4：下面单引号里的路径（/root/panel-start.sh 等）是 proot【里面】的路径。
# shellcheck disable=SC2086
exec "$TOOR" -r "$ROOTFS_DIR" -0 -w /root $BIND_OPTS --kill-on-exit \
  /bin/bash -c '
    set -e

    # Firefox 供给：宿主机侧已把安装包放到 /root/（手工包或自动下载的 .firefox.tar.xz），
    # 这里解压到 /opt/。proot 内保证有 xz（缺失则 apt 装）。
    if [ ! -x /opt/ruyipage-firefox/firefox ]; then
      tb=""
      for c in /root/ruyipage-firefox.tar.gz /root/ruyipage-firefox.tgz \
               /root/ruyipage-firefox.tar.xz /root/.firefox.tar.xz; do
        if [ -f "$c" ]; then tb="$c"; break; fi
      done
      if [ -z "$tb" ]; then
        echo "[ERROR] 找不到 Firefox 安装包（宿主机侧下载失败，检查开服日志）"
        exit 1
      fi
      echo "解压 Firefox 安装包：$tb ..."
      if ! command -v xz >/dev/null 2>&1; then
        echo "安装 xz-utils..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update && apt-get install -y xz-utils
      fi
      tmpd="$(mktemp -d)"
      tar -xf "$tb" -C "$tmpd"
      # ---- 诊断探针（查 proot 里 -x 失败根因，定位后删除）----
      echo "[diag] 身份: $(id)"
      stat -c "[diag] firefox 文件: 权限=%a 属主=%u:%g 大小=%s" "$tmpd/firefox/firefox" 2>&1 || echo "[diag] firefox 文件不存在"
      printf "#!/bin/sh\nexit 0\n" > "$tmpd/canary.sh"
      chmod +x "$tmpd/canary.sh"
      stat -c "[diag] canary 脚本: 权限=%a" "$tmpd/canary.sh"
      if [ -x "$tmpd/canary.sh" ]; then echo "[diag] canary -x 检查: 通过"; else echo "[diag] canary -x 检查: 失败"; fi
      if "$tmpd/canary.sh"; then echo "[diag] canary 实际执行: 成功"; else echo "[diag] canary 实际执行: 失败"; fi
      if [ -x "$tmpd/firefox/firefox" ]; then echo "[diag] firefox -x 检查: 通过"; else echo "[diag] firefox -x 检查: 失败"; fi
      echo "[diag] 尝试直接执行:"
      "$tmpd/firefox/firefox" --version 2>&1 | head -2 || echo "[diag] 直接执行失败，退出码=$?"
      # ---- 诊断探针结束 ----
      # 注：tmpd 在 /tmp 下（可能 noexec），这里只检查文件存在性，不检查可执行位；
      # 可执行位在搬到 /opt 后再确认。
      srcdir=""
      if [ -f "$tmpd/ruyipage-firefox/firefox" ]; then
        srcdir="$tmpd/ruyipage-firefox"
      elif [ -f "$tmpd/firefox/firefox" ]; then
        srcdir="$tmpd/firefox"
      else
        echo "[ERROR] 安装包里找不到 firefox 文件"
        echo "包内顶层：$(ls "$tmpd" | tr "\n" " ")"
        echo "firefox/ 内容：$(ls "$tmpd/firefox" 2>/dev/null | tr "\n" " ")"
        rm -rf "$tmpd"
        exit 1
      fi
      rm -rf /opt/ruyipage-firefox
      mv "$srcdir" /opt/ruyipage-firefox
      rm -rf "$tmpd"
      chmod +x /opt/ruyipage-firefox/firefox
      if [ ! -x /opt/ruyipage-firefox/firefox ]; then
        echo "[ERROR] /opt/ruyipage-firefox/firefox 无法执行（/opt 可能被挂载为 noexec）"
        exit 1
      fi
      echo "✅ Firefox 已安装到 /opt/ruyipage-firefox"
    fi

    # 安装模式：/opt/browser-panel 不存在 = 全新环境（或被清空）。
    # 自动按顺序跑安装链，装完直接继续往下启动面板，一次开服搞定。
    # 四个安装脚本要提前放到 proot 的 /root/ 下
    #（即翼龙文件管理的 MyWorlds/Ubuntu24/root/）：
    #  install-web.sh / stack.sh / bp.sh 取自 kuisa/proot-ub24 仓库，
    #  fix_browser.sh 用修订版。
    if [ ! -d /opt/browser-panel ]; then
      echo "=================================================="
      echo " 检测到面板未安装，进入安装模式"
      echo "=================================================="
      export DEBIAN_FRONTEND=noninteractive
      export DEBCONF_NONINTERACTIVE_SEEN=true
      for s in install-web.sh stack.sh bp.sh fix_browser.sh; do
        if [ ! -f "/root/$s" ]; then
          echo "[ERROR] 缺少 /root/$s"
          echo "请把 $s 上传到翼龙文件管理的 MyWorlds/Ubuntu24/root/ 后再开服"
          exit 1
        fi
      done
      echo "[1/4] 安装系统依赖（基础工具 / PHP）..."
      bash /root/install-web.sh
      echo "[2/4] 安装浏览器运行栈（node / chrome / python）..."
      bash /root/stack.sh
      echo "[3/4] 安装 browser-panel..."
      bash /root/bp.sh
      echo "[4/4] PRoot 兼容修复..."
      bash /root/fix_browser.sh
      rm -f /root/.refix-browser
      echo "=================================================="
      echo " 安装完成，继续启动面板"
      echo "=================================================="
    fi

    # 重跑修复开关：在 MyWorlds/Ubuntu24/root/ 下新建一个空文件 .refix-browser，
    # 下次开服会自动重跑 fix_browser.sh（幂等），跑完自动删掉标记。
    # 用于：补上 Firefox 后补做冒烟测试、面板升级覆盖补丁后重打。
    if [ -f /root/.refix-browser ]; then
      echo "=================================================="
      echo " 检测到 .refix-browser 标记，重跑 PRoot 兼容修复"
      echo "=================================================="
      bash /root/fix_browser.sh
      rm -f /root/.refix-browser
      echo "✅ 修复完成，标记已清除，继续启动面板"
    fi

    if [ ! -f /root/panel-start.sh ]; then
      echo "[ERROR] proot 内缺少 /root/panel-start.sh"
      echo "解决办法：把修订版 panel-start.sh 上传到翼龙文件管理的 MyWorlds/Ubuntu24/root/panel-start.sh"
      exit 1
    fi
    # 用 bash 显式调用：不依赖可执行位，文件管理上传丢权限也能跑
    bash /root/panel-start.sh
    sleep 3
    PID=$(cat /opt/browser-panel/pids/panel.pid 2>/dev/null || true)
    if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
      echo "[WARN] panel 进程似乎没起来，请检查 /opt/browser-panel/logs/panel.log"
    else
      echo "[OK] panel 运行中 (PID=$PID)，下方为实时日志"
    fi
    echo "--------------------------------------------------"
    tail -F /opt/browser-panel/logs/panel.log
  '
