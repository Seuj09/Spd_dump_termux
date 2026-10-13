package io.github.seuj09.spdhost.engine

import io.github.seuj09.spdhost.loader.LoaderIndex
import io.github.seuj09.spdhost.loader.LoaderPair

/**
 * Builds the P1-5 session commands the way menu.sh's run_session does
 * (E2): `--timeout 3000 [--keep-going] exec_addr EA STUB fdl F1 A1 fdl F2 A2 …`.
 * The menu passes the side-file folder as SPDHOST_PART_XML_DIR; the app's env
 * whitelist strips those, so it passes the same folder as `--part-xml DIR/meta`
 * (ops.c: "the APK passes --part-xml DIR/meta"). Every result goes through
 * [EngineArgv.validate].
 */
object SessionArgs {
    const val TIMEOUT_MS = "3000"

    enum class Ending(val word: String, val label: String) { RESET("reset", "Reset (reboot)"), POWER_OFF("power-off", "Power off") }

    /** What to dump: one partition, all_lite or all. */
    sealed class Preset(val words: List<String>) {
        class One(name: String) : Preset(listOf(name))
        object AllLite : Preset(listOf("all_lite"))
        object All : Preset(listOf("all"))
    }

    fun loaders(root: String, ix: LoaderIndex, pair: LoaderPair): List<String> {
        val dir = "$root/fdl"
        val soc = ix.socs[pair.soc] ?: throw EngineArgv.Refused("unknown soc ${pair.soc}")
        val stub = ix.stubs[pair.soc]
        val ea = if (soc.stub != null && stub != null) listOf("exec_addr", soc.stub, "$dir/$stub") else emptyList()
        return ea + listOf("fdl", "$dir/${pair.fdl1}", soc.fdl1, "fdl", "$dir/${pair.fdl2}", soc.fdl2)
    }

    fun meta(dumpDir: String) = "$dumpDir/meta"
    fun partsFile(dumpDir: String) = "${meta(dumpDir)}/partition_list.txt"

    /** BootROM hello: menu.sh `run_session ping` -> `--timeout 3000 ping` (E2 golden hello). */
    fun hello(): List<String> = listOf("--timeout", TIMEOUT_MS, "ping").also(EngineArgv::validate)

    fun parts(loaders: List<String>, dumpDir: String, ending: Ending): List<String> =
        (listOf("--timeout", TIMEOUT_MS, "--part-xml", meta(dumpDir)) + loaders +
            listOf("parts", partsFile(dumpDir), ending.word)).also(EngineArgv::validate)

    fun dump(loaders: List<String>, dumpDir: String, preset: Preset, ending: Ending): List<String> =
        (listOf("--timeout", TIMEOUT_MS, "--keep-going", "--part-xml", meta(dumpDir)) + loaders +
            listOf("ops", "dump", dumpDir) + preset.words.flatMap { listOf("--preset", it) } +
            ending.word).also(EngineArgv::validate)

    /**
     * Folders that must exist before the session (Debugger #30 leftover 1):
     * `ops dump` / `parts` do not create the `--part-xml` folder themselves.
     */
    fun dirsToCreate(commands: List<String>): List<String> {
        val i = commands.indexOf("--part-xml")
        return if (i >= 0 && i + 1 < commands.size) listOf(commands[i + 1]) else emptyList()
    }
}
