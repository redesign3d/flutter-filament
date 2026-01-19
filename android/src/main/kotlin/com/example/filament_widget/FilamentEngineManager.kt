package com.example.filament_widget

import com.google.android.filament.Engine
import com.google.android.filament.Filament

object FilamentEngineManager {
    private var engine: Engine? = null

    fun getEngine(): Engine {
        if (engine == null) {
            Filament.init()
            engine = Engine.create()
        }
        return engine!!
    }
}
