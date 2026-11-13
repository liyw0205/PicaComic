package com.github.pacalini.pica_comic;

import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpsConfigurator;
import com.sun.net.httpserver.HttpsServer;
import java.io.FileInputStream;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;

public final class NativeCurl {
    private static native boolean availableNative();
    private static native Map<String, Object> fetchNative(
        String method, String url, String proxy, Map<String, String> headers,
        byte[] body, int timeout, int attempts, AtomicBoolean cancelled);

    private static void check(boolean ok, String message) {
        if (!ok) throw new AssertionError(message);
    }

    public static void main(String[] args) throws Exception {
        System.load(args[0]);
        check(availableNative(), "JNI bindings are unavailable");
        var executor = Executors.newCachedThreadPool();
        var http = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        var https = HttpsServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        http.setExecutor(executor);
        https.setExecutor(executor);
        var keyStore = KeyStore.getInstance("PKCS12");
        try (var input = new FileInputStream(args[1])) {
            keyStore.load(input, "changeit".toCharArray());
        }
        var keys = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        keys.init(keyStore, "changeit".toCharArray());
        var tls = SSLContext.getInstance("TLS");
        tls.init(keys.getKeyManagers(), null, null);
        https.setHttpsConfigurator(new HttpsConfigurator(tls));

        var headCalls = new AtomicInteger();
        var postCalls = new AtomicInteger();
        var postBodyValid = new AtomicBoolean();
        var retryCalls = new AtomicInteger();
        var tlsCalls = new AtomicInteger();
        http.createContext("/head", exchange -> {
            headCalls.incrementAndGet();
            exchange.getResponseHeaders().add("Content-Length", "8");
            exchange.sendResponseHeaders(200, -1);
            exchange.close();
        });
        http.createContext("/post", exchange -> {
            postCalls.incrementAndGet();
            boolean bodyMatches = new String(exchange.getRequestBody().readAllBytes(),
                StandardCharsets.UTF_8).equals("payload");
            postBodyValid.set(bodyMatches);
            byte[] response = (bodyMatches ? "ok" : "bad")
                .getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(bodyMatches ? 200 : 400, response.length);
            try (var output = exchange.getResponseBody()) {
                output.write(response);
            }
        });
        http.createContext("/retry", exchange -> {
            int call = retryCalls.incrementAndGet();
            exchange.sendResponseHeaders(call == 1 ? 503 : 200, 1);
            exchange.getResponseBody().write('x');
            exchange.close();
        });
        http.createContext("/stream", exchange -> {
            exchange.sendResponseHeaders(200, 0);
            try {
                for (int i = 0; i < 30; i++) {
                    exchange.getResponseBody().write(new byte[1024]);
                    exchange.getResponseBody().flush();
                    Thread.sleep(100);
                }
            } catch (IOException expectedOnCancel) {
                // The client closed the connection after cancellation.
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
            } finally {
                exchange.close();
            }
        });
        https.createContext("/", exchange -> {
            tlsCalls.incrementAndGet();
            exchange.sendResponseHeaders(200, -1);
            exchange.close();
        });
        http.start();
        https.start();
        String base = "http://127.0.0.1:" + http.getAddress().getPort();
        try {
            var head = fetchNative("HEAD", base + "/head", null, Map.of(),
                null, 3000, 3, new AtomicBoolean());
            check((int) head.get("curlCode") == 0, "HEAD failed: " + head);
            check(((byte[]) head.get("body")).length == 0, "HEAD read a body");
            check(headCalls.get() == 1, "HEAD was retried unnecessarily");

            var post = fetchNative("POST", base + "/post", null, Map.of(),
                "payload".getBytes(StandardCharsets.UTF_8), 3000, 3, new AtomicBoolean());
            check(postCalls.get() == 1 && (int) post.get("attempts") == 1
                    && postBodyValid.get() && (int) post.get("curlCode") == 0
                    && (int) post.get("statusCode") == 200
                    && new String((byte[]) post.get("body"), StandardCharsets.UTF_8)
                        .equals("ok"),
                "POST body or response was invalid, or request was replayed: " + post);

            var retry = fetchNative("GET", base + "/retry", null, Map.of(),
                null, 3000, 3, new AtomicBoolean());
            check(retryCalls.get() == 2 && (int) retry.get("statusCode") == 200,
                "Transient GET did not recover: " + retry);

            var rejected = fetchNative("GET", "https://127.0.0.1:"
                + https.getAddress().getPort(), null, Map.of(), null,
                3000, 3, new AtomicBoolean());
            check((int) rejected.get("curlCode") != 0 && tlsCalls.get() == 0,
                "Untrusted certificate was accepted: " + rejected);
            check((int) rejected.get("attempts") == 1,
                "Certificate error was retried: " + rejected);

            var preCancelled = fetchNative("GET", base + "/head", null, Map.of(),
                null, 3000, 3, new AtomicBoolean(true));
            check((int) preCancelled.get("curlCode") == 42 && headCalls.get() == 1,
                "Pre-cancelled request reached the server");

            var cancel = new AtomicBoolean();
            var cancelling = new Thread(() -> {
                try { Thread.sleep(150); } catch (InterruptedException ignored) {}
                cancel.set(true);
            });
            cancelling.start();
            var stopped = fetchNative("GET", base + "/stream", null, Map.of(),
                null, 3000, 3, cancel);
            cancelling.join();
            check((int) stopped.get("curlCode") == 42
                && (int) stopped.get("attempts") == 1,
                "Transfer continued or retried after cancellation: " + stopped);
            System.out.println("Native curl: 6 regression checks passed");
        } finally {
            http.stop(0);
            https.stop(0);
            executor.shutdownNow();
        }
    }
}
