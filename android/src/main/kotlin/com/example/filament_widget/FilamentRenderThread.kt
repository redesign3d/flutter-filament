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
            frameRequested = false // Consumed

            // Double check state to avoid race conditions or redundant calls
            if (shouldStopLoop()) {
                return
            }

            var needsContinuous = false
            for (viewer in viewers) {
                viewer.render(frameTimeNanos)
                if (viewer.wantsContinuousRendering()) {
                    needsContinuous = true
                }
            }

            // Context: Continuous rendering or pending request
            if (needsContinuous || frameRequested) {
                scheduleFrame()
            }
        }
    }
    
    // State for lazy rendering
    private var frameRequested = false

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
        frameRequested = true
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
             // Only schedule if we have a pending request or active content
             // For simplicity in updateCallbackScheduling call, we just schedule 
             // and let doFrame decide whether to continue unless we strictly track active viewers here.
             // But to be fully lazy, we should check if we need to start.
             // If this is called from addViewer, we iterate.
             var needsStart = frameRequested
             if (!needsStart) {
                 for (v in viewers) {
                     if (v.wantsContinuousRendering()) {
                         needsStart = true
                         break
                     }
                 }
             }
             if (needsStart) {
                scheduleFrame()
             }
        }
    }

    private fun scheduleFrame() {
        // clear request flag as we are scheduling it now (or it will be cleared in doFrame)
        // actually doFrame clears it.
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
