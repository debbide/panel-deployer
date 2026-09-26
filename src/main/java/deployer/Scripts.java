package deployer;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;

/**
 * 内嵌脚本管理。
 *
 * 脚本直接打进 jar（/scripts/*.sh），拒绝运行时从仓库拉取——
 * 可变分支的脚本会在开服时引入不可预料的故障，jar 与脚本必须是
 * 同一批构建、同一批测试的不可变原子。
 */
public final class Scripts {

    static final String[] NAMES = {
        "start.sh", "panel-start.sh", "install-web.sh",
        "stack.sh", "bp.sh", "fix_browser.sh"
    };

    /**
     * 把内嵌脚本释放到 dir：统一转 LF（根治 CRLF）、加执行位。
     * 返回 dir。
     */
    public static Path extract(Path dir) throws IOException {
        Files.createDirectories(dir);
        for (String name : NAMES) {
            String res = "/scripts/" + name;
            try (InputStream in = Scripts.class.getResourceAsStream(res)) {
                if (in == null) {
                    throw new IOException("jar 内缺脚本: " + res + "（构建时未打入）");
                }
                byte[] raw = in.readAllBytes();
                String text = new String(raw, StandardCharsets.UTF_8)
                    .replace("\r\n", "\n")
                    .replace("\r", "\n");
                Path out = dir.resolve(name);
                Files.writeString(out, text, StandardCharsets.UTF_8);
                if (!out.toFile().setExecutable(true, true)) {
                    throw new IOException("无法加执行位: " + out);
                }
            }
        }
        return dir;
    }

    /** 审计用：把内嵌脚本导出到目录，并打印构建信息。 */
    public static void dump(Path dir) throws IOException {
        extract(dir);
        System.out.println("[deployer] 内嵌脚本已导出到: " + dir.toAbsolutePath());
        System.out.println("[deployer] 脚本列表: " + Arrays.toString(NAMES));
        System.out.println("[deployer] " + BuildInfo.summary());
    }

    private Scripts() {}
}
