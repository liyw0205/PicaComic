package com.github.pacalini.pica_comic

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

object NativeCurl {
    private val cancellations = ConcurrentHashMap<String, AtomicBoolean>()

    fun registerRequest(id: String): Boolean =
        cancellations.putIfAbsent(id, AtomicBoolean(false)) == null

    fun releaseRequest(id: String) {
        cancellations.remove(id)
    }

    fun cancelRequest(id: String) {
        cancellations[id]?.set(true)
    }

    private val loaded: Boolean = try {
        System.loadLibrary("pica_curl")
        availableNative()
    } catch (_: Throwable) {
        false
    }

    @JvmStatic
    private external fun availableNative(): Boolean

    @JvmStatic
    private external fun fetchNative(
        method: String,
        url: String,
        proxy: String?,
        headers: Map<String, String>,
        body: ByteArray?,
        timeoutMs: Int,
        attempts: Int,
        cancelled: AtomicBoolean,
    ): Map<String, Any?>

    fun isAvailable(): Boolean = loaded

    fun fetch(arguments: Map<*, *>): Map<String, Any?> {
        val headers = mutableMapOf<String, String>()
        val rawHeaders = arguments["headers"]
        if (rawHeaders is Map<*, *>) {
            for ((key, value) in rawHeaders) {
                if (key != null && value != null) {
                    headers[key.toString()] = value.toString()
                }
            }
        }
        val id = arguments["requestId"]?.toString() ?: ""
        val cancelled = cancellations[id] ?: AtomicBoolean(false)
        try {
            if (!loaded) return mapOf("error" to "native curl unavailable")
            return fetchNative(
            arguments["method"]?.toString() ?: "GET",
            arguments["url"]?.toString() ?: "",
            arguments["proxy"]?.toString(),
            headers,
            arguments["body"] as? ByteArray,
            arguments["timeoutMs"] as? Int ?: 15000,
            arguments["attempts"] as? Int ?: 3,
            cancelled,
            )
        } finally {
            cancellations.remove(id)
        }
    }
}
