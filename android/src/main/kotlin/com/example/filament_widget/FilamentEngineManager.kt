package com.example.filament_widget

import android.os.Looper
import com.google.android.filament.Engine
import com.google.android.filament.Filament

object FilamentEngineManager {
    private var engine: Engine? = null

    fun getEngine(): Engine {
        return engine ?: throw IllegalStateException("Filament Engine not initialized")
    }

    fun init() {
        if (engine != null) return
        checkThread()
        Filament.init()
        engine = Engine.create()
    }

    fun destroy() {
        checkThread()
        engine?.destroy()
        engine = null
    }

    private fun checkThread() {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            throw IllegalStateException("Filament Engine must not be accessed on the main thread.")
        }
    }
}
