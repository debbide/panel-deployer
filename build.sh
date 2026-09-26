#!/bin/bash
# panel-deployer 一键打包：javac + jar，零依赖。
# 本地和 GitHub Actions 跑同一套。
#
# token 注入（只从环境变量来，仓库里永远没有）：
#   CF_TUNNEL_TOKEN   Cloudflare 隧道 token（named 模式用）
#   WEBTERM_TOKEN     webterm 访问 token
# 为空则构建产物里留空，运行时走 /home/container/.secrets/ 文件或环境变量兜底。
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
esc_bs() { printf '%s' "$1" | sed 's/\\/\\\\/g'; }
printf '# 构建时注入。本地构建未设环境变量时留空，运行时走外部文件/环境变量兜底。\n' > "$BUILD_DIR/res/secrets.properties"
printf 'cf.tunnel.token=%s\n' "$(esc_bs "${CF_TUNNEL_TOKEN:-}")" >> "$BUILD_DIR/res/secrets.properties"
printf 'webterm.token=%s\n' "$(esc_bs "${WEBTERM_TOKEN:-}")" >> "$BUILD_DIR/res/secrets.properties"
chmod 600 "$BUILD_DIR/res/secrets.properties"
if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then echo "[build] 已注入 CF 隧道 token"; else echo "[build] CF 隧道 token 为空（运行时兜底）"; fi
if [ -n "${WEBTERM_TOKEN:-}" ]; then echo "[build] 已注入 webterm token"; else echo "[build] webterm token 为空（运行时兜底）"; fi

# 4. 编译（--release 17，目标机 Java 25 兼容，老环境也尽量能跑）
mkdir -p "$BUILD_DIR/classes"
javac --release 17 -d "$BUILD_DIR/classes" $(find src -name '*.java')
cp "$BUILD_DIR/res/"*.properties "$BUILD_DIR/classes/"

# 5. 打包
jar --create --file "$DIST/server.jar" --main-class deployer.Main -C "$BUILD_DIR/classes" .
echo "[build] 完成: $DIST/server.jar ($(du -h "$DIST/server.jar" | cut -f1))"
echo "[build] 验证内容:"
unzip -l "$DIST/server.jar" | grep -E 'deployer/|scripts/|properties' | head -20
