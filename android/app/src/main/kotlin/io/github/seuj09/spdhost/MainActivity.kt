package io.github.seuj09.spdhost

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import io.github.seuj09.spdhost.engine.EngineService
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import io.github.seuj09.spdhost.ui.AppRoot
import io.github.seuj09.spdhost.ui.SpdhostTheme

/**
 * singleTop (manifest): plugging the phone while the app is open delivers the
 * USB_DEVICE_ATTACHED intent here through onNewIntent instead of stacking a
 * second Activity.
 */
class MainActivity : ComponentActivity() {
    private val app get() = application as SpdhostApp

    private var pendingCommands: List<String>? = null

    // POST_NOTIFICATIONS is a runtime permission on 33+ only (ApiGates). A
    // denial does not block the session: the FGS still runs, its
    // notification is just hidden.
    private val notifPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { _ ->
        pendingCommands?.let { EngineService.start(this, it) }
        pendingCommands = null
    }

    /** From the UI: start a core session through the foreground service. */
    fun startEngine(commands: List<String>) {
        // D1: start the FGS only once the broker has the device open.
        io.github.seuj09.spdhost.engine.EngineLaunchPolicy.startRefusal(app.broker.state.value)?.let {
            app.engine.refused(it); return
        }
        if (ApiGates.needsNotificationPermission(Build.VERSION.SDK_INT) &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            pendingCommands = commands
            notifPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
            return
        }
        EngineService.start(this, commands)
    }

    fun stopEngine() = EngineService.stop(this)

    // P1-4: SAF import of fdl-pack-<sha7>.zip. Copied into the app dir and
    // verified against the pinned sha; the Uri itself is not kept.
    private val packPicker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let { app.loaders.import(it) }
    }

    fun importLoaderPack() = packPicker.launch(arrayOf("application/zip", "application/octet-stream", "application/x-zip-compressed"))

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        // Only a fresh launch carries a new attach intent; a recreation
        // (rotation) replays the old one, which the broker would just rescan.
        if (savedInstanceState == null) app.broker.handleIntent(intent)
        setContent {
            SpdhostTheme { AppRoot(app, ::startEngine, ::stopEngine, ::importLoaderPack) }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        app.broker.handleIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        // Catch attach/detach that happened while we were in the background.
        app.broker.rescan()
    }
}
