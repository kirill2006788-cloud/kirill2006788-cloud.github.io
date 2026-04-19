package ru.nolpromille.driver

import android.app.Application
import android.util.Log

class MainApplication : Application() {
  override fun onCreate() {
    super.onCreate()

    val apiKeyPresent = BuildConfig.YANDEX_MAPS_KEY.isNotBlank()
    Log.i("MainApplication", "onCreate: yandexMapsKeyPresent=$apiKeyPresent")

    try {
      val mapKitFactoryClass = Class.forName("com.yandex.mapkit.MapKitFactory")
      mapKitFactoryClass.getMethod("setLocale", String::class.java).invoke(null, "ru_RU")

      val apiKey = BuildConfig.YANDEX_MAPS_KEY
      if (apiKey.isNotBlank()) {
        mapKitFactoryClass.getMethod("setApiKey", String::class.java).invoke(null, apiKey)
      }
    } catch (_: Throwable) {
    }
  }
}
