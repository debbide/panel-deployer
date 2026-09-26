#!/bin/bash
# panel-deployer 一键打包：javac + jar，零依赖。
# 本地和 GitHub Actions 跑同一套。
#
# token/配置注入（只从环境变量来，仓库里永远没有）：
#   CF_TUNNEL_TOKEN   Cloudflare 隧道 token（named 模式用）
#   CF_DOMAIN         Cloudflare 隧道域名（named 模式，面板地址展示用）
#   WEBTERM_TOKEN     webterm 访问 token
#   WEBTERM_PORT      webterm 端口（默认 7681）
#   VNC_PASSWORD      VNC 密码（为空则不启用 noVNC）
#   VNC_PORT          noVNC 网页端口（默认 6080）
# 为空则构建产物里留空（token 运行时走 /home/container/.secrets/ 文件或环境变量兜底）。
#
# 用法：
#   ./build.sh                 本地构建 -> dist/server.jar
#   VERSION=v1.0.0 ./build.sh  指定版本
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-dev}"
BUILD_DIR="build/stage"
DIST="dist"

echo "[build] panel-deployer version=$VERSION"
rm -rf "$BUILD_DIR" "$DIST"
mkdir -p "$BUILD_DIR/classes" "$BUILD_DIR/res" "$DIST"

# 1. 内嵌脚本
mkdir -p "$BUILD_DIR/classes/scripts"
cp scripts/*.sh "$BUILD_DIR/classes/scripts/"
echo "[build] 内嵌脚本: $(ls "$BUILD_DIR/classes/scripts" | tr '\n' ' ')"

# 2. 版本清单（可溯源：哪次构建、哪个 commit、脚本哈希）
{
  echo "build.version=$VERSION"
  echo "build.time=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "git.commit=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
  for f in "$BUILD_DIR/classes/scripts/"*.sh; do
    echo "script.$(basename "$f").sha256=$(sha256sum "$f" | cut -d' ' -f1)"
  done
} > "$BUILD_DIR/res/build-info.properties"

# 3. secrets（只从环境变量注入；反斜杠双写防 Properties 转义吃掉）
# 6 个变量：CF_TUNNEL_TOKEN / CF_DOMAIN / WEBTERM_TOKEN / WEBTERM_PORT / VNC_PASSWORD / VNC_PORT
esc_bs() { printf '%s' "$1" | sed 's/\\/\\\\/g'; }
printf '# 构建时注入。本地构建未设环境变量时留空，运行时走外部文件/环境变量兜底。\n' > "$BUILD_DIR/res/secrets.properties"
printf 'cf.tunnel.token=%s\n' "$(esc_bs "${CF_TUNNEL_TOKEN:-}")" >> "$BUILD_DIR/res/secrets.properties"
printf 'cf.domain=%s\n' "$(esc_bs "${CF_DOMAIN:-}")" >> "$BUILD_DIR/res/secrets.properties"
printf 'webterm.token=%s\n' "$(esc_bs "${WEBTERM_TOKEN:-}")" >> "$BUILD_DIR/res/secrets.properties"
printf 'webterm.port=%s\n' "$(esc_bs "${WEBTERM_PORT:-}")" >> "$BUILD_DIR/res/secrets.properties"
printf 'vnc.password=%s\n' "$(esc_bs "${VNC_PASSWORD:-}")" >> "$BUILD_DIR/res/secrets.properties"
printf 'vnc.port=%s\n' "$(esc_bs "${VNC_PORT:-}")" >> "$BUILD_DIR/res/secrets.properties"
chmod 600 "$BUILD_DIR/res/secrets.properties"
[ -n "${CF_TUNNEL_TOKEN:-}" ] && echo "[build] 已注入 CF 隧道 token" || echo "[build] CF 隧道 token 为空（运行时兜底）"
[ -n "${CF_DOMAIN:-}" ] && echo "[build] 已注入 CF 域名" || echo "[build] CF 域名为空"
[ -n "${WEBTERM_TOKEN:-}" ] && echo "[build] 已注入 webterm token" || echo "[build] webterm token 为空（运行时兜底）"
[ -n "${WEBTERM_PORT:-}" ] && echo "[build] webterm 端口: ${WEBTERM_PORT}" || echo "[build] webterm 端口默认 7681"
[ -n "${VNC_PASSWORD:-}" ] && echo "[build] 已注入 VNC 密码" || echo "[build] VNC 密码为空（不启用 noVNC）"
[ -n "${VNC_PORT:-}" ] && echo "[build] VNC 端口: ${VNC_PORT}" || echo "[build] VNC 端口默认 6080"

# 3b. 混淆 secrets.properties：unzip 直接看是乱码，防随手翻（防君子不防小人；
#     密钥必须与 Secrets.java 里的 OBFUSCATION_KEY 一致；魔术头 PDOB1 用于运行时识别）
python3 - "$BUILD_DIR/res/secrets.properties" <<'EOF'
import sys
path = sys.argv[1]
key = b"PanelDeployer-Obfuscate-v1"  # ← 与 Secrets.java 里的 OBFUSCATION_KEY 必须一致
data = open(path, "rb").read()
obf = bytes(b ^ key[i % len(key)] for i, b in enumerate(data))
open(path, "wb").write(b"PDOB1" + obf)
EOF
echo "[build] secrets.properties 已混淆（魔术头 PDOB1）"

# 4. 编译（--release 17，目标机 Java 25 兼容，老环境也尽量能跑）
mkdir -p "$BUILD_DIR/classes"
javac --release 17 -d "$BUILD_DIR/classes" $(find src -name '*.java')
cp "$BUILD_DIR/res/"*.properties "$BUILD_DIR/classes/"

# 5. 打包
jar --create --file "$DIST/server.jar" --main-class deployer.Main -C "$BUILD_DIR/classes" .
echo "[build] 完成: $DIST/server.jar ($(du -h "$DIST/server.jar" | cut -f1))"
echo "[build] 验证内容:"
unzip -l "$DIST/server.jar" | grep -E 'deployer/|scripts/|properties' | head -20
