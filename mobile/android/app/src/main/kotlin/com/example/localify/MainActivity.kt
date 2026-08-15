package com.example.localify

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import androidx.annotation.Keep

@Keep
interface ProgressCallback {
    fun invoke(status: String, percent: Double)
}

@Keep
interface StringCallback {
    fun invoke(value: String)
}

class MainActivity: AudioServiceActivity() {
    private val CHANNEL = "com.example.localify/downloader"

    @Synchronized
    private fun ensurePythonStarted() {
        if (!Python.isStarted()) {
            Python.start(AndroidPlatform(context))
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "authenticateSpotify" -> {
                    val credsDir = context.getExternalFilesDir(null)?.absolutePath ?: context.filesDir.absolutePath
                    val credsPath = "$credsDir/credentials.json"
                    
                    val urlCallback = object : StringCallback {
                        override fun invoke(value: String) {
                            Handler(Looper.getMainLooper()).post {
                                MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).invokeMethod("onAuthUrl", value)
                            }
                        }
                    }
                    
                    val successCallback = object : StringCallback {
                        override fun invoke(value: String) {
                            Handler(Looper.getMainLooper()).post {
                                result.success(value)
                            }
                        }
                    }
                    
                    val errorCallback = object : StringCallback {
                        override fun invoke(value: String) {
                            Handler(Looper.getMainLooper()).post {
                                result.error("AUTH_ERROR", value, null)
                            }
                        }
                    }
                    
                    // Roda a chamada do Chaquopy em background thread e com Lazy Init para economizar RAM na inicialização
                    Thread {
                        try {
                            ensurePythonStarted()
                            val py = Python.getInstance()
                            val loginModule = py.getModule("login")
                            loginModule.callAttr("authenticate_spotify", credsPath, urlCallback, successCallback, errorCallback)
                        } catch (e: Exception) {
                            Handler(Looper.getMainLooper()).post {
                                result.error("CHAQUOPY_ERROR", e.message, null)
                            }
                        }
                    }.start()
                }
                "downloadTrack" -> {
                    val spotifyId = call.argument<String>("spotify_id") ?: return@setMethodCallHandler result.error("INVALID_ARG", "spotify_id is missing", null)
                    val credsDir = context.getExternalFilesDir(null)?.absolutePath ?: context.filesDir.absolutePath
                    val credsPath = "$credsDir/credentials.json"
                    val outputDir = call.argument<String>("output_dir") ?: return@setMethodCallHandler result.error("INVALID_ARG", "output_dir is missing", null)
                    val tmpFilename = call.argument<String>("tmp_filename") ?: return@setMethodCallHandler result.error("INVALID_ARG", "tmp_filename is missing", null)
                    val audioQuality = call.argument<String>("audio_quality") ?: "high"
                    
                    val progressCallback = object : ProgressCallback {
                        override fun invoke(status: String, percent: Double) {
                            Handler(Looper.getMainLooper()).post {
                                MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).invokeMethod("onProgress", mapOf("status" to status, "percent" to percent, "track_id" to spotifyId))
                            }
                        }
                    }
                    
                    val successCallback = object : StringCallback {
                        override fun invoke(value: String) {
                            Handler(Looper.getMainLooper()).post {
                                result.success(value)
                            }
                        }
                    }
                    
                    val errorCallback = object : StringCallback {
                        override fun invoke(value: String) {
                            Handler(Looper.getMainLooper()).post {
                                result.error("DOWNLOAD_ERROR", value, null)
                            }
                        }
                    }
                    
                    // Roda o download em background thread com Lazy Init em Kotlin
                    Thread {
                        try {
                            ensurePythonStarted()
                            val py = Python.getInstance()
                            val downloaderModule = py.getModule("downloader")
                            downloaderModule.callAttr(
                                "download_track",
                                spotifyId,
                                credsPath,
                                outputDir,
                                tmpFilename,
                                progressCallback,
                                successCallback,
                                errorCallback,
                                audioQuality
                            )
                        } catch (e: Exception) {
                            Handler(Looper.getMainLooper()).post {
                                result.error("CHAQUOPY_ERROR", e.message, null)
                            }
                        }
                    }.start()
                }
                "closeSession" -> {
                    Thread {
                        try {
                            ensurePythonStarted()
                            val py = Python.getInstance()
                            val downloaderModule = py.getModule("downloader")
                            downloaderModule.callAttr("close_session")
                            Handler(Looper.getMainLooper()).post {
                                result.success(null)
                            }
                        } catch (e: Exception) {
                            Handler(Looper.getMainLooper()).post {
                                result.error("CHAQUOPY_ERROR", e.message, null)
                            }
                        }
                    }.start()
                }
                "checkAuth" -> {
                    val credsDir = context.getExternalFilesDir(null)?.absolutePath ?: context.filesDir.absolutePath
                    val credsPath = "$credsDir/credentials.json"
                    val exists = java.io.File(credsPath).exists()
                    result.success(exists)
                }
                "deleteCredentials" -> {
                    val credsDir = context.getExternalFilesDir(null)?.absolutePath ?: context.filesDir.absolutePath
                    val credsPath = "$credsDir/credentials.json"
                    val file = java.io.File(credsPath)
                    if (file.exists()) file.delete()
                    result.success(true)
                }
                "saveCredentials" -> {
                    val jsonContent = call.argument<String>("json")
                    if (jsonContent.isNullOrEmpty()) {
                        result.error("INVALID_ARG", "json content is empty", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val credsDir = context.getExternalFilesDir(null)?.absolutePath ?: context.filesDir.absolutePath
                        val credsPath = "$credsDir/credentials.json"
                        val file = java.io.File(credsPath)
                        file.writeText(jsonContent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SAVE_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
