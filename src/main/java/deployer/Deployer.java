package deployer;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;

/**
 * 编排与监督。
 *
 * 流程：
 *   1. 脚本来源：--scripts-dir 外部目录，或释放 jar 内嵌脚本（转 LF + 加执行位）
 *   2. 起 panel 主链：/bin/bash start.sh
 *      （沿用已验证的脚本：proot 安装→面板四件套安装→panel-start.sh→tail -F 挂前台；
 *       VNC 密码/端口经环境变量透传进 proot）
 *   3. 起 webterm（ssh 终端）：127.0.0.1:webterm 端口，token 走环境变量（不进 ps、不进日志）
 *   4. 起 VNC（可选）：proot 内 x11vnc + noVNC，有 VNC 密码才启用
 *   5. 起隧道：TUNNEL_MODE 显式优先；未设置时有 CF token 自动 named（固定隧道），
 *      否则 quick（临时隧道，每条服务一个随机 https 地址）；
 *      named 下 token 走 TUNNEL_TOKEN 环境变量（ps 不可见），
 *      路由（哪个域名→哪个端口）由 Cloudflare 后台的隧道配置决定。
 *
 * 监督策略（v1）：
 *   - panel 主链退出 → 杀掉其余子进程，透传退出码，整体结束
 *     （平台侧看到容器退出，可按重启策略重开服）
 *   - tunnel / webterm 退出 → 打日志，退避重启（5s→10s→…→300s 上限）
 */
public class Deployer {

    private final Map<String, String> opts;

    public Deployer(Map<String, String> opts) {
        this.opts = opts;
    }

    /** 隧道模式：显式的 TUNNEL_MODE 环境变量优先；
     *  未设置时，有 CF 隧道 token 就自动用 named（固定隧道），否则 quick（临时隧道），
     *  免得配了 token 还要再手动设环境变量。 */
    static String tunnelMode() {
        String mode = System.getenv("TUNNEL_MODE");
        if (mode == null || mode.isBlank()) {
            mode = Secrets.cfTunnelToken() != null ? "named" : "quick";
        }
        return mode.strip().toLowerCase();
    }

