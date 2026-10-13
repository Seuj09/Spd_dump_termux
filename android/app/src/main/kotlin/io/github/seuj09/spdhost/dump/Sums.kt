package io.github.seuj09.spdhost.dump

/**
 * meta/SHA256SUMS as the core writes it (ops.c: "<hex>  NAME", NAME relative
 * to the dump folder). An older flat dump keeps it at DIR/SHA256SUMS.
 * Unknown or malformed lines are skipped; a file with no line is "unverified"
 * and is never exported as verified.
 */
object Sums {
    private val LINE = Regex("^([0-9a-fA-F]{64}) [ *](.+)$")

    fun parse(text: String): Map<String, String> {
        val m = LinkedHashMap<String, String>()
        text.lineSequence().forEach { raw ->
            val r = LINE.find(raw.trimEnd('\r')) ?: return@forEach
            val name = r.groupValues[2].removePrefix("./")
            if (name.isEmpty() || name.startsWith("/") || name.split('/').any { it == ".." || it == "." }) return@forEach
            m[name] = r.groupValues[1].lowercase()
        }
        return m
    }
}
