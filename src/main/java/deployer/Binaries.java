package deployer;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.time.Duration;

/**
 * 第三方二进制按需下载到 ~/.cache/panel-deployer/bin（不存在才下）。
 * 版本通过环境变量 pin，默认 latest（可在 Binaries 里改成固定版本）。
 */
public final class Binaries {

    static final Path BIN_DIR = Path.of(
        System.getProperty("user.home"), ".cache", "panel-deployer", "bin");

    private static String env(String key, String def) {
        String v = System.getenv(key);
        return (v == null || v.isBlank()) ? def : v.strip();
    }

    /** cloudflared 下载地址（amd64）。 */
    static String cloudflaredUrl() {
        String ver = env("CLOUDFLARED_VERSION", "latest");
        String base = "https://github.com/cloudflare/cloudflared/releases/"
            + ("latest".equals(ver) ? "latest/download" : "download/" + ver);
        return base + "/cloudflared-linux-amd64";
    }

    /** webterm（TermDock）下载地址（amd64）。 */
    static String webtermUrl() {
        String ver = env("WEBTERM_VERSION", "latest");
        String base = "https://github.com/debbide/termdock/releases/"
            + ("latest".equals(ver) ? "latest/download" : "download/" + ver);
        return base + "/webterm-linux-amd64";
    }

    public static Path cloudflared() throws Exception {
        return fetch("cloudflared", cloudflaredUrl());
    }

    public static Path webterm() throws Exception {
        return fetch("webterm", webtermUrl());
    }

    static Path fetch(String name, String url) throws Exception {
        Files.createDirectories(BIN_DIR);
        Path out = BIN_DIR.resolve(name);
        if (Files.isExecutable(out)) {
            System.out.println("[deployer] 二进制已存在，跳过下载: " + out);
            return out;
        }
        System.out.println("[deployer] 下载 " + name + " <- " + url);
        Path tmp = out.resolveSibling(name + ".tmp");
        HttpClient hc = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(20))
            .followRedirects(HttpClient.Redirect.ALWAYS)
            .build();
        HttpRequest req = HttpRequest.newBuilder(URI.create(url))
            .timeout(Duration.ofMinutes(10))
            .GET()
            .build();
        HttpResponse<Path> resp = hc.send(req, HttpResponse.BodyHandlers.ofFile(tmp));
        if (resp.statusCode() != 200) {
            Files.deleteIfExists(tmp);
            throw new IOException("下载失败 HTTP " + resp.statusCode() + ": " + url);
        }
        Files.move(tmp, out, StandardCopyOption.REPLACE_EXISTING);
        if (!out.toFile().setExecutable(true, true)) {
            throw new IOException("无法加执行位: " + out);
        }
        System.out.println("[deployer] 下载完成: " + out);
        return out;
    }

    private Binaries() {}
}
