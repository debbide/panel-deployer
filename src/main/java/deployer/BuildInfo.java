package deployer;

import java.io.InputStream;
import java.util.Properties;

/** 构建信息：build.sh 生成，jar 里可溯源（版本/commit/脚本哈希）。 */
public final class BuildInfo {

    private static final Properties P = new Properties();

    static {
        try (InputStream in = BuildInfo.class.getResourceAsStream("/build-info.properties")) {
            if (in != null) {
                P.load(in);
            }
        } catch (Exception ignored) {
            // 本地直接 javac 调试时可能没有，忽略
        }
    }

    public static String summary() {
        return "version=" + P.getProperty("build.version", "?")
            + " commit=" + P.getProperty("git.commit", "?")
            + " time=" + P.getProperty("build.time", "?");
    }

    private BuildInfo() {}
}
