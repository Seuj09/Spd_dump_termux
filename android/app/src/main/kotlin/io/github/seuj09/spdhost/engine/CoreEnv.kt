package io.github.seuj09.spdhost.engine

/**
 * The environment the core child runs with (plan P1: env whitelist). Every
 * SPDHOST_* / SPD_* knob is CLI-only (transport tuning, BROM tracing, …), and
 * TERMUX_USB_FD would make the core wrap an fd the app did not hand over, so
 * all of them are stripped. Everything else is inherited.
 */
object CoreEnv {
    fun isStripped(key: String): Boolean =
        key.startsWith("SPDHOST_") || key.startsWith("SPD_") || key == "TERMUX_USB_FD"

    fun sanitize(env: MutableMap<String, String>) {
        env.keys.filter(::isStripped).forEach(env::remove)
    }
}
