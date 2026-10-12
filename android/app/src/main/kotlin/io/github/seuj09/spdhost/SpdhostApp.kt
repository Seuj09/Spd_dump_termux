package io.github.seuj09.spdhost

import android.app.Application
import io.github.seuj09.spdhost.engine.CoreProbe
import io.github.seuj09.spdhost.engine.CoreRunner
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Process-wide holder: the last core probe survives Activity recreation. */
class SpdhostApp : Application() {
    private val _core = MutableStateFlow<CoreProbe?>(null)
    val core: StateFlow<CoreProbe?> = _core.asStateFlow()
    @Volatile private var probing = false

    override fun onCreate() {
        super.onCreate()
        probeCore()
    }

    /** Runs `libspdhost.so caps` off the main thread. */
    fun probeCore() {
        if (probing) return
        probing = true
        _core.value = null
        Thread {
            try {
                _core.value = CoreRunner.probeCaps(this)
            } finally {
                probing = false
            }
        }.apply { name = "core-caps"; isDaemon = true; start() }
    }
}
