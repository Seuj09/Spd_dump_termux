package io.github.seuj09.spdhost.engine

/**
 * `spdhost caps`, format 1 (no-root/src/main.c print_caps, README "spdhost caps"):
 *
 *     caps_format=1
 *     build_sha=<40 lowercase hex | unknown>
 *     protocol=<n>
 *     cap=<name>        (zero or more)
 *     end
 *
 * Same rules as menu.sh spdhost_caps: the first line must be exactly
 * caps_format=1 and the last line exactly `end`, otherwise the build has no
 * caps (an older core, a crash, truncated output). Unknown keys and unknown
 * cap names are ignored, so a newer core still parses.
 */
data class Caps(
    val buildSha: String?,
    val protocol: Int?,
    val caps: Set<String>,
) {
    fun has(cap: String) = cap in caps

    companion object {
        const val FORMAT_LINE = "caps_format=1"
        private val SHA = Regex("[0-9a-f]{40}")

        /** Null means "no caps": treat the core as having no features. */
        fun parse(output: String): Caps? {
            // Like menu.sh's $(...): trailing newlines do not count. CRLF is tolerated.
            val lines = output.replace("\r\n", "\n").trimEnd('\n').split('\n')
            if (lines.size < 2 || lines.first() != FORMAT_LINE || lines.last() != "end") return null
            var sha: String? = null
            var protocol: Int? = null
            val caps = linkedSetOf<String>()
            for (line in lines.subList(1, lines.size - 1)) {
                if (line == "end") return null // `end` only as the final line
                val eq = line.indexOf('=')
                if (eq <= 0) continue
                val key = line.substring(0, eq)
                val value = line.substring(eq + 1)
                when (key) {
                    "build_sha" -> sha = value.takeIf { SHA.matches(it) }
                    "protocol" -> protocol = value.toIntOrNull()
                    "cap" -> if (value.isNotEmpty()) caps += value
                    else -> Unit // unknown key: ignored
                }
            }
            return Caps(sha, protocol, caps)
        }
    }
}
