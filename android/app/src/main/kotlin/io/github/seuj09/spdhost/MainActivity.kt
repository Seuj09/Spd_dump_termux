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
    // P1-1: the attach intent only brings the app forward. The USB broker
    // (permission, open, detach) lands in P1-2.

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            SpdhostTheme { AppRoot(app) }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

}
