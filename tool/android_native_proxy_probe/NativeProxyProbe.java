import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Authenticator;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.PasswordAuthentication;
import java.net.Proxy;
import java.net.URI;
import java.net.Socket;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Base64;
import java.util.List;
import javax.net.ssl.SNIHostName;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;

@SuppressWarnings("deprecation")
public final class NativeProxyProbe {
    private static final int TIMEOUT_MS = 8000;
    private static final String[] DEFAULT_URLS = {
            "https://www.gstatic.com/generate_204",
            "https://example.com/",
            "https://e-hentai.org/",
            "https://nhentai.net/",
            "https://hitomi.la/"
    };

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            System.err.println("Usage: NativeProxyProbe <proxy> [url ...]");
            System.exit(2);
        }

        ProbeProxy proxy = ProbeProxy.parse(args[0]);
        if (!"http".equals(proxy.scheme)) {
            throw new IllegalArgumentException("Only http proxy is supported by this native probe");
        }

        if (proxy.username != null) {
            Authenticator.setDefault(new Authenticator() {
                @Override
                protected PasswordAuthentication getPasswordAuthentication() {
                    if (getRequestorType() == RequestorType.PROXY) {
                        return new PasswordAuthentication(
                                proxy.username,
                                proxy.password == null ? new char[0] : proxy.password.toCharArray());
                    }
                    return null;
                }
            });
        }

        System.out.println("proxy=" + proxy.masked());
        List<String> urls = new ArrayList<>();
        if (args.length == 1) {
            for (String url : DEFAULT_URLS) urls.add(url);
        } else {
            for (int i = 1; i < args.length; i++) urls.add(args[i]);
        }

        Proxy javaProxy = new Proxy(Proxy.Type.HTTP, new InetSocketAddress(proxy.host, proxy.port));
        for (String url : urls) {
            if (url.startsWith("https://")) {
                probeHttpsTunnel(proxy, url);
            } else {
                probeHttpUrlConnection(javaProxy, proxy, url);
            }
        }
        System.exit(0);
    }

    private static void probeHttpUrlConnection(Proxy javaProxy, ProbeProxy proxy, String urlText) {
        long start = System.nanoTime();
        HttpURLConnection connection = null;
        try {
            URL url = new URL(urlText);
            connection = (HttpURLConnection) url.openConnection(javaProxy);
            connection.setConnectTimeout(TIMEOUT_MS);
            connection.setReadTimeout(TIMEOUT_MS);
            connection.setInstanceFollowRedirects(false);
            connection.setUseCaches(false);
            connection.setRequestMethod("GET");
            connection.setRequestProperty("User-Agent",
                    "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 "
                            + "(KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36");
            connection.setRequestProperty("Accept", "*/*");
            connection.setRequestProperty("Connection", "close");
            if (proxy.username != null) {
                String raw = proxy.username + ":" + (proxy.password == null ? "" : proxy.password);
                String token = Base64.getEncoder().encodeToString(raw.getBytes(StandardCharsets.UTF_8));
                connection.setRequestProperty("Proxy-Authorization", "Basic " + token);
            }

            int code = connection.getResponseCode();
            InputStream stream = code >= 400 ? connection.getErrorStream() : connection.getInputStream();
            int bytes = readSome(stream);
            long elapsedMs = (System.nanoTime() - start) / 1000000L;
            System.out.println(label(urlText) + " OK status=" + code + " bytes=" + bytes + " time=" + elapsedMs + "ms");
        } catch (Throwable e) {
            long elapsedMs = (System.nanoTime() - start) / 1000000L;
            System.out.println(label(urlText) + " ERR time=" + elapsedMs + "ms error="
                    + e.getClass().getSimpleName() + ": " + String.valueOf(e.getMessage()));
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private static void probeHttpsTunnel(ProbeProxy proxy, String urlText) {
        long start = System.nanoTime();
        Socket rawSocket = null;
        SSLSocket tlsSocket = null;
        String stage = "connect-proxy";
        try {
            URL url = new URL(urlText);
            int port = url.getPort() > 0 ? url.getPort() : 443;
            rawSocket = new Socket();
            rawSocket.connect(new InetSocketAddress(proxy.host, proxy.port), TIMEOUT_MS);
            rawSocket.setSoTimeout(TIMEOUT_MS);

            stage = "http-connect";
            OutputStream rawOut = rawSocket.getOutputStream();
            rawOut.write(connectRequest(proxy, url.getHost(), port).getBytes(StandardCharsets.ISO_8859_1));
            rawOut.flush();

            String connectHeaders = readHeaders(rawSocket.getInputStream());
            String connectLine = firstLine(connectHeaders);
            if (!connectLine.contains(" 200 ")) {
                throw new IllegalStateException("CONNECT failed: " + connectLine);
            }

            stage = "tls";
            tlsSocket = (SSLSocket) ((SSLSocketFactory) SSLSocketFactory.getDefault())
                    .createSocket(rawSocket, url.getHost(), port, true);
            SSLParameters parameters = tlsSocket.getSSLParameters();
            parameters.setEndpointIdentificationAlgorithm("HTTPS");
            parameters.setServerNames(Collections.singletonList(new SNIHostName(url.getHost())));
            tlsSocket.setSSLParameters(parameters);
            tlsSocket.setSoTimeout(TIMEOUT_MS);
            tlsSocket.startHandshake();

            stage = "http-get";
            String path = url.getFile() == null || url.getFile().isEmpty() ? "/" : url.getFile();
            OutputStream tlsOut = tlsSocket.getOutputStream();
            tlsOut.write(("GET " + path + " HTTP/1.1\r\n"
                    + "Host: " + url.getHost() + "\r\n"
                    + "User-Agent: Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 "
                    + "(KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36\r\n"
                    + "Accept: */*\r\n"
                    + "Connection: close\r\n"
                    + "\r\n").getBytes(StandardCharsets.ISO_8859_1));
            tlsOut.flush();

            String responseHeaders = readHeaders(tlsSocket.getInputStream());
            int status = parseStatus(firstLine(responseHeaders));
            long elapsedMs = (System.nanoTime() - start) / 1000000L;
            System.out.println(label(urlText) + " OK status=" + status + " time=" + elapsedMs + "ms");
        } catch (Throwable e) {
            long elapsedMs = (System.nanoTime() - start) / 1000000L;
            System.out.println(label(urlText) + " ERR stage=" + stage + " time=" + elapsedMs + "ms error="
                    + e.getClass().getSimpleName() + ": " + String.valueOf(e.getMessage()));
        } finally {
            closeQuietly(tlsSocket);
            closeQuietly(rawSocket);
        }
    }

    private static String connectRequest(ProbeProxy proxy, String host, int port) {
        StringBuilder request = new StringBuilder();
        request.append("CONNECT ").append(host).append(":").append(port).append(" HTTP/1.1\r\n");
        request.append("Host: ").append(host).append(":").append(port).append("\r\n");
        request.append("Proxy-Connection: Keep-Alive\r\n");
        request.append("User-Agent: Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36\r\n");
        if (proxy.username != null) {
            String raw = proxy.username + ":" + (proxy.password == null ? "" : proxy.password);
            String token = Base64.getEncoder().encodeToString(raw.getBytes(StandardCharsets.UTF_8));
            request.append("Proxy-Authorization: Basic ").append(token).append("\r\n");
        }
        request.append("\r\n");
        return request.toString();
    }

    private static String readHeaders(InputStream input) throws Exception {
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        int previous3 = -1;
        int previous2 = -1;
        int previous1 = -1;
        int current;
        while ((current = input.read()) != -1) {
            buffer.write(current);
            if (previous3 == '\r' && previous2 == '\n' && previous1 == '\r' && current == '\n') {
                break;
            }
            if (buffer.size() > 16384) {
                throw new IllegalStateException("headers too large");
            }
            previous3 = previous2;
            previous2 = previous1;
            previous1 = current;
        }
        return buffer.toString("ISO-8859-1");
    }

    private static String firstLine(String headers) {
        int end = headers.indexOf("\r\n");
        return end < 0 ? headers : headers.substring(0, end);
    }

    private static int parseStatus(String statusLine) {
        String[] parts = statusLine.split(" ");
        if (parts.length >= 2) {
            try {
                return Integer.parseInt(parts[1]);
            } catch (NumberFormatException ignored) {
            }
        }
        return -1;
    }

    private static void closeQuietly(Socket socket) {
        if (socket == null) return;
        try {
            socket.close();
        } catch (Exception ignored) {
        }
    }

    private static int readSome(InputStream stream) throws Exception {
        if (stream == null) return 0;
        try (BufferedInputStream input = new BufferedInputStream(stream)) {
            byte[] buffer = new byte[512];
            int total = 0;
            while (total < 1024) {
                int read = input.read(buffer, 0, Math.min(buffer.length, 1024 - total));
                if (read <= 0) break;
                total += read;
                if (total > 0) break;
            }
            return total;
        }
    }

    private static String label(String urlText) {
        try {
            return new URL(urlText).getHost();
        } catch (Exception e) {
            return urlText;
        }
    }

    private static final class ProbeProxy {
        final String scheme;
        final String host;
        final int port;
        final String username;
        final String password;

        private ProbeProxy(String scheme, String host, int port, String username, String password) {
            this.scheme = scheme;
            this.host = host;
            this.port = port;
            this.username = username;
            this.password = password;
        }

        static ProbeProxy parse(String text) throws Exception {
            URI uri = URI.create(text.contains("://") ? text : "http://" + text);
            String userInfo = uri.getUserInfo();
            String username = null;
            String password = null;
            if (userInfo != null) {
                int index = userInfo.indexOf(':');
                if (index < 0) {
                    username = userInfo;
                } else {
                    username = userInfo.substring(0, index);
                    password = userInfo.substring(index + 1);
                }
            }
            return new ProbeProxy(
                    uri.getScheme() == null ? "http" : uri.getScheme(),
                    uri.getHost(),
                    uri.getPort(),
                    username,
                    password);
        }

        String masked() {
            String auth = username == null ? "" : username + ":***@";
            return scheme + "://" + auth + host + ":" + port;
        }
    }
}
