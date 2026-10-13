package io.github.seuj09.spdhost.engine

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.github.seuj09.spdhost.ApiGates
import io.github.seuj09.spdhost.MainActivity
import io.github.seuj09.spdhost.SpdhostApp

/**
 * Foreground service that owns one core session (plan P1-3, §7):
 *  - FGS type connectedDevice on 29+ (ServiceCompat passes 0 below);
 *    startForegroundService on 26+, startService + startForeground below;
 *    notification channel on 26+ only.
 *  - Partial wake lock for the whole session.
 *  - Caps gate before anything touches USB; the UsbDeviceConnection is held
 *    by the broker from start until the child exits (no close in between).
 *  - Stop = SIGINT to the child.
 */
class EngineService : Service() {
    private val app get() = application as SpdhostApp
    private var wake: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (EngineLaunchPolicy.goesForeground(action)) {
            // D1: never startForeground(connectedDevice) without an open
            // device (34+ throws SecurityException without USB permission).
            val why = EngineLaunchPolicy.startRefusal(app.broker.state.value)
            if (why != null) { app.engine.refused(why); refuseForeground(); return START_NOT_STICKY }
            try {
                goForeground()
            } catch (e: SecurityException) {
                app.engine.refused("foreground service refused: ${e.message}")
                refuseForeground(); return START_NOT_STICKY
            }
            startSession(intent!!.getStringArrayListExtra(EXTRA_COMMANDS).orEmpty())
            return START_NOT_STICKY
        }
        // STOP / null / unknown: no startForeground.
        when (action) {
            ACTION_STOP -> app.engine.session?.let { app.engine.stopping(); it.stop() } ?: stopSelf()
            else -> if (app.engine.session == null) stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startSession(commands: List<String>) {
        val ctl = app.engine
        if (ctl.session != null) { ctl.log("a session is already running"); return }
        Thread {
            // Caps gate (blocking, offline: no USB).
            val why = launcher.gateRefusal(this)
            if (why != null) { ctl.refused(why); finish(); return@Thread }
            // P1-5: only the read-only grammar, and the --part-xml folder
            // (DIR/meta) must exist before the session: the core does not
            // create it.
            val bad = runCatching { EngineArgv.validate(commands) }.exceptionOrNull()
            if (bad != null) { ctl.refused(bad.message ?: "refused"); finish(); return@Thread }
            for (d in SessionArgs.dirsToCreate(commands)) {
                val f = java.io.File(d)
                if (!f.isDirectory && !f.mkdirs()) { ctl.refused("cannot create $d"); finish(); return@Thread }
            }
            val fd = app.broker.holdForEngine()
            if (fd == null) { ctl.refused("the USB device is not open"); finish(); return@Thread }
            acquireWake()
            ctl.started(commands)
            val s = try {
                launcher.create(
                    ctx = this,
                    usbFd = fd,
                    commands = commands,
                    onLog = ctl::log,
                    onEvent = ctl::event,
                    onExit = { rc ->
                        // Release first, each guarded, so a throw in the UI
                        // callbacks can never skip them.
                        try {
                            runCatching { app.broker.releaseFromEngine() }
                            runCatching { releaseWake() }
                        } finally {
                            // #36 S2: finish() here is not coordinated with a
                            // START that races in after the child exits. That
                            // is fine while P1 is single-session (startSession
                            // refuses a second session and the UI disables
                            // Start while one runs); revisit before any
                            // multi-session or reacquire (P2-R) work.
                            ctl.session = null
                            ctl.exited(rc)
                            finish()
                        }
                    },
                )
            } catch (e: Exception) {
                app.broker.releaseFromEngine(); releaseWake()
                ctl.refused("${e.javaClass.simpleName}: ${e.message}"); finish(); return@Thread
            }
            ctl.session = s
            try {
                s.start()
            } catch (e: Exception) {
                ctl.session = null
                app.broker.releaseFromEngine(); releaseWake()
                ctl.refused("${e.javaClass.simpleName}: ${e.message}"); finish()
            }
        }.apply { name = "engine-start"; isDaemon = true; start() }
    }

    private fun goForeground() {
        if (ApiGates.needsChannel(Build.VERSION.SDK_INT)) createChannel()
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE, // minSdk 24 > 23; the content intent needs no extras
        )
        val n: Notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("spdhost session")
            .setContentText("Talking to the phone over USB")
            .setOngoing(true)
            .setContentIntent(open)
            .build()
        val type = if (ApiGates.typeHonoured(Build.VERSION.SDK_INT)) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0
        ServiceCompat.startForeground(this, NOTIFICATION_ID, n, type)
    }

