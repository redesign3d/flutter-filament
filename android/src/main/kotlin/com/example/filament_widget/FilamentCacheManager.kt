package com.example.filament_widget

import java.io.File
import java.io.FileOutputStream
import java.net.URL
import java.security.MessageDigest

class FilamentCacheManager(private val rootDir: File) {
    private val cacheDir = File(rootDir, "filament_widget_cache")

    fun getCacheSizeBytes(): Long {
        if (!cacheDir.exists()) {
            return 0L
        }
        return cacheDir.walkTopDown()
            .filter { it.isFile }
            .map { it.length() }
            .sum()
    }

    fun clearCache(): Boolean {
        if (!cacheDir.exists()) {
            return true
        }
        return cacheDir.deleteRecursively()
    }

    fun getOrDownload(url: String): File {
        cacheDir.mkdirs()
        val target = File(cacheDir, cacheFileName(url))
        if (target.exists()) {
            return target
        }
        val connection = URL(url).openConnection() as java.net.HttpURLConnection
        connection.connectTimeout = 15000
        connection.readTimeout = 20000
        connection.instanceFollowRedirects = true
        connection.connect()

        if (connection.responseCode !in 200..299) {
            throw java.io.IOException("Failed to download file: HTTP ${connection.responseCode}")
        }

        connection.inputStream.use { input ->
            FileOutputStream(target).use { output ->
                input.copyTo(output)
            }
        }
        return target
    }

    private fun cacheFileName(url: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val bytes = digest.digest(url.toByteArray())
        val hash = bytes.joinToString("") { "%02x".format(it) }
        val extension = url.substringAfterLast('.', "").takeIf { it.length <= 6 }
        return if (extension.isNullOrEmpty()) hash else "$hash.$extension"
    }
}
