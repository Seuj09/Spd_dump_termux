package io.github.seuj09.spdhost.engine

/**
 * Caps gate (plan P1-3, A3): a device session starts only when the core in
 * this APK answered `caps` with protocol 1, the two caps the session uses
 * (usb-fd-sock, events), and the same commit as the APK. Null = allowed;
 * otherwise the reason it is refused.
 */
object EngineGate {
    const val PROTOCOL = 1
    val REQUIRED_CAPS = listOf("usb-fd-sock", "events")

    fun refusal(caps: Caps?, apkSha: String): String? {
        if (caps == null) return "the core gave no valid caps"
        if (caps.protocol != PROTOCOL) return "core protocol ${caps.protocol ?: "?"} (need $PROTOCOL)"
        val missing = REQUIRED_CAPS.filterNot(caps::has)
        if (missing.isNotEmpty()) return "core lacks cap ${missing.joinToString()}"
        if (caps.buildSha == null || apkSha == "unknown") return "cannot compare the core's commit with the APK's"
        if (caps.buildSha != apkSha) return "core commit ${caps.buildSha.take(7)} differs from the APK's ${apkSha.take(7)}"
        return null
    }
}
