package com.example.filament_widget

import android.os.Handler
import android.os.HandlerThread
import android.view.Choreographer
import java.util.concurrent.CopyOnWriteArraySet

class FilamentRenderThread {
    private val thread = HandlerThread("FilamentRenderThread").apply { start() }
    private val handler = Handler(thread.looper)
    private val viewers = CopyOnWriteArraySet<FilamentViewer>()
    private var choreographer: Choreographer? = null

    init {
        handler.post {
            FilamentEngineManager.init()
        }
    }

    private val frameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (viewers.isEmpty()) {
                stopChoreographer()
                return
            }
            for (viewer in viewers) {
                viewer.render(frameTimeNanos)
            }
            choreographer?.postFrameCallback(this)
        }
    }

    fun post(task: () -> Unit) {
        handler.post(task)
    }

    fun addViewer(viewer: FilamentViewer) {
        if (Thread.currentThread() !== thread) {
            handler.post { addViewer(viewer) }
            return
        }
        viewers.add(viewer)
        ensureChoreographer()
    }

    fun removeViewer(viewer: FilamentViewer) {
        if (Thread.currentThread() !== thread) {
            handler.post { removeViewer(viewer) }
            return
        }
        viewers.remove(viewer)
        if (viewers.isEmpty()) {
            stopChoreographer()
        }
    }

    fun setPaused(paused: Boolean) {
        handler.post {
            for (viewer in viewers) {
                viewer.setPaused(paused)
            }
        }
    }

    fun dispose() {
        handler.post {
            stopChoreographer()
            viewers.clear()
            FilamentEngineManager.destroy()
            thread.quitSafely()
        }
    }

    private fun ensureChoreographer() {
        if (choreographer == null) {
            choreographer = Choreographer.getInstance()
            choreographer?.postFrameCallback(frameCallback)
        }
    }

    private fun stopChoreographer() {
        choreographer?.removeFrameCallback(frameCallback)
        choreographer = null
    }
}
