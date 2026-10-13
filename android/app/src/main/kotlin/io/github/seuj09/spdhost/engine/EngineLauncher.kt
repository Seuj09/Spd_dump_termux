package io.github.seuj09.spdhost.engine

import android.content.Context
import android.os.Process as AndroidProcess
import io.github.seuj09.spdhost.BuildConfig
import java.io.File

/** A running core child as EngineService sees it (EngineSession in the app). */
interface EngineChild {
    fun start()
    /** SIGINT, then destroy (EngineSession.stop). */
    fun stop()
}

/**
 * How EngineService gates and spawns the core child. The app uses [Default]
 * (caps probe of the packaged core + [EngineSession]); the E8 Robolectric
 * tests inject a fake child so the service lifecycle (foreground, USB pin and
 * release on child exit, stop) runs with no native core (#40 soft note 2).
 */
interface EngineLauncher {
    /** Blocking, off the main thread. Null = allowed; else why refused. */
    fun gateRefusal(ctx: Context): String?

    /**
     * Where the start work (caps gate, mkdirs, USB pin, spawn) runs: a daemon
     * thread in the app. The E8 fake runs it inline on the main thread so the
     * tests are deterministic, with no wall-clock waits (#41 note 4).
     */
    fun background(name: String, body: () -> Unit) {
        Thread(body).apply { this.name = name; isDaemon = true; start() }
    }

    fun create(
        ctx: Context,
        usbFd: Int,
        commands: List<String>,
        onLog: (String) -> Unit,
        onEvent: (EngineEvent) -> Unit,
        onExit: (Int?) -> Unit,
    ): EngineChild

    object Default : EngineLauncher {
        override fun gateRefusal(ctx: Context): String? =
            EngineGate.refusal(CoreRunner.probeCaps(ctx).caps, BuildConfig.GIT_SHA)

        override fun create(
            ctx: Context, usbFd: Int, commands: List<String>,
            onLog: (String) -> Unit, onEvent: (EngineEvent) -> Unit, onExit: (Int?) -> Unit,
        ): EngineChild = EngineSession(
            core = CoreRunner.corePath(ctx),
            runDir = File(ctx.noBackupFilesDir, "run"),
            myUid = AndroidProcess.myUid(),
            usbFd = usbFd,
            commands = commands,
            onLog = onLog,
            onEvent = onEvent,
            onExit = onExit,
        )
    }
}
