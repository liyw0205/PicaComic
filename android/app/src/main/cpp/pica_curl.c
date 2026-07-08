#include <jni.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>

#ifdef PICA_USE_LIBCURL
#include <curl/curl.h>
#include <stdlib.h>
#endif

#ifdef PICA_USE_LIBCURL

typedef struct {
    char *data;
    size_t length;
    size_t capacity;
} Buffer;

typedef struct {
    char **items;
    size_t count;
    size_t capacity;
} HeaderList;

typedef struct {
    JNIEnv *env;
    jobject map;
    jclass array_list_class;
    jmethodID array_list_init;
    jmethodID array_list_add;
    jmethodID map_put;
} HeaderMapContext;

static void buffer_free(Buffer *buffer) {
    if (buffer->data != NULL) {
        free(buffer->data);
    }
    buffer->data = NULL;
    buffer->length = 0;
    buffer->capacity = 0;
}

static int buffer_append(Buffer *buffer, const char *data, size_t length) {
    if (length == 0) return 1;
    if (buffer->length + length > 16 * 1024 * 1024) return 0;
    if (buffer->length + length + 1 > buffer->capacity) {
        size_t new_capacity = buffer->capacity == 0 ? 8192 : buffer->capacity;
        while (new_capacity < buffer->length + length + 1) {
            new_capacity *= 2;
        }
        char *new_data = (char *)realloc(buffer->data, new_capacity);
        if (new_data == NULL) return 0;
        buffer->data = new_data;
        buffer->capacity = new_capacity;
    }
    memcpy(buffer->data + buffer->length, data, length);
    buffer->length += length;
    buffer->data[buffer->length] = '\0';
    return 1;
}

static void headers_clear(HeaderList *headers) {
    for (size_t i = 0; i < headers->count; i++) {
        free(headers->items[i]);
    }
    headers->count = 0;
}

static void headers_free(HeaderList *headers) {
    headers_clear(headers);
    free(headers->items);
    headers->items = NULL;
    headers->capacity = 0;
}

static int headers_add(HeaderList *headers, const char *line, size_t length) {
    while (length > 0 && (line[length - 1] == '\r' || line[length - 1] == '\n')) {
        length--;
    }
    if (length == 0 || memchr(line, ':', length) == NULL) return 1;
    if (headers->count + 1 > headers->capacity) {
        size_t new_capacity = headers->capacity == 0 ? 16 : headers->capacity * 2;
        char **new_items = (char **)realloc(headers->items, sizeof(char *) * new_capacity);
        if (new_items == NULL) return 0;
        headers->items = new_items;
        headers->capacity = new_capacity;
    }
    char *copy = (char *)malloc(length + 1);
    if (copy == NULL) return 0;
    memcpy(copy, line, length);
    copy[length] = '\0';
    headers->items[headers->count++] = copy;
    return 1;
}

static size_t write_callback(char *ptr, size_t size, size_t nmemb, void *userdata) {
    Buffer *body = (Buffer *)userdata;
    size_t length = size * nmemb;
    return buffer_append(body, ptr, length) ? length : 0;
}

static size_t header_callback(char *ptr, size_t size, size_t nmemb, void *userdata) {
    HeaderList *headers = (HeaderList *)userdata;
    size_t length = size * nmemb;
    if (length >= 5 && memcmp(ptr, "HTTP/", 5) == 0) {
        headers_clear(headers);
        return length;
    }
    return headers_add(headers, ptr, length) ? length : 0;
}

static char *jstring_to_c(JNIEnv *env, jstring value) {
    if (value == NULL) return NULL;
    const char *chars = (*env)->GetStringUTFChars(env, value, NULL);
    if (chars == NULL) return NULL;
    char *copy = strdup(chars);
    (*env)->ReleaseStringUTFChars(env, value, chars);
    return copy;
}

static void put_object(JNIEnv *env, jobject map, const char *key, jobject value) {
    jclass map_class = (*env)->GetObjectClass(env, map);
    jmethodID put = (*env)->GetMethodID(env, map_class, "put",
                                       "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");
    jstring jkey = (*env)->NewStringUTF(env, key);
    (*env)->CallObjectMethod(env, map, put, jkey, value);
    (*env)->DeleteLocalRef(env, jkey);
    (*env)->DeleteLocalRef(env, map_class);
}

