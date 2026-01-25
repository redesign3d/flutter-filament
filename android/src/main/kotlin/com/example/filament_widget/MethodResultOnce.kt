package com.example.filament_widget

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.atomic.AtomicBoolean

class MethodResultOnce(
    private val delegate: Result,
    private val handler: Handler = Handler(Looper.getMainLooper()),
    private val tag: String = "FilamentWidget",
    private val debugLogging: Boolean = BuildConfig.DEBUG,
) : Result {
    private val completed = AtomicBoolean(false)

    override fun success(result: Any?) {
        completeOnce { delegate.success(result) }
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        completeOnce { delegate.error(errorCode, errorMessage, errorDetails) }
    }

    override fun notImplemented() {
        completeOnce { delegate.notImplemented() }
    }

    private fun completeOnce(block: () -> Unit) {
        if (!completed.compareAndSet(false, true)) {
            if (debugLogging) {
                Log.d(tag, "MethodResultOnce: duplicate completion ignored")
            }
            return
        }
        if (Looper.myLooper() == handler.looper) {
            block()
        } else {
            handler.post { block() }
        }
    }
}
