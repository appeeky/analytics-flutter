package com.appeeky.analytics

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Native side of appeeky_analytics on Android: the Play Install Referrer,
 * the data URI of the Intent that opened the app, and device fields.
 * Everything else runs in Dart.
 */
class AppeekyAnalyticsPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.NewIntentListener {

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var activityBinding: ActivityPluginBinding? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        /** The first URI that opened the app; kept for the process lifetime. */
        @Volatile
        private var launchUrl: String? = null

        private fun record(intent: Intent?) {
            val data = intent?.dataString ?: return
            if (launchUrl == null) launchUrl = data
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "appeeky_analytics").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        record(binding.activity.intent)
        binding.addOnNewIntentListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }

    override fun onNewIntent(intent: Intent): Boolean {
        record(intent)
        // Not handled: other plugins and the app still get the intent.
        return false
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getLaunchUrl" -> result.success(launchUrl)
            "getInstallReferrer" -> installReferrer(result)
            "getDeviceContext" -> result.success(deviceContext())
            "getAdServicesToken", "updateConversionValue" -> result.success(null)
            else -> result.notImplemented()
        }
    }

    private fun installReferrer(result: MethodChannel.Result) {
        val ctx = context
        if (ctx == null) {
            result.success(null)
            return
        }
        var settled = false
        fun settle(value: String?) {
            mainHandler.post {
                if (settled) return@post
                settled = true
                result.success(value)
            }
        }
        try {
            val client = InstallReferrerClient.newBuilder(ctx).build()
            client.startConnection(object : InstallReferrerStateListener {
                override fun onInstallReferrerSetupFinished(responseCode: Int) {
                    try {
                        if (responseCode == InstallReferrerClient.InstallReferrerResponse.OK) {
                            settle(client.installReferrer.installReferrer)
                        } else {
                            settle(null)
                        }
                    } catch (e: Exception) {
                        settle(null)
                    } finally {
                        try {
                            client.endConnection()
                        } catch (_: Exception) {
                        }
                    }
                }

                override fun onInstallReferrerServiceDisconnected() {
                    settle(null)
                }
            })
        } catch (e: Exception) {
            settle(null)
        }
    }

    private fun deviceContext(): Map<String, String?> {
        val out = mutableMapOf<String, String?>(
            "osVersion" to Build.VERSION.RELEASE,
            "deviceModel" to Build.MODEL,
        )
        val ctx = context ?: return out
        try {
            val info = if (Build.VERSION.SDK_INT >= 33) {
                ctx.packageManager.getPackageInfo(ctx.packageName, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                ctx.packageManager.getPackageInfo(ctx.packageName, 0)
            }
            out["appVersion"] = info.versionName
            out["build"] = if (Build.VERSION.SDK_INT >= 28) {
                info.longVersionCode.toString()
            } else {
                @Suppress("DEPRECATION")
                info.versionCode.toString()
            }
        } catch (e: Exception) {
            // Leave app version out.
        }
        return out
    }
}