static void put_string(JNIEnv *env, jobject map, const char *key, const char *value) {
    jstring jvalue = value == NULL ? NULL : (*env)->NewStringUTF(env, value);
    put_object(env, map, key, jvalue);
    if (jvalue != NULL) (*env)->DeleteLocalRef(env, jvalue);
}

static void put_int(JNIEnv *env, jobject map, const char *key, jint value) {
    jclass integer_class = (*env)->FindClass(env, "java/lang/Integer");
    jmethodID value_of = (*env)->GetStaticMethodID(env, integer_class, "valueOf",
                                                   "(I)Ljava/lang/Integer;");
    jobject integer = (*env)->CallStaticObjectMethod(env, integer_class, value_of, value);
    put_object(env, map, key, integer);
    (*env)->DeleteLocalRef(env, integer);
    (*env)->DeleteLocalRef(env, integer_class);
}

static jobject new_hash_map(JNIEnv *env) {
    jclass hash_map_class = (*env)->FindClass(env, "java/util/HashMap");
    jmethodID init = (*env)->GetMethodID(env, hash_map_class, "<init>", "()V");
    jobject map = (*env)->NewObject(env, hash_map_class, init);
    (*env)->DeleteLocalRef(env, hash_map_class);
    return map;
}

static int add_header_to_java_map(const char *line, HeaderMapContext *context) {
    const char *colon = strchr(line, ':');
    if (colon == NULL) return 1;
    size_t key_length = (size_t)(colon - line);
    const char *value = colon + 1;
    while (*value == ' ' || *value == '\t') value++;

    char *key = (char *)malloc(key_length + 1);
    if (key == NULL) return 0;
    memcpy(key, line, key_length);
    key[key_length] = '\0';

    JNIEnv *env = context->env;
    jstring jkey = (*env)->NewStringUTF(env, key);
    jstring jvalue = (*env)->NewStringUTF(env, value);
    jobject list = (*env)->NewObject(env, context->array_list_class, context->array_list_init);
    (*env)->CallBooleanMethod(env, list, context->array_list_add, jvalue);
    (*env)->CallObjectMethod(env, context->map, context->map_put, jkey, list);
    (*env)->DeleteLocalRef(env, list);
    (*env)->DeleteLocalRef(env, jvalue);
    (*env)->DeleteLocalRef(env, jkey);
    free(key);
    return 1;
}

static jobject headers_to_java_map(JNIEnv *env, HeaderList *headers) {
    jobject map = new_hash_map(env);
    jclass map_class = (*env)->GetObjectClass(env, map);
    HeaderMapContext context = {
        .env = env,
        .map = map,
        .array_list_class = (*env)->FindClass(env, "java/util/ArrayList"),
        .map_put = (*env)->GetMethodID(env, map_class, "put",
                                       "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;"),
    };
    context.array_list_init = (*env)->GetMethodID(env, context.array_list_class, "<init>", "()V");
    context.array_list_add = (*env)->GetMethodID(env, context.array_list_class, "add",
                                                 "(Ljava/lang/Object;)Z");

    for (size_t i = 0; i < headers->count; i++) {
        add_header_to_java_map(headers->items[i], &context);
    }

    (*env)->DeleteLocalRef(env, context.array_list_class);
    (*env)->DeleteLocalRef(env, map_class);
    return map;
}

static struct curl_slist *headers_from_java_map(JNIEnv *env, jobject headers) {
    if (headers == NULL) return NULL;
    jclass map_class = (*env)->GetObjectClass(env, headers);
    jmethodID entry_set = (*env)->GetMethodID(env, map_class, "entrySet", "()Ljava/util/Set;");
    jobject set = (*env)->CallObjectMethod(env, headers, entry_set);
    jclass set_class = (*env)->GetObjectClass(env, set);
    jmethodID iterator_method = (*env)->GetMethodID(env, set_class, "iterator", "()Ljava/util/Iterator;");
    jobject iterator = (*env)->CallObjectMethod(env, set, iterator_method);
    jclass iterator_class = (*env)->GetObjectClass(env, iterator);
    jmethodID has_next = (*env)->GetMethodID(env, iterator_class, "hasNext", "()Z");
    jmethodID next = (*env)->GetMethodID(env, iterator_class, "next", "()Ljava/lang/Object;");
    jclass entry_class = (*env)->FindClass(env, "java/util/Map$Entry");
    jmethodID get_key = (*env)->GetMethodID(env, entry_class, "getKey", "()Ljava/lang/Object;");
    jmethodID get_value = (*env)->GetMethodID(env, entry_class, "getValue", "()Ljava/lang/Object;");

