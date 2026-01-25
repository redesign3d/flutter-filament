package com.example.filament_widget

import com.google.android.filament.Engine
import com.google.android.filament.IndirectLight
import com.google.android.filament.Skybox
import com.google.android.filament.Texture
import java.util.concurrent.ConcurrentHashMap

data class EnvironmentResource(
    val indirectLight: IndirectLight?,
    val skybox: Skybox?,
    val skyboxTexture: Texture?,
    val iblTexture: Texture?
)

private class RefCountedResource(
     val resource: EnvironmentResource
) {
    var refCount = 0
}

object EnvironmentCache {
    private val cache = ConcurrentHashMap<String, RefCountedResource>()

    fun retain(key: String): EnvironmentResource? {
        val entry = cache[key] ?: return null
        entry.refCount++
        return entry.resource
    }

    fun add(key: String, resource: EnvironmentResource) {
        val entry = RefCountedResource(resource)
        entry.refCount = 1
        cache[key] = entry
    }

    fun release(key: String, engine: Engine): Boolean {
        val entry = cache[key] ?: return false
        entry.refCount--
        if (entry.refCount <= 0) {
            // Destruction must be handled by the caller or passed in engine context
            // Here we just remove from cache and return true indicating "should destroy"
            // Actually, we must destroy here if we want to encapsulate, but we need the engine.
            destroyResource(entry.resource, engine)
            cache.remove(key)
            return true
        }
        return false
    }

    private fun destroyResource(res: EnvironmentResource, engine: Engine) {
        res.indirectLight?.let { engine.destroyIndirectLight(it) }
        res.skybox?.let { engine.destroySkybox(it) }
        res.skyboxTexture?.let { engine.destroyTexture(it) }
        res.iblTexture?.let { engine.destroyTexture(it) }
    }
    
    fun clear(engine: Engine) {
        for ((_, entry) in cache) {
            destroyResource(entry.resource, engine)
        }
        cache.clear()
    }
}
