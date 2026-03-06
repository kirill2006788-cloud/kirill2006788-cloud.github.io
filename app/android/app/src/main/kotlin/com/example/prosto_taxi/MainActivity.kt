package ru.prostotaxi.client

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun getCachedEngineId(): String = SplashActivity.ENGINE_ID
}