    struct curl_slist *list = NULL;
    while ((*env)->CallBooleanMethod(env, iterator, has_next)) {
        jobject entry = (*env)->CallObjectMethod(env, iterator, next);
        jstring key = (jstring)(*env)->CallObjectMethod(env, entry, get_key);
        jstring value = (jstring)(*env)->CallObjectMethod(env, entry, get_value);
        char *key_c = jstring_to_c(env, key);
        char *value_c = jstring_to_c(env, value);
        if (key_c != NULL && value_c != NULL &&
            strcasecmp(key_c, "content-length") != 0 &&
            strcasecmp(key_c, "accept-encoding") != 0) {
            size_t length = strlen(key_c) + strlen(value_c) + 3;
            char *line = (char *)malloc(length);
            if (line != NULL) {
                snprintf(line, length, "%s: %s", key_c, value_c);
                list = curl_slist_append(list, line);
                free(line);
            }
        }
        free(key_c);
        free(value_c);
        if (key != NULL) (*env)->DeleteLocalRef(env, key);
        if (value != NULL) (*env)->DeleteLocalRef(env, value);
        (*env)->DeleteLocalRef(env, entry);
    }

    (*env)->DeleteLocalRef(env, entry_class);
    (*env)->DeleteLocalRef(env, iterator_class);
    (*env)->DeleteLocalRef(env, iterator);
    (*env)->DeleteLocalRef(env, set_class);
    (*env)->DeleteLocalRef(env, set);
    (*env)->DeleteLocalRef(env, map_class);
    return list;
}

