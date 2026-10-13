package io.github.seuj09.spdhost.e8

import io.github.seuj09.spdhost.SpdhostApp
import org.robolectric.Shadows.shadowOf

/**
 * Below 33, ContextCompat.registerReceiver(RECEIVER_NOT_EXPORTED) checks the
 * app holds its own signature permission <pkg>.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION
 * (from core-ktx's manifest). A device grants it at install; Robolectric does
 * not, so grant it before SpdhostApp.onCreate starts the broker.
 */
class E8App : SpdhostApp() {
    override fun onCreate() {
        shadowOf(this).grantPermissions("$packageName.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION")
        super.onCreate()
    }
}
