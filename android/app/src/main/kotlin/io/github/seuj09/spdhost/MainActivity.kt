package io.github.seuj09.spdhost

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
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

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        // Only a fresh launch carries a new attach intent; a recreation
        // (rotation) replays the old one, which the broker would just rescan.
        if (savedInstanceState == null) app.broker.handleIntent(intent)
        setContent {
            SpdhostTheme { AppRoot(app) }
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
