#include <curl/curl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *default_urls[] = {
    "https://www.gstatic.com/generate_204",
    "https://example.com/",
    "https://e-hentai.org/",
    "https://nhentai.net/",
    "https://hitomi.la/",
};

static size_t discard_body(char *ptr, size_t size, size_t nmemb, void *userdata) {
    (void)ptr;
    (void)userdata;
    return size * nmemb;
}

static void print_time(const char *name, curl_off_t us) {
    if (us < 0) {
        printf(" %s=-", name);
    } else {
        printf(" %s=%.3fs", name, (double)us / 1000000.0);
    }
}

struct ProbeResult {
    CURLcode code;
    long status;
    curl_off_t connect_us;
    curl_off_t tls_us;
    curl_off_t first_byte_us;
    curl_off_t total_us;
    char primary_ip[128];
};

static struct ProbeResult probe_once(const char *proxy, const char *url) {
    struct ProbeResult result;
    memset(&result, 0, sizeof(result));
    result.connect_us = -1;
    result.tls_us = -1;
    result.first_byte_us = -1;
    result.total_us = -1;

    CURL *curl = curl_easy_init();
    if (curl == NULL) {
        result.code = CURLE_FAILED_INIT;
        return result;
    }

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_PROXY, proxy);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 2L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, 6000L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, 20000L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, discard_body);
    curl_easy_setopt(curl, CURLOPT_USERAGENT,
                     "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 "
                     "(KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36");
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, NULL);

    char *primary_ip = NULL;

    result.code = curl_easy_perform(curl);
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &result.status);
    curl_easy_getinfo(curl, CURLINFO_CONNECT_TIME_T, &result.connect_us);
    curl_easy_getinfo(curl, CURLINFO_APPCONNECT_TIME_T, &result.tls_us);
    curl_easy_getinfo(curl, CURLINFO_STARTTRANSFER_TIME_T, &result.first_byte_us);
    curl_easy_getinfo(curl, CURLINFO_TOTAL_TIME_T, &result.total_us);
    curl_easy_getinfo(curl, CURLINFO_PRIMARY_IP, &primary_ip);
    if (primary_ip != NULL) {
        snprintf(result.primary_ip, sizeof(result.primary_ip), "%s", primary_ip);
    }

    curl_easy_cleanup(curl);
    return result;
}

static int is_success(struct ProbeResult result) {
    return result.code == CURLE_OK && result.status >= 200 && result.status < 500;
}

static void probe(const char *proxy, const char *url, int attempts) {
    struct ProbeResult result;
    memset(&result, 0, sizeof(result));

    int used_attempts = 0;
    for (int i = 0; i < attempts; i++) {
        result = probe_once(proxy, url);
        used_attempts = i + 1;
        if (is_success(result)) {
            break;
        }
    }

    if (is_success(result)) {
        printf("%-18s OK   code=%ld attempts=%d", url, result.status, used_attempts);
    } else {
        printf("%-18s FAIL code=%ld attempts=%d err=%s",
               url, result.status, used_attempts, curl_easy_strerror(result.code));
    }
    print_time("connect", result.connect_us);
    print_time("tls", result.tls_us);
    print_time("first_byte", result.first_byte_us);
    print_time("total", result.total_us);
    if (result.primary_ip[0] != '\0') {
        printf(" remote=%s", result.primary_ip);
    }
    printf("\n");
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <proxy> [url ...]\n", argv[0]);
        return 2;
    }

    CURLcode init = curl_global_init(CURL_GLOBAL_DEFAULT);
    if (init != CURLE_OK) {
        fprintf(stderr, "curl_global_init failed: %s\n", curl_easy_strerror(init));
        return 1;
    }

    int attempts = 3;
    const char *env_attempts = getenv("CURL_PROBE_ATTEMPTS");
    if (env_attempts != NULL && env_attempts[0] != '\0') {
        int parsed = atoi(env_attempts);
        if (parsed > 0 && parsed < 20) {
            attempts = parsed;
        }
    }

    printf("libcurl=%s\n", curl_version());
    printf("attempts=%d\n", attempts);
    if (argc == 2) {
        size_t count = sizeof(default_urls) / sizeof(default_urls[0]);
        for (size_t i = 0; i < count; i++) {
            probe(argv[1], default_urls[i], attempts);
        }
    } else {
        for (int i = 2; i < argc; i++) {
            probe(argv[1], argv[i], attempts);
        }
    }

    curl_global_cleanup();
    return 0;
}