    public int run() throws Exception {
        System.out.println("[deployer] panel-deployer " + BuildInfo.summary());

        // 兼容旧 jar 行为：--script= 直接跑指定脚本
        if (opts.containsKey("script")) {
            Path script = Path.of(opts.get("script"));
            System.out.println("[deployer] 兼容模式拉起: /bin/bash " + script);
            return new ProcessBuilder("/bin/bash", script.toString())
                .inheritIO().start().waitFor();
        }

        // 1. 脚本来源
        Path scriptsDir;
        if (opts.containsKey("scripts-dir")) {
            scriptsDir = Path.of(opts.get("scripts-dir"));
            System.out.println("[deployer] 使用外部脚本目录: " + scriptsDir);
        } else {
            scriptsDir = Scripts.extract(Files.createTempDirectory("panel-deployer-scripts"));
            System.out.println("[deployer] 已释放内嵌脚本: " + scriptsDir);
        }
        Path startSh = scriptsDir.resolve("start.sh");
        if (!Files.isExecutable(startSh)) {
            System.err.println("[deployer] 错误: 找不到可执行的 start.sh: " + startSh);
            return 2;
        }

        boolean wantWebterm = !opts.containsKey("no-webterm");
        boolean wantTunnel = !opts.containsKey("no-tunnel");

        Supervisor sup = new Supervisor();

        // 2. panel 主链（VNC 配置经环境变量透传进 proot）
        java.util.Map<String, String> panelEnv = new java.util.HashMap<>();
        panelEnv.put("VNC_PORT", String.valueOf(Secrets.vncPort()));
        String vncPass = Secrets.vncPassword();
        if (vncPass != null) {
            panelEnv.put("VNC_PASSWORD", vncPass);
            System.out.println("[deployer] VNC/noVNC 已启用（端口 " + Secrets.vncPort() + "）");
        } else {
            System.out.println("[deployer] 未配置 VNC 密码，跳过 VNC/noVNC");
        }
        sup.spawn("panel", true, List.of("/bin/bash", startSh.toString()), panelEnv);

        // 3. webterm
        if (wantWebterm) {
            String token = Secrets.webtermToken();
            if (token == null) {
                System.out.println("[deployer] 未配置 webterm token，跳过 webterm（面板照常跑）");
                wantWebterm = false;
            } else {
                Path wt = Binaries.webterm();
                int port = Secrets.webtermPort();
                sup.spawn("webterm", false,
                    List.of(wt.toString()),
                    Map.of("WEBTERM_PORT", String.valueOf(port),
                           "WEBTERM_ACCESS_TOKEN", token));
            }
        }

        // 4. 隧道
        if (wantTunnel) {
            String mode = tunnelMode();
            System.out.println("[deployer] 隧道模式: " + mode
                + ("named".equals(mode) ? "（固定隧道）" : "（临时隧道）"));
            Path cf = Binaries.cloudflared();
            if ("named".equals(mode)) {
                String token = Secrets.cfTunnelToken();
                if (token == null) {
                    System.out.println("[deployer] named 模式需要 CF 隧道 token，未配置则跳过隧道");
                } else {
                    // token 走环境变量，不进 ps
                    sup.spawn("tunnel", false,
                        List.of(cf.toString(), "tunnel", "--no-autoupdate", "run"),
                        Map.of("TUNNEL_TOKEN", token));
                }
            } else {
                // quick：quick 隧道，各一个随机 https 地址，日志里会打印
                sup.spawn("tunnel-panel", false,
                    List.of(cf.toString(), "tunnel", "--no-autoupdate",
                            "--url", "http://127.0.0.1:3210"),
                    Map.of());
                if (wantWebterm) {
                    sup.spawn("tunnel-webterm", false,
                        List.of(cf.toString(), "tunnel", "--no-autoupdate",
                                "--url", "http://127.0.0.1:" + Secrets.webtermPort()),
                        Map.of());
                }
                if (Secrets.vncPassword() != null) {
                    sup.spawn("tunnel-novnc", false,
                        List.of(cf.toString(), "tunnel", "--no-autoupdate",
                                "--url", "http://127.0.0.1:" + Secrets.vncPort()),
                        Map.of());
                }
            }
        }

        return sup.watch();
    }

    /** 简单监督器。 */
    static class Supervisor {

        record Child(String name, boolean main, List<String> cmd,
                     Map<String, String> env, Process proc) {}

        private final List<Child> children = new ArrayList<>();
        private final BlockingQueue<Child> dead = new LinkedBlockingQueue<>();

        void spawn(String name, boolean main, List<String> cmd, Map<String, String> env) {
            try {
                ProcessBuilder pb = new ProcessBuilder(cmd).inheritIO();
                pb.environment().putAll(env);
                Process p = pb.start();
                Child c = new Child(name, main, List.copyOf(cmd), Map.copyOf(env), p);
                children.add(c);
                System.out.println("[deployer] 已启动 [" + name + "] pid=" + p.pid());
                Thread t = new Thread(() -> {
                    try {
                        p.waitFor();
                    } catch (InterruptedException ignored) {
                        Thread.currentThread().interrupt();
                    }
                    dead.offer(c);
                }, "watch-" + name);
                t.setDaemon(true);
                t.start();
            } catch (IOException e) {
                throw new RuntimeException("启动失败 [" + name + "]: " + e.getMessage(), e);
            }
        }

        int watch() throws InterruptedException {
            int backoff = 5;
            while (true) {
                Child c = dead.take();
                int code = c.proc.exitValue();
                System.out.println("[deployer] [" + c.name + "] 退出 code=" + code);
                if (c.main) {
                    System.out.println("[deployer] 主链退出，清理其余进程并结束");
                    killAll();
                    return code;
                }
                System.out.println("[deployer] [" + c.name + "] " + backoff + "s 后重启");
                Thread.sleep(backoff * 1000L);
                backoff = Math.min(backoff * 2, 300);
                children.remove(c);
                spawn(c.name, false, c.cmd, c.env);
            }
        }

        void killAll() {
            for (Child c : children) {
                c.proc.destroy();
            }
        }
    }
}
