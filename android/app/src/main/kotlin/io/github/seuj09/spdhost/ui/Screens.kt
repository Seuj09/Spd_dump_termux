package io.github.seuj09.spdhost.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.seuj09.spdhost.BuildConfig
import io.github.seuj09.spdhost.SpdhostApp
import io.github.seuj09.spdhost.engine.CoreProbe
import io.github.seuj09.spdhost.engine.EngineGate
import io.github.seuj09.spdhost.engine.EngineState
import io.github.seuj09.spdhost.loader.LoaderPair
import io.github.seuj09.spdhost.loader.LoaderPin
import io.github.seuj09.spdhost.loader.LoaderState
import io.github.seuj09.spdhost.usb.DeviceInfo
import io.github.seuj09.spdhost.usb.UsbBroker
import io.github.seuj09.spdhost.usb.UsbState
import io.github.seuj09.spdhost.usb.device

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppRoot(app: SpdhostApp, onStart: (List<String>) -> Unit, onStop: () -> Unit, onImport: () -> Unit) {
    var showNotice by rememberSaveable { mutableStateOf(false) }
    BackHandler(enabled = showNotice) { showNotice = false }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(if (showNotice) "About / notices" else "spdhost") },
                actions = {
                    TextButton(onClick = { showNotice = !showNotice }) {
                        Text(if (showNotice) "Back" else "About")
                    }
                },
            )
        },
    ) { pad ->
        val mod = Modifier.padding(pad).fillMaxSize()
        if (showNotice) NoticeScreen(mod) else StatusScreen(app, mod, onStart, onStop, onImport)
    }
}

