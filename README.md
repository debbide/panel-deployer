# panel-deployer

单 jar 闭环部署：在翼龙 / Pelican 这类**启动命令锁死**（只能 `java -jar server.jar`）
的面板环境里，一个 jar 拉起全部东西——

- **browser-panel**：PRoot Ubuntu 24.04 里的浏览器自动化面板
- **webterm**：网页终端（ssh 替代），`127.0.0.1:7681`
- **cloudflared 隧道**：把面板和终端暴露成公网 https 地址

```
java -jar server.jar --nogui
  ├─ panel 主链：/bin/bash start.sh → PRoot → panel-start.sh → browser-panel
  ├─ webterm：二进制按需下载，token 走环境变量
  └─ 隧道：quick 模式两条（面板/终端各一个随机地址）或 named 模式一条
```

## 快速开始

1. 建**私有**仓库，把本项目推上去（公有仓库的 Actions 产物任何人可下载，token 会泄露）。
2. Actions 页点 **Run workflow**，直接填 6 个值（留空则回退到仓库 Secrets）：
   - `cf_tunnel_token`：CF 隧道 token（named 模式才需要）
   - `cf_domain`：CF 隧道域名（如 `panel.example.com`，named 模式展示用）
   - `webterm_token`：webterm 访问 token
   - `webterm_port`：webterm 端口（默认 7681）
   - `vnc_password`：VNC 密码（留空则不启用 noVNC）
   - `vnc_port`：noVNC 网页端口（默认 6080）
   
   注意：填的值会显示在本次 Run 的页面上（仅仓库成员可见），不要截图外发。
   也可以在 Settings → Secrets 里配同名 Secret（`CF_TUNNEL_TOKEN` / `CF_DOMAIN` /
   `WEBTERM_TOKEN` / `WEBTERM_PORT`），输入框留空时自动回退用它——tag 发版时只能走 Secrets。
3. 跑完下载 `server.jar`，传到面板 `/home/container/server.jar`，启动命令保持 `java -jar server.jar --nogui`。
4. 看控制台：quick 隧道的 https 地址会打印出来（named 模式打印配置的域名）。

## 本地构建

```bash
./build.sh                                    # -> dist/server.jar
VERSION=v1.0.0 ./build.sh
CF_TUNNEL_TOKEN=xxx WEBTERM_TOKEN=yyy ./build.sh   # 注入 token（不建议在共享机器上）
```

## 参数

| 参数 | 说明 |
|---|---|
| `--nogui` | 兼容翼龙启动命令（忽略） |
| `--script=/path/x.sh` | 兼容旧行为：直接跑指定脚本 |
| `--scripts-dir=/dir` | 用外部脚本覆盖内嵌脚本（调试用） |
| `--dump-scripts=/dir` | 导出内嵌脚本（审计 jar 里装了什么） |
| `--version` | 打印构建信息 |
| `--no-tunnel` / `--no-webterm` | 跳过对应组件 |

环境变量：`TUNNEL_MODE=quick|named`（默认 quick）。

## token 优先级

环境变量（`CF_TUNNEL_TOKEN` / `CF_DOMAIN` / `WEBTERM_TOKEN` / `WEBTERM_PORT` /
`VNC_PASSWORD` / `VNC_PORT`）
> `/home/container/.secrets/` 下的文件（`cf_tunnel_token`、`cf_domain`、`webterm_token`、
> `webterm_port`、`vnc_password`、`vnc_port`，建议 600）
> 构建时注入（jar 内 `/secrets.properties`）> 缺失则该组件跳过（面板不受影响）

## noVNC 看浏览器画面（可选）

填了 `vnc_password` 就会在 proot 里拉起一条链：
`Xvfb(:1)` → `x11vnc(:1 → 5901)` → `websockify(noVNC 网页 → VNC_PORT)`。
首次开服自动 `apt-get install novnc websockify x11vnc`，之后跳过。

- quick 隧道模式：noVNC 也会分到一条随机 https 隧道，打开 `https://xxx/vnc.html`，
  输入 VNC 密码就能看到浏览器画面；
- named 模式：在 CF 后台给隧道加一条到 `127.0.0.1:VNC_PORT` 的 ingress 规则；
- 密码为空 = 整个 VNC 栈不启动（默认关闭，安全）。

注意：noVNC 网页本身不设登录，靠 VNC 密码鉴权——密码别太简单。

token 绝不出现在：分享出去的脚本、进程命令行（ps）、构建日志。
webterm 在固定 token 模式下不会把 token 打印到日志（它自己的行为）。

## 安全须知

- **jar 文件本人就是秘密**：unzip 就能解出烘焙的 token，只发给信得过的人/机器。
- 轮换 token：改 Secret → 重跑 Actions → 下载新 jar → 上传覆盖。
- 脚本直接打进 jar，**不运行时拉取**：jar 与脚本是同一批构建测试的不可变原子。

## 监督策略（v1）

- panel 主链退出 → 杀其余子进程，透传退出码，整体结束（平台按重启策略重开服）。
- tunnel / webterm 退出 → 打日志，退避重启（5s 起，300s 上限）。
