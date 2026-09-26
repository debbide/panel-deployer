package deployer;

import java.io.InputStream;
import java.io.StringReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Properties;

/**
 * token 读取。
 *
 * 优先级（明确的本地覆盖构建时默认值）：
 *   1. 环境变量（CF_TUNNEL_TOKEN / CF_DOMAIN / WEBTERM_TOKEN / WEBTERM_PORT /
 *      VNC_PASSWORD / VNC_PORT）
 *   2. 外部文件：/home/container/.secrets/ 下的 cf_tunnel_token、cf_domain、
 *      webterm_token、webterm_port、vnc_password、vnc_port（建议 600）
 *   3. 构建时注入：jar 内的 /secrets.properties（GitHub Secrets → Actions 构建，
 *      构建时已做异或混淆，防 unzip 随手看；不防反编译）
 *
 * 任何 token 都不会出现在：分享出去的脚本、进程命令行参数（ps）、构建日志。
 */
public final class Secrets {

    private static final Path SECRET_DIR = Path.of("/home/container/.secrets");
    private static final Properties BAKED = new Properties();

    /**
     * 混淆密钥：必须与 build.sh 里 python 混淆用的 key 字面量一致。
     * 防 unzip 随手看，不防反编译（密钥就在 class 文件里）。
     */
    private static final byte[] OBFUSCATION_KEY =
        "PanelDeployer-Obfuscate-v1".getBytes(StandardCharsets.UTF_8);
    private static final byte[] MAGIC = "PDOB1".getBytes(StandardCharsets.UTF_8);

    static {
        try (InputStream in = Secrets.class.getResourceAsStream("/secrets.properties")) {
            if (in != null) {
                byte[] raw = in.readAllBytes();
                if (startsWith(raw, MAGIC)) {
                    // 构建时混淆过：去掉魔术头后异或解开
                    byte[] obf = new byte[raw.length - MAGIC.length];
                    System.arraycopy(raw, MAGIC.length, obf, 0, obf.length);
                    for (int i = 0; i < obf.length; i++) {
                        obf[i] ^= OBFUSCATION_KEY[i % OBFUSCATION_KEY.length];
                    }
                    raw = obf;
                }
                // 无魔术头：旧版明文构建的 jar，直接加载（兼容）
                BAKED.load(new StringReader(new String(raw, StandardCharsets.UTF_8)));
            }
        } catch (Exception ignored) {
            // 本地构建未注入时没有，忽略
        }
    }

    private static boolean startsWith(byte[] data, byte[] prefix) {
        if (data.length < prefix.length) {
            return false;
        }
        for (int i = 0; i < prefix.length; i++) {
            if (data[i] != prefix[i]) {
                return false;
            }
        }
        return true;
    }

    /** Cloudflare 隧道 token（named 模式需要；quick 模式不需要）。 */
    public static String cfTunnelToken() {
        return resolve("CF_TUNNEL_TOKEN", "cf_tunnel_token", "cf.tunnel.token");
    }

    /** webterm 访问 token。 */
    public static String webtermToken() {
        return resolve("WEBTERM_TOKEN", "webterm_token", "webterm.token");
    }

    /** CF 隧道域名（named 模式，面板地址展示用）。 */
    public static String cfDomain() {
        return resolve("CF_DOMAIN", "cf_domain", "cf.domain");
    }

    /** webterm 端口，默认 7681。 */
    public static int webtermPort() {
        return parsePort(resolve("WEBTERM_PORT", "webterm_port", "webterm.port"), 7681, "webterm 端口");
    }

    /** VNC 密码。为空 = 不启用 VNC/noVNC。 */
    public static String vncPassword() {
        return resolve("VNC_PASSWORD", "vnc_password", "vnc.password");
    }

    /** noVNC 网页端口，默认 6080。 */
    public static int vncPort() {
        return parsePort(resolve("VNC_PORT", "vnc_port", "vnc.port"), 6080, "VNC 端口");
    }

    private static int parsePort(String v, int def, String label) {
        if (v == null) {
            return def;
        }
        try {
            int p = Integer.parseInt(v.strip());
            if (p >= 1 && p <= 65535) {
                return p;
            }
        } catch (NumberFormatException ignored) {
            // 落到下面的警告
        }
        System.err.println("[deployer] 警告: " + label + "非法 (" + v + ")，用默认 " + def);
        return def;
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
