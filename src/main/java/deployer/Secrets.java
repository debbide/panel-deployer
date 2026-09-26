package deployer;

import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Properties;

/**
 * token 读取。
 *
 * 优先级（明确的本地覆盖构建时默认值）：
 *   1. 环境变量（CF_TUNNEL_TOKEN / WEBTERM_TOKEN）
 *   2. 外部文件：/home/container/.secrets/cf_tunnel_token、webterm_token（建议 600）
 *   3. 构建时注入：jar 内的 /secrets.properties（GitHub Secrets → Actions 构建）
 *
 * 任何 token 都不会出现在：分享出去的脚本、进程命令行参数（ps）、构建日志。
 */
public final class Secrets {

    private static final Path SECRET_DIR = Path.of("/home/container/.secrets");
    private static final Properties BAKED = new Properties();

    static {
        try (InputStream in = Secrets.class.getResourceAsStream("/secrets.properties")) {
            if (in != null) {
                BAKED.load(in);
            }
        } catch (Exception ignored) {
            // 本地构建未注入时没有，忽略
        }
    }

    /** Cloudflare 隧道 token（named 模式需要；quick 模式不需要）。 */
    public static String cfTunnelToken() {
        return resolve("CF_TUNNEL_TOKEN", "cf_tunnel_token", "cf.tunnel.token");
    }

    /** webterm 访问 token。 */
    public static String webtermToken() {
        return resolve("WEBTERM_TOKEN", "webterm_token", "webterm.token");
    }

    private static String resolve(String envName, String fileName, String bakedKey) {
        String v = System.getenv(envName);
        if (v != null && !v.isBlank()) {
            return v;
        }
        try {
            Path p = SECRET_DIR.resolve(fileName);
            if (Files.isRegularFile(p)) {
                v = Files.readString(p).strip();
                if (!v.isBlank()) {
                    return v;
                }
            }
        } catch (Exception ignored) {
            // 读不到就往下走
        }
        v = BAKED.getProperty(bakedKey, "").strip();
        return v.isEmpty() ? null : v;
    }

    private Secrets() {}
}
