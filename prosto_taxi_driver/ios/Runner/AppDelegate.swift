import Flutter
import UIKit
import UserNotifications
import YandexMapsMobile

@main
@objc class AppDelegate: FlutterAppDelegate, UNUserNotificationCenterDelegate {
  private let pushChannelName = "ru.nolpromille.driver/push"
  private let pushTokenStorageKey = "ru.nolpromille.driver.pushToken"
  private var pushChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self

    if let key = Bundle.main.object(forInfoDictionaryKey: "YANDEX_MAPS_KEY") as? String, !key.isEmpty {
      YMKMapKit.setLocale("ru_RU")
      YMKMapKit.setApiKey(key)
    }

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: pushChannelName, binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self else {
          result(FlutterError(code: "push_unavailable", message: "Push channel not ready", details: nil))
          return
        }

        switch call.method {
        case "requestPushPermissions":
          self.requestPushPermissions(result: result)
        case "getPushToken":
          result(UserDefaults.standard.string(forKey: self.pushTokenStorageKey))
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      pushChannel = channel
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func requestPushPermissions(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
      if let error {
        result(FlutterError(code: "push_permission_error", message: error.localizedDescription, details: nil))
        return
      }

      DispatchQueue.main.async {
        UIApplication.shared.registerForRemoteNotifications()
        let token = UserDefaults.standard.string(forKey: self.pushTokenStorageKey)
        result([
          "granted": granted,
          "token": token ?? NSNull(),
        ])
      }
    }
  }

  override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
    UserDefaults.standard.set(token, forKey: pushTokenStorageKey)
    pushChannel?.invokeMethod("pushTokenUpdated", arguments: token)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    pushChannel?.invokeMethod("pushTokenUpdated", arguments: nil)
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .list, .sound, .badge])
    } else {
      completionHandler([.alert, .sound, .badge])
    }
  }
}