    /**
     * #36 S1: refusing a START that came through startForegroundService (26+)
     * still owes the system a startForeground, else "did not call
     * startForeground" kills the app (e.g. the device closed after the UI
     * check). Go foreground briefly with a minimal notification of a type
     * that needs no USB permission (EngineLaunchPolicy), then stop.
     */
    private fun refuseForeground() {
        val type = EngineLaunchPolicy.refusalForegroundType(Build.VERSION.SDK_INT)
        if (type != null) {
            try {
                if (ApiGates.needsChannel(Build.VERSION.SDK_INT)) createChannel()
                val n = NotificationCompat.Builder(this, CHANNEL)
                    .setSmallIcon(android.R.drawable.stat_notify_error)
                    .setContentTitle("spdhost session refused")
                    .build()
                ServiceCompat.startForeground(this, NOTIFICATION_ID, n, type)
            } catch (e: Exception) {
                app.engine.log("minimal foreground failed: ${e.javaClass.simpleName}: ${e.message}")
            }
        }
        finish()
    }

    private fun createChannel() {
        NotificationManagerCompat.from(this).createNotificationChannel(
            NotificationChannelCompat.Builder(CHANNEL, NotificationManagerCompat.IMPORTANCE_LOW)
                .setName("Engine session").build()
        )
    }

    private fun acquireWake() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "spdhost:session").apply {
            setReferenceCounted(false)
            acquire(WAKE_MAX_MS) // safety cap; released on exit
        }
    }

    private fun releaseWake() {
        wake?.let { if (it.isHeld) it.release() }
        wake = null
    }

    private fun finish() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        // Process stays; if the service is torn down mid-session, stop the child.
        app.engine.session?.stop()
        super.onDestroy()
    }

    companion object {
        const val ACTION_START = "io.github.seuj09.spdhost.engine.START"
        const val ACTION_STOP = "io.github.seuj09.spdhost.engine.STOP"
        const val EXTRA_COMMANDS = "commands"
        private const val CHANNEL = "engine"
        private const val NOTIFICATION_ID = 1
        private const val WAKE_MAX_MS = 3L * 60 * 60 * 1000

        /** Gate + child factory; E8 tests swap in a fake child (EngineLauncher). */
        @androidx.annotation.VisibleForTesting
        @Volatile var launcher: EngineLauncher = EngineLauncher.Default

        fun start(ctx: Context, commands: List<String>) {
            val i = Intent(ctx, EngineService::class.java).setAction(ACTION_START)
                .putStringArrayListExtra(EXTRA_COMMANDS, ArrayList(commands))
            launch(ctx, i)
        }

        /**
         * Stop the running session in-process (SIGINT). No service intent:
         * startForegroundService(STOP) would oblige a startForeground (D1).
         */
        fun stop(ctx: Context) {
            val ctl = (ctx.applicationContext as SpdhostApp).engine
            ctl.session?.let { ctl.stopping(); it.stop() }
        }

        private fun launch(ctx: Context, i: Intent) {
            if (ApiGates.useStartForegroundService(Build.VERSION.SDK_INT)) ContextCompat.startForegroundService(ctx, i)
            else ctx.startService(i) // below 26: startService + startForeground in onStartCommand
        }
    }
}