static jobject fetch_native(JNIEnv *env, jclass clazz, jstring method_value,
                            jstring url_value, jstring proxy_value, jobject headers_value,
                            jbyteArray body_value, jint timeout_ms, jint attempts) {
    (void)clazz;
    jobject result = new_hash_map(env);
    char *method = jstring_to_c(env, method_value);
    char *url = jstring_to_c(env, url_value);
    char *proxy = jstring_to_c(env, proxy_value);
    if (method == NULL || url == NULL) {
        put_string(env, result, "error", "invalid arguments");
        free(method);
        free(url);
        free(proxy);
        return result;
    }

    jbyte *body_bytes = NULL;
    jsize body_length = 0;
    if (body_value != NULL) {
        body_length = (*env)->GetArrayLength(env, body_value);
        body_bytes = (*env)->GetByteArrayElements(env, body_value, NULL);
    }

    CURLcode code = CURLE_OK;
    long status = 0;
    Buffer body = {0};
    HeaderList response_headers = {0};
    char error_buffer[CURL_ERROR_SIZE] = {0};
    int used_attempts = 0;

    if (attempts <= 0) attempts = 1;
    if (attempts > 5) attempts = 5;
    if (timeout_ms <= 0) timeout_ms = 15000;

    for (int attempt = 0; attempt < attempts; attempt++) {
        used_attempts = attempt + 1;
        buffer_free(&body);
        headers_clear(&response_headers);
        error_buffer[0] = '\0';

        CURL *curl = curl_easy_init();
        if (curl == NULL) {
            code = CURLE_FAILED_INIT;
            break;
        }

        struct curl_slist *request_headers = headers_from_java_map(env, headers_value);
        curl_easy_setopt(curl, CURLOPT_URL, url);
        curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
        curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 3L);
        curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, (long)timeout_ms);
        curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, (long)timeout_ms);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &body);
        curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, header_callback);
        curl_easy_setopt(curl, CURLOPT_HEADERDATA, &response_headers);
        curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, error_buffer);
        curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
        curl_easy_setopt(curl, CURLOPT_CAPATH, "/system/etc/security/cacerts");
        if (attempt > 0) {
            curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
            curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 0L);
        }
        if (proxy != NULL && proxy[0] != '\0') {
            curl_easy_setopt(curl, CURLOPT_PROXY, proxy);
        }
        if (request_headers != NULL) {
            curl_easy_setopt(curl, CURLOPT_HTTPHEADER, request_headers);
        }

        if (strcasecmp(method, "POST") == 0) {
            curl_easy_setopt(curl, CURLOPT_POST, 1L);
            curl_easy_setopt(curl, CURLOPT_POSTFIELDS, (void *)body_bytes);
            curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)body_length);
        } else if (strcasecmp(method, "GET") != 0) {
            curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method);
            if (body_bytes != NULL && body_length > 0) {
                curl_easy_setopt(curl, CURLOPT_POSTFIELDS, (void *)body_bytes);
                curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)body_length);
            }
        }

        code = curl_easy_perform(curl);
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
        curl_slist_free_all(request_headers);
        curl_easy_cleanup(curl);

        if (code == CURLE_OK && status >= 200 && status < 500) {
            break;
        }
    }

    put_int(env, result, "curlCode", (jint)code);
    put_int(env, result, "statusCode", (jint)status);
    put_int(env, result, "attempts", (jint)used_attempts);

    if (code == CURLE_OK) {
        jbyteArray jbody = (*env)->NewByteArray(env, (jsize)body.length);
        if (jbody != NULL && body.length > 0) {
            (*env)->SetByteArrayRegion(env, jbody, 0, (jsize)body.length, (const jbyte *)body.data);
        }
        jobject jheaders = headers_to_java_map(env, &response_headers);
        put_object(env, result, "body", jbody);
        put_object(env, result, "headers", jheaders);
        put_string(env, result, "url", url);
        (*env)->DeleteLocalRef(env, jheaders);
        if (jbody != NULL) (*env)->DeleteLocalRef(env, jbody);
    } else {
        const char *message = error_buffer[0] == '\0' ? curl_easy_strerror(code) : error_buffer;
        put_string(env, result, "error", message);
    }

    if (body_bytes != NULL) {
        (*env)->ReleaseByteArrayElements(env, body_value, body_bytes, JNI_ABORT);
    }
    buffer_free(&body);
    headers_free(&response_headers);
    free(method);
    free(url);
    free(proxy);
    return result;
}

static jboolean available_native(JNIEnv *env, jclass clazz) {
    (void)env;
    (void)clazz;
    return JNI_TRUE;
}

#else

static jobject new_hash_map(JNIEnv *env) {
    jclass hash_map_class = (*env)->FindClass(env, "java/util/HashMap");
    jmethodID init = (*env)->GetMethodID(env, hash_map_class, "<init>", "()V");
    jobject map = (*env)->NewObject(env, hash_map_class, init);
    (*env)->DeleteLocalRef(env, hash_map_class);
    return map;
}

static jobject fetch_native(JNIEnv *env, jclass clazz, jstring method_value,
                            jstring url_value, jstring proxy_value, jobject headers_value,
                            jbyteArray body_value, jint timeout_ms, jint attempts) {
    (void)clazz;
    (void)method_value;
    (void)url_value;
    (void)proxy_value;
    (void)headers_value;
    (void)body_value;
    (void)timeout_ms;
    (void)attempts;
    return new_hash_map(env);
}

static jboolean available_native(JNIEnv *env, jclass clazz) {
    (void)env;
    (void)clazz;
    return JNI_FALSE;
}

#endif

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    }

#ifdef PICA_USE_LIBCURL
    curl_global_init(CURL_GLOBAL_DEFAULT);
#endif

    jclass clazz = (*env)->FindClass(env, "com/github/pacalini/pica_comic/NativeCurl");
    if (clazz == NULL) {
        return JNI_ERR;
    }
    JNINativeMethod methods[] = {
        {
            "availableNative",
            "()Z",
            (void *)available_native,
        },
        {
            "fetchNative",
            "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/util/Map;[BII)Ljava/util/Map;",
            (void *)fetch_native,
        },
    };
    if ((*env)->RegisterNatives(env, clazz, methods, 2) != JNI_OK) {
        return JNI_ERR;
    }
    return JNI_VERSION_1_6;
}