@Composable
private fun StatusScreen(app: SpdhostApp, modifier: Modifier, onStart: (List<String>) -> Unit, onStop: () -> Unit, onImport: () -> Unit) {
    val usb by app.broker.state.collectAsStateWithLifecycle()
    val log by app.broker.log.collectAsStateWithLifecycle()
    val core by app.core.collectAsStateWithLifecycle()
    val engine by app.engine.state.collectAsStateWithLifecycle()
    val loaders by app.loaders.state.collectAsStateWithLifecycle()
    Column(
        modifier.verticalScroll(rememberScrollState()).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        UsbCard(usb, app.broker, engine.running)
        CoreCard(core, onRetry = app::probeCore)
        EngineCard(engine, usb, core, onStart, onStop)
        LoaderCard(loaders, onImport, app.loaders::pick)
        Section("Events") {
            if (log.isEmpty()) Text("—") else Mono(log.joinToString("\n"))
        }
        Text(
            "Read-only: this build runs only the BootROM hello (ping) through the engine " +
                "service, and checks loader packs offline. No dump, write, misc or set-active.",
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

private fun headline(s: UsbState): Pair<String, Color> = when (s) {
    UsbState.NoDevice -> "No device. Plug the phone in BROM mode (1782:4d00)." to Color.Gray
    is UsbState.Multiple -> "Refused: ${s.devices.size} Spreadtrum (1782) devices attached. Unplug all but one." to Color(0xFFC62828)
    is UsbState.Unsupported -> "Spreadtrum device ${s.device.vidPid} is not in BROM mode (4d00). Not opened." to Color(0xFFEF6C00)
    is UsbState.Found -> "Device found" to Color(0xFF1565C0)
    is UsbState.PermissionRequested -> "Permission requested. Answer the system dialog." to Color(0xFF1565C0)
    is UsbState.Granted -> "Permission granted" to Color(0xFF2E7D32)
    is UsbState.Denied -> "Permission denied" to Color(0xFFC62828)
    is UsbState.Opened -> "Opened: fd ${s.fd}" to Color(0xFF2E7D32)
    is UsbState.OpenFailed -> "Open failed: ${s.reason}" to Color(0xFFC62828)
    is UsbState.Detached -> "Detached" to Color(0xFFEF6C00)
}

@Composable
private fun UsbCard(s: UsbState, broker: UsbBroker, engineRunning: Boolean) {
    Section("USB") {
        val (text, color) = headline(s)
        Text(text, color = color, fontWeight = FontWeight.Bold)
        when (s) {
            is UsbState.Multiple -> s.devices.forEach { DeviceDetails(it) }
            else -> s.device?.let { DeviceDetails(it) }
        }
        Spacer(Modifier.height(4.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            when (s) {
                is UsbState.Found, is UsbState.Denied ->
                    Button(onClick = broker::requestPermission) { Text("Request permission") }
                is UsbState.Granted, is UsbState.OpenFailed ->
                    Button(onClick = broker::open) { Text("Open") }
                is UsbState.Opened ->
                    // Never close under a running core child (P1-3).
                    OutlinedButton(onClick = broker::close, enabled = !engineRunning) { Text("Close") }
                else -> Unit
            }
            OutlinedButton(onClick = broker::rescan) { Text("Rescan") }
        }
    }
}

@Composable
private fun EngineCard(
    e: EngineState,
    usb: UsbState,
    core: CoreProbe?,
    onStart: (List<String>) -> Unit,
    onStop: () -> Unit,
) {
    Section("Engine session") {
        val gate = EngineGate.refusal(core?.caps, BuildConfig.GIT_SHA)
        val (text, color) = when {
            e.stopping -> "Stopping (SIGINT sent)…" to Color(0xFFEF6C00)
            e.running -> "Running: ${e.commands.joinToString(" ")}" to Color(0xFF1565C0)
            e.refusal != null && e.lastRc == null -> "Refused: ${e.refusal}" to Color(0xFFC62828)
            e.lastRc != null -> "Last run exited rc=${e.lastRc}" to if (e.lastRc == 0) Color(0xFF2E7D32) else Color(0xFFC62828)
            gate != null -> "Caps gate: $gate" to Color(0xFFC62828)
            usb !is UsbState.Opened -> "Open the device first" to Color.Gray
            else -> "Ready" to Color(0xFF2E7D32)
        }
        Text(text, color = color, fontWeight = FontWeight.Bold)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(
                onClick = { onStart(listOf("ping")) },
                enabled = !e.running && gate == null && usb is UsbState.Opened,
            ) { Text("BootROM hello (ping)") }
            OutlinedButton(onClick = onStop, enabled = e.running && !e.stopping) { Text("Stop") }
        }
        if (e.events.isNotEmpty()) Mono(e.events.takeLast(30).joinToString("\n"))
        if (e.log.isNotEmpty()) Mono(e.log.takeLast(30).joinToString("\n"))
    }
}

@Composable
private fun LoaderCard(s: LoaderState, onImport: () -> Unit, onPick: (LoaderPair) -> Unit) {
    Section("Loaders (fdl pack)") {
        s.message?.let { Text(it, color = if (s.error) Color(0xFFC62828) else Color.Unspecified, fontWeight = FontWeight.Bold) }
        Mono("pinned pack  ${LoaderPin.PACK_SHA256.take(16)}…\npinned index ${LoaderPin.INDEX_SHA256.take(16)}…")
        OutlinedButton(onClick = onImport, enabled = !s.busy) { Text("Import fdl-pack zip…") }
        val ix = s.index ?: return@Section
        Text("Model (pick yours; a model is used only after loaders check passes):", style = MaterialTheme.typography.bodySmall)
        ix.pairs.forEach { p ->
            val sel = s.selected == p
            val label = (if (sel) "✓ " else "") + "${p.soc} · ${p.model}"
            if (sel) Button(onClick = { onPick(p) }, enabled = !s.busy, modifier = Modifier.fillMaxWidth()) { Text(label) }
            else OutlinedButton(onClick = { onPick(p) }, enabled = !s.busy, modifier = Modifier.fillMaxWidth()) { Text(label) }
        }
        s.lastCheck?.let { v ->
            if (!v.ok) Mono("REFUSED:\n" + v.reasons.joinToString("\n"))
            else Mono(listOf("pair", "soc", "fdl1_sha256", "fdl2_sha256", "exec", "stub_sha256")
                .mapNotNull { k -> v.kv[k]?.let { "%-12s %s".format(k, it) } }.joinToString("\n"))
        }
    }
}

@Composable
private fun DeviceDetails(d: DeviceInfo) {
    val lines = buildList {
        add("vid:pid   ${d.vidPid}  (${d.vendorId}:${d.productId})")
        add("path      ${d.name}")
        d.manufacturer?.let { add("maker     $it") }
        d.product?.let { add("product   $it") }
        add("serial    ${d.serial ?: "(needs permission)"}")
        if (d.interfaces.isEmpty()) add("interfaces: none reported")
        d.interfaces.forEach { f ->
            add("iface %d class %02x/%02x/%02x".format(f.id, f.interfaceClass, f.subclass, f.protocol))
            f.endpoints.forEach { add("  $it") }
        }
    }
    Mono(lines.joinToString("\n"))
}

@Composable
private fun CoreCard(p: CoreProbe?, onRetry: () -> Unit) {
    Section("Native core (libspdhost.so caps)") {
        if (p == null) Text("running…") else CoreDetails(p, onRetry)
    }
}

@Composable
private fun CoreDetails(p: CoreProbe, onRetry: () -> Unit) {
    run {
        val caps = p.caps
        val (text, color) = when {
            !p.present -> "Not in this APK: ${p.error}" to Color(0xFFC62828)
            caps == null -> "Ran, but no valid caps (exit ${p.exitCode ?: "-"})" to Color(0xFFC62828)
            else -> "Runs on this phone (${p.elapsedMs} ms)" to Color(0xFF2E7D32)
        }
        Text(text, color = color, fontWeight = FontWeight.Bold)
        val lines = buildList {
            add("path      ${p.path}")
            if (p.present) add("size      ${p.sizeBytes} B")
            p.sha256?.let { add("sha256    $it") }
            if (caps != null) {
                add("build_sha ${caps.buildSha ?: "unknown"}")
                val match = when {
                    caps.buildSha == null || BuildConfig.GIT_SHA == "unknown" -> "cannot compare"
                    caps.buildSha == BuildConfig.GIT_SHA -> "matches the APK"
                    else -> "DIFFERS from the APK (${BuildConfig.GIT_SHA.take(7)})"
                }
                add("          $match")
                add("protocol  ${caps.protocol ?: "?"}")
                add("caps      ${caps.caps.joinToString(" ")}")
            }
            p.error?.takeIf { p.present }?.let { add("stderr    $it") }
        }
        Mono(lines.joinToString("\n"))
        if (p.present && p.caps == null && p.output.isNotEmpty()) Mono("raw output:\n${p.output}")
        OutlinedButton(onClick = onRetry) { Text("Run caps again") }
    }
}

@Composable
private fun NoticeScreen(modifier: Modifier) {
    val ctx = LocalContext.current
    val text = remember {
        runCatching { ctx.assets.open("NOTICE.txt").bufferedReader().use { it.readText() } }
            .getOrElse { "NOTICE.txt missing: ${it.message}" }
    }
    Column(modifier.verticalScroll(rememberScrollState()).padding(12.dp)) {
        Mono(
            "spdhost ${BuildConfig.VERSION_NAME} (${BuildConfig.APPLICATION_ID})\n" +
                "commit ${BuildConfig.GIT_SHA}\n" +
                "source https://github.com/Seuj09/Spd_dump_termux\n"
        )
        Spacer(Modifier.height(8.dp))
        Mono(text)
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Card(Modifier.fillMaxWidth(), colors = CardDefaults.cardColors()) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            content()
        }
    }
}

@Composable
private fun Mono(text: String) {
    SelectionContainer {
        Text(text, fontFamily = FontFamily.Monospace, fontSize = 12.sp, lineHeight = 16.sp)
    }
}
