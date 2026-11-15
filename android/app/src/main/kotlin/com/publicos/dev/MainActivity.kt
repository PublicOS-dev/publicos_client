package com.publicos.dev

import android.content.Intent
import androidx.core.content.FileProvider
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import java.io.File
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var initialDeepLink: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Capture cold-start deep link from initial intent
        initialDeepLink = intent.data?.toString()
        intent.data = null

        // Let Dart pull the initial link when ready
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.publicos/deeplink")
            .setMethodCallHandler { call, result ->
                if (call.method == "getInitialLink") {
                    result.success(initialDeepLink)
                    initialDeepLink = null
                } else {
                    result.notImplemented()
                }
            }

        // "Open with" for received documents — hand a cached file to the user's
        // chosen app via ACTION_VIEW. The file is exposed through a FileProvider
        // (content:// URI) because file:// URIs are blocked on Android 7+.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.publicos/openfile")
            .setMethodCallHandler { call, result ->
                if (call.method == "openFile") {
                    val path = call.argument<String>("path")
                    val mime = call.argument<String>("mimeType") ?: "*/*"
                    if (path == null) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        val uri = FileProvider.getUriForFile(
                            this, "$packageName.fileprovider", File(path)
                        )
                        val view = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, mime)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        val chooser = Intent.createChooser(view, null).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(chooser)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                } else {
                    result.notImplemented()
                }
            }

        // Social push token: the SECOND Firebase
        // project's FCM token. firebase_messaging serves the default app only,
        // so the secondary app is initialised here from the options Dart
        // passes and its own FirebaseMessaging component asked for a token.
        // Delivery needs nothing more: the one messaging service in this
        // package receives both senders.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.publicos/social_push")
            .setMethodCallHandler { call, result ->
                if (call.method != "getToken") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val name = "social"
                    val app = FirebaseApp.getApps(this).firstOrNull { it.name == name }
                        ?: FirebaseApp.initializeApp(
                            this,
                            FirebaseOptions.Builder()
                                .setProjectId(call.argument<String>("projectId"))
                                .setGcmSenderId(call.argument<String>("senderId"))
                                .setApplicationId(call.argument<String>("appId")!!)
                                .setApiKey(call.argument<String>("apiKey")!!)
                                .build(),
                            name
                        )
                    app.get(FirebaseMessaging::class.java).token
                        .addOnSuccessListener { token -> result.success(token) }
                        .addOnFailureListener { e ->
                            result.error("TOKEN_FAILED", e.message, null)
                        }
                } catch (e: Exception) {
                    result.error("SOCIAL_APP_FAILED", e.message, null)
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        // Extract the deep link URL before Flutter processes the intent.
        // This prevents GoRouter from navigating via go() (which replaces
        // the stack). Instead we send it through our MethodChannel so the
        // Dart side can push() on top of the existing navigation.
        val url = intent.data?.toString()
        intent.data = null

        super.onNewIntent(intent)

        if (url != null) {
            flutterEngine?.dartExecutor?.let { executor ->
                MethodChannel(executor.binaryMessenger, "com.publicos/deeplink")
                    .invokeMethod("onDeepLink", url)
            }
        }
    }
}
