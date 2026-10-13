package io.github.seuj09.spdhost.ui

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.runtime.LaunchedEffect
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
import io.github.seuj09.spdhost.engine.EngineArgv
import io.github.seuj09.spdhost.engine.EngineGate
import io.github.seuj09.spdhost.dump.Exporter
import io.github.seuj09.spdhost.engine.EngineState
import io.github.seuj09.spdhost.engine.SessionArgs
import io.github.seuj09.spdhost.dump.DumpState
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
        val dumps by app.dumps.state.collectAsStateWithLifecycle()
        LaunchedEffect(engine.running) { if (!engine.running) app.dumps.refresh() }
        DumpCard(app, dumps, engine, usb, core, loaders, onStart)
        Section("Events") {
            if (log.isEmpty()) Text("—") else Mono(log.joinToString("\n"))
        }
        Text(
            "Read-only: BootROM hello, partition table, dumps into the app's own folder, then " +
                "reset or power-off. No write, misc or set-active.",
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
                onClick = { onStart(SessionArgs.hello()) },
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

/**
 * P1-5: hello is the Engine card's ping; here: read the partition table
 * (`parts`), dump one / all_lite / all with `ops dump` into
 * getExternalFilesDir()/dumps/<time>, ending reset or power-off. Every session
 * runs the picked model's loaders (selected only after `loaders check`).
 */
@Composable
private fun DumpCard(
    app: SpdhostApp, d: DumpState, e: EngineState, usb: UsbState, core: CoreProbe?,
    loaders: LoaderState, onStart: (List<String>) -> Unit,
) {
    Section("Partition table and dump") {
        var ending by rememberSaveable { mutableStateOf(SessionArgs.Ending.RESET) }
        var one by rememberSaveable { mutableStateOf<String?>(null) }
        var showJson by rememberSaveable { mutableStateOf(false) }
        val caps = core?.caps?.caps.orEmpty()
        val pair = loaders.selected
        val ix = loaders.index
        val why = when {
            e.running -> "a session is running"
            usb !is UsbState.Opened -> "open the device first"
            pair == null || ix == null -> "pick a model (loaders check must pass)"
            "ops-dump" !in caps -> "this core has no ops-dump cap"
            else -> null
        }
        Text("Folder: ${d.dir?.absolutePath ?: "(created on first run)"}", style = MaterialTheme.typography.bodySmall)
        d.message?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        why?.let { Text(it, color = Color.Gray) }
        Text("Ending after the session:")
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SessionArgs.Ending.values().forEach { en ->
                if (en == ending) Button(onClick = {}) { Text(en.label) }
                else OutlinedButton(onClick = { ending = en }) { Text(en.label) }
            }
        }
        fun go(build: (List<String>, String) -> List<String>) {
            val dir = app.dumps.dir() ?: return
            val l = SessionArgs.loaders(app.loaders.root.absolutePath, ix!!, pair!!)
            runCatching { build(l, dir.absolutePath) }
                .onSuccess(onStart).onFailure { app.engine.refused(it.message ?: "refused") }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = { go { l, dir -> SessionArgs.parts(l, dir, ending) } }, enabled = why == null) { Text("Read partition table") }
            OutlinedButton(onClick = { app.dumps.newFolder() }, enabled = !e.running) { Text("New folder") }
        }
        val table = d.table
        // P1-5 note 3: a pick that is no longer a row of the current table is cleared.
        LaunchedEffect(d.dir, table) { if (one != null && table?.names?.contains(one) != true) one = null }
        if (table != null) {
            Text("Table: ${table.rows.size} rows, unit shift ${table.shift ?: "?"}, " +
                if (table.verified) "sizes verified" else "sizes NOT verified (estimate)")
            OutlinedButton(onClick = { showJson = !showJson }) { Text(if (showJson) "Hide JSON" else "Show table JSON") }
            if (showJson) Mono(table.toJson())
            Text("Dump one partition:", style = MaterialTheme.typography.bodySmall)
            table.rows.forEach { r ->
                val label = "${r.index} ${r.name}" + (r.bytes?.let { " · ${it shr 20} MiB" } ?: "")
                if (r.name.startsWith("userdata")) return@forEach
                // P1-5 note 2: rows the app's name rule refuses are shown greyed out with the reason.
                if (!EngineArgv.partNameOk(r.name)) {
                    OutlinedButton(onClick = {}, enabled = false, modifier = Modifier.fillMaxWidth()) {
                        Text("$label (name not allowed: letters, digits, _ only)")
                    }
                    return@forEach
                }
                if (one == r.name) Button(onClick = { one = null }, modifier = Modifier.fillMaxWidth()) { Text("✓ $label") }
                else OutlinedButton(onClick = { one = r.name }, modifier = Modifier.fillMaxWidth()) { Text(label) }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = { one?.let { n -> go { l, dir -> SessionArgs.dump(l, dir, SessionArgs.Preset.One(n), ending) } } },
                enabled = why == null && one != null) { Text("Dump ${one ?: "one"}") }
            Button(onClick = { go { l, dir -> SessionArgs.dump(l, dir, SessionArgs.Preset.AllLite, ending) } }, enabled = why == null) { Text("all_lite") }
            Button(onClick = { go { l, dir -> SessionArgs.dump(l, dir, SessionArgs.Preset.All, ending) } }, enabled = why == null) { Text("all") }
        }
        val v = e.view
        val lines = buildList {
            v.hello?.let { add(it) }
            v.stage?.let { add("stage $it") }
            v.progress?.let { add(it) }
            v.preflight?.let { add(it.text()) }
            v.files.forEach { f -> add("%-10s %-14s %s".format(f.state, f.name, f.bytes?.let { "${it shr 20} MiB" } ?: "")) }
            v.dumpResult?.let { add(it) }
            v.otherOp?.let { add("other op: $it") }
        }
        if (lines.isNotEmpty()) Mono(lines.joinToString("\n"))
        val imgs = d.images
        if (imgs != null) {
            val shown = imgs.filterBy(table)
            Text("Images in this folder (images list --json, filtered by the table): ${shown.size} of ${imgs.images.size}",
                style = MaterialTheme.typography.bodySmall)
            if (shown.isNotEmpty()) Mono(shown.joinToString("\n") { "%-14s %8d MiB %s".format(it.name, it.bytes shr 20, it.sha256?.take(12) ?: "no sha") })

            ExportBlock(app, d, shown, e.running)
        }
        if (d.partials.isNotEmpty()) {
            Text("Unfinished files (cancelled or failed dump, not exported):", color = Color(0xFFB00020),
                style = MaterialTheme.typography.bodySmall)
            Mono(d.partials.joinToString("\n") { "PARTIAL  $it" })
            if (d.partials.any { it.endsWith(".partial") })
                OutlinedButton(onClick = { app.dumps.deletePartials() }, enabled = !e.running) { Text("Delete *.partial files") }
        }
    }
}

