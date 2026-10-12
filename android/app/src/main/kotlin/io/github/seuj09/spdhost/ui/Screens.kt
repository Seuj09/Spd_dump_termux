package io.github.seuj09.spdhost.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppRoot(app: SpdhostApp) {
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
        if (showNotice) NoticeScreen(mod) else StatusScreen(app, mod)
    }
}

@Composable
private fun StatusScreen(app: SpdhostApp, modifier: Modifier) {
    val core by app.core.collectAsStateWithLifecycle()
    Column(
        modifier.verticalScroll(rememberScrollState()).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        CoreCard(core, onRetry = app::probeCore)
        Text(
            "Skeleton (P1-1): runs only `libspdhost.so caps`. USB detection comes in P1-2; " +
                "the engine service (fd hand-off, hello, dump) in P1-3. No writes in P1.",
            style = MaterialTheme.typography.bodySmall,
        )
    }
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
