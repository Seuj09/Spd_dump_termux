package io.github.seuj09.spdhost.engine

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** What the screen shows about the engine. Process-wide (SpdhostApp). */
data class EngineState(
    val running: Boolean = false,
    val stopping: Boolean = false,
    val commands: List<String> = emptyList(),
    val lastRc: Int? = null,
    val refusal: String? = null,
    val log: List<String> = emptyList(),
    val events: List<String> = emptyList(),
)

class EngineController {
    private val _state = MutableStateFlow(EngineState())
    val state: StateFlow<EngineState> = _state.asStateFlow()

    @Volatile var session: EngineSession? = null

    fun log(msg: String) = _state.update { it.copy(log = (it.log + stamp(msg)).takeLast(200)) }
    fun event(e: EngineEvent) = _state.update { it.copy(events = (it.events + stamp(e.summary())).takeLast(200)) }
    fun refused(why: String) = _state.update { it.copy(running = false, refusal = why, log = (it.log + stamp("refused: $why")).takeLast(200)) }
    fun started(cmds: List<String>) = _state.update { EngineState(running = true, commands = cmds, log = it.log.takeLast(50)) }
    fun stopping() = _state.update { it.copy(stopping = true) }
    fun exited(rc: Int?) = _state.update { it.copy(running = false, stopping = false, lastRc = rc) }

    private fun stamp(s: String) =
        java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.US).format(java.util.Date()) + " " + s
}
