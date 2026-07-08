package com.github.pacalini.pica_comic

object NativeCurl {
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
    ): Map<String, Any?>

    fun isAvailable(): Boolean = loaded

    fun fetch(arguments: Map<*, *>): Map<String, Any?> {
        if (!loaded) {
            return mapOf("error" to "native curl unavailable")
        }
        val headers = mutableMapOf<String, String>()
        val rawHeaders = arguments["headers"]
        if (rawHeaders is Map<*, *>) {
            for ((key, value) in rawHeaders) {
                if (key != null && value != null) {
                    headers[key.toString()] = value.toString()
                }
            }
        }
        return fetchNative(
            arguments["method"]?.toString() ?: "GET",
            arguments["url"]?.toString() ?: "",
            arguments["proxy"]?.toString(),
            headers,
            arguments["body"] as? ByteArray,
            arguments["timeoutMs"] as? Int ?: 15000,
            arguments["attempts"] as? Int ?: 3,
        )
    }
}
