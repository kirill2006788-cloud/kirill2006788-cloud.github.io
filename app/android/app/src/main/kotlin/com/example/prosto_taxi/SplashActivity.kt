package ru.prostotaxi.client

import android.content.Intent
import android.net.Uri
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.VideoView
import android.app.Activity
import androidx.core.view.WindowCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

class SplashActivity : Activity() {
    companion object {
        private const val TAG = "SplashActivity"
        const val ENGINE_ID = "main_engine"
    }

    private val minDurationMs = 2000L
    private val maxDurationMs = 12000L
    private val handler = Handler(Looper.getMainLooper())
    private var startedAt = 0L
    private var finished = false
    private var flutterReady = false

    private val timeoutRunnable = Runnable {
        Log.w(TAG, "timeout reached — forcing transition")
        goToMain()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setVolumeControlStream(AudioManager.STREAM_MUSIC)
        // Убираем чёрные полосы сверху/снизу — контент под системными барами, фон #05060A
        WindowCompat.setDecorFitsSystemWindows(window, false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            window.statusBarColor = 0xFF05060A.toInt()
            window.navigationBarColor = 0xFF05060A.toInt()
        }
        setContentView(R.layout.activity_splash)

        startedAt = SystemClock.elapsedRealtime()

        // ── 1. Pre-warm Flutter engine while video plays ──
        val engine = FlutterEngine(this)
        GeneratedPluginRegistrant.registerWith(engine)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)

        // Listen for "ready" signal from Dart
        MethodChannel(engine.dartExecutor.binaryMessenger, "com.prosto_taxi/splash")
            .setMethodCallHandler { call, result ->
                if (call.method == "ready") {
                    Log.d(TAG, "Flutter app reports ready")
                    flutterReady = true
                    tryGoToMain()
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }

        // ── 2. Сразу запускаем видео (если ресурса нет, показываем постер/фон)
        val videoView = findViewById<VideoView>(R.id.splashVideo)
        val posterView = findViewById<ImageView>(R.id.splashPoster)

        videoView.setZOrderMediaOverlay(true)

        val splashRawId = resources.getIdentifier("splash_video", "raw", packageName)
        val splashPosterId = resources.getIdentifier("splash_poster", "drawable", packageName)
        if (splashPosterId != 0) {
            posterView.setImageResource(splashPosterId)
            posterView.visibility = View.VISIBLE
        }
        if (splashRawId == 0) {
            Log.w(TAG, "splash_video not found in res/raw, using poster-only fallback")
            handler.removeCallbacks(timeoutRunnable)
            handler.postDelayed(timeoutRunnable, minDurationMs + 600)
            return
        }

        val uri = Uri.parse("android.resource://$packageName/$splashRawId")
        Log.d(TAG, "setVideoURI=$uri")
        videoView.setVideoURI(uri)

        videoView.setOnPreparedListener { mp ->
            startedAt = SystemClock.elapsedRealtime()
            Log.d(TAG, "onPrepared video=${mp.videoWidth}x${mp.videoHeight} durationMs=${mp.duration}")
            mp.isLooping = false
            mp.setVolume(1f, 1f)

            handler.removeCallbacks(timeoutRunnable)
            handler.postDelayed(timeoutRunnable, maxDurationMs)

            // Масштаб «cover» — видео на весь экран без чёрных полос
            videoView.post {
                val videoW = mp.videoWidth.toFloat()
                val videoH = mp.videoHeight.toFloat()
                val viewW = videoView.width.toFloat()
                val viewH = videoView.height.toFloat()
                if (videoW > 0f && videoH > 0f && viewW > 0f && viewH > 0f) {
                    val scale = maxOf(viewW / videoW, viewH / videoH)
                    val scaledW = (videoW * scale).toInt()
                    val scaledH = (videoH * scale).toInt()
                    Log.d(TAG, "scale cover: video=${videoW.toInt()}x${videoH.toInt()} view=${viewW.toInt()}x${viewH.toInt()} -> scaled=${scaledW}x${scaledH}")
                    val lp = videoView.layoutParams as FrameLayout.LayoutParams
                    lp.width = scaledW
                    lp.height = scaledH
                    lp.gravity = Gravity.CENTER
                    videoView.layoutParams = lp
                }
            }

            Log.d(TAG, "start video immediately")
            posterView.visibility = View.GONE
            videoView.start()
        }

        videoView.setOnCompletionListener {
            Log.d(TAG, "onCompletion")
            handler.removeCallbacks(timeoutRunnable)
            // Video finished — if Flutter is ready, go now; otherwise wait for it
            tryGoToMain()
        }

        videoView.setOnErrorListener { _, what, extra ->
            Log.e(TAG, "onError what=$what extra=$extra")
            posterView.visibility = View.VISIBLE
            handler.removeCallbacks(timeoutRunnable)
            tryGoToMain()
            true
        }

        // Safety timeout in case video never starts
        handler.postDelayed(timeoutRunnable, maxDurationMs)
    }

    /**
     * Transition as soon as Flutter is ready AND minimum splash time has passed.
     * If Flutter is ready but min time hasn't elapsed — schedule a delayed check.
     * If video finished but Flutter isn't ready — wait (timeout is the safety net).
     */
    private fun tryGoToMain() {
        if (finished) return
        val elapsed = SystemClock.elapsedRealtime() - startedAt

        if (!flutterReady) {
            // Flutter not ready yet — keep waiting (timeout will catch)
            Log.d(TAG, "tryGoToMain: flutter not ready yet, elapsedMs=$elapsed")
            return
        }

        if (elapsed < minDurationMs) {
            // Flutter ready but min time not reached — schedule transition
            val delay = minDurationMs - elapsed + 50
            Log.d(TAG, "tryGoToMain: flutter ready, waiting ${delay}ms for minDuration")
            handler.postDelayed({ tryGoToMain() }, delay)
            return
        }

        // Both conditions met — go!
        Log.d(TAG, "tryGoToMain: all clear, elapsedMs=$elapsed — transitioning")
        goToMain()
    }

    private fun goToMain() {
        if (finished) return
        finished = true
        handler.removeCallbacksAndMessages(null)
        startActivity(Intent(this, MainActivity::class.java))
        finish()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }
}
