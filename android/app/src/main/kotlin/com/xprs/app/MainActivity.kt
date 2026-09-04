package com.xprs.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

// FlutterFragmentActivity, not FlutterActivity: kept for plugins that need an
// androidx FragmentActivity (and for the historical BiometricPrompt path).
// Harmless for everything else; do not downgrade without checking plugins.
class MainActivity : FlutterFragmentActivity() {
    companion object {
        // Held so the foreground service can ping Dart ('onTick') even while
        // the activity is backgrounded. Mirrors XprsApplication.bgChannel.
        var channel: MethodChannel? = null
        private const val LINKS_CHANNEL = "com.xprs.app/links"
    }

    // Deep-link plumbing: the URI a cold start was launched with (delivered to
    // Dart via getInitialLink), and the channel used to push later links.
    private var linksChannel: MethodChannel? = null
    private var initialLink: String? = null

    // Hardware inline-video playback (MediaPlayer → Flutter texture). UI
    // engine only — textures need an attached FlutterView.
    private var hwVideo: HwVideo? = null

    // Wi-Fi multicast lock: by default Android drops incoming broadcast/multicast
    // UDP to save power, which would stop the Reticulum LAN auto-peering
    // interface from RECEIVING peers' announces. Holding this lets co-located
    // devices discover each other on the same Wi-Fi.
    private var multicastLock: WifiManager.MulticastLock? = null

