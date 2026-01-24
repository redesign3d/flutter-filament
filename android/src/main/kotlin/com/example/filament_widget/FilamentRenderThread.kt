package com.example.filament_widget

import android.os.Handler
import android.os.HandlerThread
import android.view.Choreographer
import android.util.Log
import java.util.concurrent.CopyOnWriteArraySet

class FilamentRenderThread {
    private val thread = HandlerThread("FilamentRenderThread").apply { start() }
    private val handler = Handler(thread.looper)
    private val viewers = CopyOnWriteArraySet<FilamentViewer>()
    private var choreographer: Choreographer? = null

    // State tracking
    private var isAppPaused = false
    private var isCallbackScheduled = false

    private val TAG = "FilamentRenderThread"

    init {
        handler.post {
            FilamentEngineManager.init()
            choreographer = Choreographer.getInstance()
        }
    }

    private val frameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            isCallbackScheduled = false

            // Double check state to avoid race conditions or redundant calls
            if (shouldStopLoop()) {
                return
            }

            for (viewer in viewers) {
                viewer.render(frameTimeNanos)
            }
            
            // Context: Continuous rendering
            scheduleFrame()
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
        updateCallbackScheduling()
    }

    fun removeViewer(viewer: FilamentViewer) {
        if (Thread.currentThread() !== thread) {
            handler.post { removeViewer(viewer) }
            return
        }
        viewers.remove(viewer)
        updateCallbackScheduling()
    }

    fun setAppPaused(paused: Boolean) {
        if (Thread.currentThread() !== thread) {
            handler.post { setAppPaused(paused) }
            return
        }
        if (isAppPaused != paused) {
            isAppPaused = paused
            val stateName = if (paused) "paused" else "resumed"
            Log.d(TAG, "App lifecycle changed: $stateName")

             // Propagate pause state to viewers
            for (viewer in viewers) {
                viewer.setPaused(paused)
            }
            updateCallbackScheduling()
        }
    }
    
    // Backwards compatibility / alias can run same logic
    fun setPaused(paused: Boolean) = setAppPaused(paused)

    fun requestFrame() {
        if (Thread.currentThread() !== thread) {
            handler.post { requestFrame() }
            return
        }
        scheduleFrame()
    }

    fun dispose() {
        handler.post {
            stopChoreographer()
            viewers.clear()
            FilamentEngineManager.destroy()
            thread.quitSafely()
        }
    }

    private fun shouldStopLoop(): Boolean {
        // We stop if app is paused OR no viewers are active
        return isAppPaused || viewers.isEmpty()
    }

    private fun updateCallbackScheduling() {
        if (shouldStopLoop()) {
            stopChoreographer()
        } else {
            scheduleFrame()
        }
    }

    private fun scheduleFrame() {
        if (!isCallbackScheduled && !shouldStopLoop()) {
            choreographer?.postFrameCallback(frameCallback)
            isCallbackScheduled = true
            // Log logic for debugging scheduling start could go here
        }
    }

    private fun stopChoreographer() {
        if (isCallbackScheduled) {
            choreographer?.removeFrameCallback(frameCallback)
            isCallbackScheduled = false
            Log.d(TAG, "Choreographer callback removed (paused=$isAppPaused, viewers=${viewers.size})")
        }
    }
}
