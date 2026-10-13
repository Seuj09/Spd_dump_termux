package io.github.seuj09.spdhost.engine

/**
 * The one place the app builds a core argv for a device session (plan P1-3,
 * E2: the argv must equal what menu.sh would run). Pure, so it is unit-tested.
 *
 *     libspdhost.so --usb-fd-sock <app-private path> --events <path> <commands…>
 *
 * Rules enforced here, not by convention:
 *  - the socket path is a FILESYSTEM path (absolute) shorter than sun_path
 *    (108 bytes, NUL included, so at most 107);
 *  - commands come from a read-only allowlist. P1-3 allows only `ping` (the
 *    BootROM hello); P1-5 widens it to parts/ops dump. No option that
 *    authorizes a write is ever produced: the allowlist has no options at all.
 */
object EngineArgv {
    /** sizeof(sockaddr_un.sun_path) on Linux/Android. */
    const val SUN_PATH_MAX = 108

    /** Read-only verbs this slice may run. */
    val READ_ONLY_COMMANDS: Set<String> = setOf("ping")

    class Refused(msg: String) : IllegalArgumentException(msg)

    fun session(core: String, sockPath: String, eventsPath: String, commands: List<String>): List<String> {
        checkSockPath(sockPath)
        require(eventsPath.startsWith("/")) { "events path must be absolute" }
        if (commands.isEmpty()) throw Refused("no command")
        for (c in commands) {
            if (c !in READ_ONLY_COMMANDS) throw Refused("command '$c' is not allowed in this build (read-only: ${READ_ONLY_COMMANDS.joinToString()})")
        }
        return listOf(core, "--usb-fd-sock", sockPath, "--events", eventsPath) + commands
    }

    fun checkSockPath(path: String) {
        if (!path.startsWith("/")) throw Refused("socket path must be an absolute filesystem path")
        val n = path.toByteArray(Charsets.UTF_8).size
        if (n >= SUN_PATH_MAX) throw Refused("socket path is $n bytes; must be < $SUN_PATH_MAX")
    }
}
