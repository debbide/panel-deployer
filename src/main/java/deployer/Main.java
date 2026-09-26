package deployer;

import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * panel-deployer 入口：单 jar 闭环部署
 * （browser-panel + webterm + cloudflared 隧道，全部由这一个 jar 拉起和监督）。
 *
 * 兼容翼龙/ Pelican 启动命令：java -jar server.jar --nogui
 * 未知参数一律忽略，只有下面列出的显式参数才生效。
 */
public class Main {

    static final String HELP =
        "panel-deployer: 单 jar 闭环部署（browser-panel + webterm + cloudflared 隧道）\n" +
        "用法: java -jar server.jar [选项]\n" +
        "  --nogui                兼容翼龙启动命令（忽略）\n" +
        "  --script=/path/x.sh    兼容旧行为：直接跑指定脚本，不走内部流程\n" +
        "  --scripts-dir=/dir     用外部脚本目录覆盖内嵌脚本（调试新脚本用）\n" +
        "  --dump-scripts=/dir    把内嵌脚本导出到目录（审计 jar 里到底装了什么）\n" +
        "  --version              打印构建信息（版本/commit/脚本哈希）\n" +
        "  --no-tunnel            不启动隧道\n" +
        "  --no-webterm           不启动 webterm\n" +
        "环境变量:\n" +
        "  TUNNEL_MODE=quick|named  隧道模式（默认 quick；named 需要 token）\n" +
        "token 优先级: 环境变量 > /home/container/.secrets/ 文件 > 构建时注入\n";

    public static void main(String[] args) throws Exception {
        Map<String, String> opts = new LinkedHashMap<>();
        for (String a : args) {
            if (!a.startsWith("--")) {
                continue; // 忽略 --nogui 等非 -- 开头的参数
            }
            int eq = a.indexOf('=');
            if (eq > 0) {
                opts.put(a.substring(2, eq), a.substring(eq + 1));
            } else {
                opts.put(a.substring(2), "true");
            }
        }

        if (opts.containsKey("h") || opts.containsKey("help")) {
            System.out.println(HELP);
            return;
        }
        if (opts.containsKey("version")) {
            System.out.println("[deployer] " + BuildInfo.summary());
            return;
        }
        if (opts.containsKey("dump-scripts")) {
            Scripts.dump(Path.of(opts.get("dump-scripts")));
            return;
        }

        int code = new Deployer(opts).run();
        System.exit(code);
    }
}
