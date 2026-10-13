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
 *  - commands must match a read-only GRAMMAR (P1-5), checked token by token:
 *      [--timeout N] [--keep-going] [--part-xml ABS]
 *      ping
 *    | [exec_addr HEX ABS] fdl ABS HEX fdl ABS HEX
 *        ( parts ABS | ops dump ABS --preset P [--preset P…] ) [reset|power-off]
 *    Nothing that authorizes or performs a write can be expressed: no yes-flag,
 *    --dangerous, --confirm-*, misc, set-active, write-*, erase-*, reacquire.
 */
object EngineArgv {
    /** sizeof(sockaddr_un.sun_path) on Linux/Android. */
    const val SUN_PATH_MAX = 108

    /** Session verbs this build may run (P1-5: hello, table read, dump, ending). */
    val READ_ONLY_COMMANDS: Set<String> = setOf("ping", "exec_addr", "fdl", "parts", "ops dump", "reset", "power-off")

    /** `--preset` values: the words, or a partition name. userdata is never offered (it asks on a tty). */
    val PRESET_WORDS = setOf("all", "all_lite")
    private val PART_NAME = Regex("[A-Za-z0-9_]{1,36}")
    private val HEX = Regex("0x[0-9a-fA-F]{1,16}")

    class Refused(msg: String) : IllegalArgumentException(msg)

    fun session(core: String, sockPath: String, eventsPath: String, commands: List<String>): List<String> {
        checkSockPath(sockPath)
        require(eventsPath.startsWith("/")) { "events path must be absolute" }
        validate(commands)
        return listOf(core, "--usb-fd-sock", sockPath, "--events", eventsPath) + commands
    }

    fun validate(c: List<String>) {
        if (c.isEmpty()) throw Refused("no command")
        var i = 0
        fun at(k: Int, what: String): String = c.getOrNull(k) ?: throw Refused("missing $what after '${c[k - 1]}'")
        fun abs(k: Int, what: String) = at(k, what).also { if (!it.startsWith("/") || it.contains("/../")) throw Refused("$what must be an absolute path: $it") }
        fun hex(k: Int, what: String) = at(k, what).also { if (!HEX.matches(it)) throw Refused("$what must be 0x hex: $it") }
        while (i < c.size && c[i].startsWith("--")) {
            when (c[i]) {
                "--timeout" -> { if (at(i + 1, "N").toIntOrNull()?.takeIf { it in 100..600_000 } == null) throw Refused("bad --timeout"); i += 2 }
                "--keep-going" -> i++
                "--part-xml" -> { abs(i + 1, "--part-xml DIR"); i += 2 }
                else -> throw Refused("option '${c[i]}' is not allowed in this build")
            }
        }
        if (i >= c.size) throw Refused("no command")
        var fdl = 0; var stub = false; var ended = false; var work = false
        while (i < c.size) {
            val w = c[i]
            if (ended) throw Refused("'$w' after the ending")
            when (w) {
                "ping" -> { if (fdl > 0 || stub) throw Refused("ping only as a BootROM hello"); i++ }
                "exec_addr" -> { if (stub || fdl > 0) throw Refused("exec_addr must come once, before fdl"); hex(i + 1, "ADDR"); abs(i + 2, "STUB"); stub = true; i += 3 }
                "fdl" -> { if (++fdl > 2) throw Refused("more than two fdl"); abs(i + 1, "FILE"); hex(i + 2, "ADDR"); i += 3 }
                "parts" -> { if (fdl != 2 || work) throw Refused("parts needs both fdl, once"); abs(i + 1, "FILE"); work = true; i += 2 }
                "ops" -> {
                    if (at(i + 1, "op") != "dump") throw Refused("ops ${c[i + 1]} is not allowed in this build (read-only)")
                    if (fdl != 2 || work) throw Refused("ops dump needs both fdl, once")
                    abs(i + 2, "DIR"); i += 3
                    val presets = ArrayList<String>()
                    while (c.getOrNull(i) == "--preset") { presets += at(i + 1, "P"); i += 2 }
                    checkPresets(presets)
                    work = true
                }
                "reset", "power-off" -> { if (fdl == 0) throw Refused("$w needs FDL1"); ended = true; i++ }
                else -> throw Refused("command '$w' is not allowed in this build (read-only)")
            }
        }
        if (fdl == 1) throw Refused("only one fdl")
    }

    fun checkPresets(p: List<String>) {
        if (p.isEmpty()) throw Refused("ops dump needs a --preset")
        if (p.any { it in PRESET_WORDS } && p.size != 1) throw Refused("all / all_lite must be the only preset")
        for (x in p) {
            if (x in PRESET_WORDS) continue
            if (!PART_NAME.matches(x)) throw Refused("bad partition name: $x")
            if (x.startsWith("userdata")) throw Refused("userdata is not offered by the app")
        }
    }

    fun checkSockPath(path: String) {
        if (!path.startsWith("/")) throw Refused("socket path must be an absolute filesystem path")
        val n = path.toByteArray(Charsets.UTF_8).size
        if (n >= SUN_PATH_MAX) throw Refused("socket path is $n bytes; must be < $SUN_PATH_MAX")
    }
}