/**
 * P1-6: SAF export of the table-filtered images (images list --json). Each file
 * is opened with "rwt" and verified against meta/SHA256SUMS while copied.
 */
@Composable
private fun ExportBlock(app: SpdhostApp, d: DumpState, shown: List<io.github.seuj09.spdhost.dump.ImageFile>, running: Boolean) {
    val ex by app.exports.state.collectAsStateWithLifecycle()
    val dir = d.dir
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri != null && dir != null) app.exports.export(uri, dir, shown)
    }
    val big = shown.filter { Exporter.needsFat32Warning(it.bytes) }
    if (big.isNotEmpty()) Text(
        "Warning: ${big.joinToString { it.name }} ${if (big.size == 1) "is" else "are"} 4 GiB or larger. " +
            "A FAT32 SD card or USB stick cannot hold such a file; pick exFAT/internal storage.",
        color = Color(0xFFB00020), style = MaterialTheme.typography.bodySmall)
    OutlinedButton(onClick = { pick.launch(null) }, enabled = dir != null && shown.isNotEmpty() && !running && !ex.running) {
        Text(if (ex.running) "Exporting…" else "Export (verify against SHA256SUMS)")
    }
    // #39 S3: after a tap the button says so and stays disabled until the worker stops.
    if (ex.running) OutlinedButton(onClick = { app.exports.cancel() }, enabled = !ex.cancelling) {
        Text(if (ex.cancelling) "Cancelling…" else "Cancel export")
    }
    if (ex.lines.isNotEmpty()) Mono(ex.lines.joinToString("\n"))
}