    private fun acquireMulticastLock() {
        if (multicastLock != null) return
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE)
                as WifiManager
            multicastLock = wifi.createMulticastLock("aurora-rns-lan").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {
        }
    }

    // Warm start (singleTop): a new deep link arrives while we're already up.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = linkFrom(intent)
        if (link != null) {
            val ch = linksChannel
            if (ch != null) ch.invokeMethod("onLink", link) else initialLink = link
        }
    }

    private fun captureLink(intent: Intent?) {
        val link = linkFrom(intent) ?: return
        initialLink = link
    }

    /** Pull a deep link out of an ACTION_VIEW intent, or null. Handled links:
     * circle invites (https://xprs.dev/circle/… and xprs://circle/…,
     * with the old xprs:// scheme still accepted)
     * and notification taps (xprs://open?wapp=…&convo=…, set by
     * BgBridge.notify so a message notification opens its conversation). */
    private fun linkFrom(intent: Intent?): String? {
        if (intent == null || intent.action != Intent.ACTION_VIEW) return null
        val data = intent.data ?: return null
        val s = data.toString()
        val ok = (data.scheme == "https" || data.scheme == "http") &&
            data.host == "xprs.dev" && (data.path?.startsWith("/circle") == true) ||
            (data.scheme == "xprs" && (data.host == "circle" || data.host == "open"))
        return if (ok) s else null
    }

    override fun onDestroy() {
        // Stop routing update calls here: without this the bridge would keep a
        // dead Activity alive and try to install from it.
        UpdateBridge.uiHandler = null
        try {
            multicastLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        multicastLock = null
        hwVideo?.dispose()
        hwVideo = null
        super.onDestroy()
    }

    /**
     * The process has ONE FlutterEngine and the Application owns it: the one
     * created at boot for the headless service, or one created right here on
     * a cold start. Either way it is cached under [XprsApplication.ENGINE_ID]
     * and handed to the framework as a HOST-PROVIDED engine.
     *
     * This used to return null on a cold start and let the framework build
     * the engine. That engine was then cached too ([XprsApplication.rememberFlutterEngine])
     * so the background service could keep it — but a FlutterFragment DESTROYS
     * an engine it created itself when the fragment goes, whatever
     * [shouldDestroyEngineWithHost] below says (that override is consulted only
     * for a host-provided engine). Backing out of the app therefore left a dead
     * engine in the cache, and the next tap on the icon attached a view to it:
     * "Cannot execute operation because FlutterJNI is not attached to native",
     * every time, until a force-stop. Creating the engine on the Application
     * side is what makes the "keep it" rule actually apply.
     *
     * A cached engine is only reused once Dart has reported `dartReady` — that
     * it owns a root widget. An engine whose `main()` died before its first
     * runApp has nothing to draw, and attaching the UI to it shows a black
     * screen that survives every reopen (only force-stop cleared it). Discard
     * that one and build a fresh one instead.
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        // Before super.onCreate: that is where the FlutterFragment is built,
        // and it must be built as a CACHED-engine fragment (see below).
        val app = application as? XprsApplication
        app?.discardDeadEngine()
        app?.ensureFlutterEngine()
        super.onCreate(savedInstanceState)
    }

    /**
     * Name the process engine as the fragment's cached engine.
     *
     * A fragment built with `withNewEngine()` carries
     * `destroy_engine_with_fragment = true` in its arguments, and destroys the
     * engine when it goes -- whether the engine came from [provideFlutterEngine]
     * or not. Only a fragment built with `withCachedEngine(id)` asks
     * [shouldDestroyEngineWithHost], and FlutterFragmentActivity builds that one
     * only when this returns an id (it reads the intent extra by default, which
     * nothing here ever set). So this is the switch the override below hangs on.
     */
    override fun getCachedEngineId(): String? =
        if (FlutterEngineCache.getInstance().get(XprsApplication.ENGINE_ID) != null)
            XprsApplication.ENGINE_ID
        else null

    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        val app = application as? XprsApplication
        app?.discardDeadEngine()
        val cache = FlutterEngineCache.getInstance()
        if (cache.get(XprsApplication.ENGINE_ID) == null) app?.ensureFlutterEngine()
        return cache.get(XprsApplication.ENGINE_ID)
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // For a pre-warmed (boot) engine, plugins were already registered when it
        // was created — calling super again double-registers and can spawn a 2nd
        // engine. Only register for a fresh engine.
        val isPreWarmed =
            FlutterEngineCache.getInstance().get(XprsApplication.ENGINE_ID) === flutterEngine
        if (!isPreWarmed) {
            super.configureFlutterEngine(flutterEngine)
        }

        // Bind process-wide native bridges once per engine. This includes the
        // bg_service channel plus BLE/WiFi transports used by the background
        // service; the Activity only attaches UI to this shared engine.
        (application as? XprsApplication)?.rememberFlutterEngine(flutterEngine)
        channel = XprsApplication.bgChannel

        // Update Center channel: the download half lives in UpdateBridge (it must
        // work on the headless engine too), and it routes the calls that need a
        // real Activity -- installing an APK, opening a settings screen -- back
        // here while we are attached. Registering our own MethodChannel under the
        // same name would silently replace the bridge's handler.
        UpdateBridge.uiHandler = { call, result -> handleUpdate(call, result) }

        // Deep links (xprs.dev/circle/<key>): expose the launch URI and push
        // any later ones (onNewIntent) to Dart's DeepLinkService.
        linksChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LINKS_CHANNEL)
            .also { ch ->
                ch.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "getInitialLink" -> { result.success(initialLink); initialLink = null }
                        else -> result.notImplemented()
                    }
                }
            }
        // Capture the URI this activity was (re)started with.
        captureLink(intent)

        // Hardware video decode into Flutter textures. flutterEngine.renderer
        // implements TextureRegistry. Re-registering after an activity restart
        // replaces the channel handler (old players were disposed above).
        hwVideo?.dispose()
        hwVideo = HwVideo(flutterEngine.renderer, flutterEngine.dartExecutor.binaryMessenger)

        // Allow receiving LAN broadcast/multicast (Reticulum LAN auto-peering).
        acquireMulticastLock()
    }

    /**
     * The Activity-only half of the update channel, reached from
     * [UpdateBridge] while this Activity is attached. Returns false for a
     * method we do not handle so the bridge can answer for itself.
     */
    private fun handleUpdate(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "installApk" -> {
                val path = call.argument<String>("filePath")
                if (path == null) {
                    result.error("ARG", "filePath required", null); return true
                }
                result.success(installApk(path))
            }
            "canInstallPackages" -> result.success(canInstallPackages())
            "openInstallPermissionSettings" -> {
                openInstallPermissionSettings(); result.success(true)
            }
            "startDownloadService" -> {
                val text = call.argument<String>("text") ?: "Downloading update"
                DownloadForegroundService.start(this, text); result.success(true)
            }
            "updateDownloadProgress" -> {
                val p = call.argument<Int>("progress") ?: 0
                val s = call.argument<String>("status") ?: "Downloading…"
                DownloadForegroundService.updateProgress(this, p, s)
                result.success(true)
            }
            "stopDownloadService" -> {
                DownloadForegroundService.stop(this); result.success(true)
            }
            // Battery-optimization (Doze) exemption — required on aggressive OEMs
            // so the foreground service + APRS-IS connection + Blossom/seed
            // servers survive deep sleep instead of being killed.
            "isIgnoringBatteryOptimizations" -> result.success(isIgnoringBattery())
            "requestIgnoreBatteryOptimizations" -> {
                requestIgnoreBattery(); result.success(true)
            }
            "openFolder" -> {
                val path = call.argument<String>("path")
                if (path == null) { result.error("ARG", "path required", null) }
                else result.success(openFolder(path))
            }
            "openFile" -> {
                val path = call.argument<String>("path")
                if (path == null) { result.error("ARG", "path required", null) }
                else result.success(openFile(path))
            }
            else -> return false
        }
        return true
    }

    private fun isIgnoringBattery(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
            pm.isIgnoringBatteryOptimizations(packageName)
        } else {
            true
        }

    private fun requestIgnoreBattery() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || isIgnoringBattery()) return
        try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName"),
                ),
            )
        } catch (_: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            } catch (_: Exception) {
            }
        }
    }

    private fun canInstallPackages(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            packageManager.canRequestPackageInstalls()
        else true

    private fun openInstallPermissionSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                    .setData(Uri.parse("package:$packageName"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    /** Open a folder on external storage in the system Files / a file manager so
     * the user can edit its contents directly. Maps the absolute path to a
     * Documents-UI directory URI; falls back to the primary-storage root. */
    private fun openFolder(path: String): Boolean {
        val rel = when {
            path.startsWith("/storage/emulated/0/") -> path.removePrefix("/storage/emulated/0/")
            path.startsWith("/sdcard/") -> path.removePrefix("/sdcard/")
            path == "/storage/emulated/0" || path == "/sdcard" -> ""
            else -> null
        }
        // Primary: ACTION_VIEW on the directory document URI (most file managers).
        if (rel != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val uri = DocumentsContract.buildDocumentUri(
                    "com.android.externalstorage.documents", "primary:$rel",
                )
                startActivity(
                    Intent(Intent.ACTION_VIEW)
                        .setDataAndType(uri, DocumentsContract.Document.MIME_TYPE_DIR)
                        .addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                        ),
                )
                return true
            } catch (_: Exception) {
            }
        }
        // Fallback: open the Files app at the primary-storage root.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val root = DocumentsContract.buildRootUri(
                    "com.android.externalstorage.documents", "primary",
                )
                startActivity(
                    Intent(Intent.ACTION_VIEW)
                        .setData(root)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                return true
            } catch (_: Exception) {
            }
        }
        return false
    }


    /**
     * Hand ONE file to whatever app views that type: a photo to the gallery, a
     * PDF to a reader, a video to a player. An .apk is not "viewed" — it is
     * INSTALLED, and that path already exists (with its own permission gate), so
     * it is routed there rather than opening a chooser that leads nowhere.
     *
     * A raw file:// URI is refused by the platform since API 24, so this goes
     * through the same FileProvider the updater uses.
     */
    private fun openFile(filePath: String): Boolean {
        return try {
            val file = File(filePath)
            if (!file.exists() || file.length() == 0L) return false
            if (file.extension.lowercase() == "apk") return installApk(filePath)

            val ext = file.extension.lowercase()
            val mime = android.webkit.MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(ext) ?: "*/*"
            val uri = FileProvider.getUriForFile(
                this, "$packageName.fileprovider", file,
            )
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, mime)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            // No app for this type is a normal outcome (a .bin, a .tar), not a
            // crash: say so and let the caller tell the user.
            if (intent.resolveActivity(packageManager) == null) {
                val chooser = Intent.createChooser(intent, file.name)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (chooser.resolveActivity(packageManager) == null) return false
                startActivity(chooser)
                return true
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun installApk(filePath: String): Boolean {
        return try {
            val file = File(filePath)
            if (!file.exists() || file.length() < 1000) return false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()
            ) {
                openInstallPermissionSettings()
                return false
            }
            val intent = Intent(Intent.ACTION_VIEW).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                val uri = FileProvider.getUriForFile(
                    this, "$packageName.fileprovider", file,
                )
                intent.setDataAndType(uri, "application/vnd.android.package-archive")
                intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } else {
                intent.setDataAndType(
                    Uri.fromFile(file), "application/vnd.android.package-archive",
                )
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "installApk failed: ${e.message}")
            false
        }
    }
}
