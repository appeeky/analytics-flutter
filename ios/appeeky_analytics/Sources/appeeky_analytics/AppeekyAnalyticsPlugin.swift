import AdServices
import Flutter
import StoreKit
import UIKit
#if canImport(AdAttributionKit)
import AdAttributionKit
#endif

/// Native side of appeeky_analytics on iOS: the Apple Search Ads attribution
/// token, SKAdNetwork / AdAttributionKit conversion value updates, the URL
/// that launched the app, and device fields. Everything else runs in Dart.
public class AppeekyAnalyticsPlugin: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate {
  /// The first URL that opened the app (custom scheme or universal link).
  private static var launchURL: URL?

  static func record(_ url: URL?) {
    guard let url = url, launchURL == nil else { return }
    launchURL = url
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "appeeky_analytics", binaryMessenger: registrar.messenger())
    let instance = AppeekyAnalyticsPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    // Apps on the UIScene lifecycle (the default for new Flutter apps) get
    // URLs through scene events; older app-delegate apps through the
    // application events below. Registering for both covers either.
    registrar.addSceneDelegate(instance)
    registrar.addApplicationDelegate(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getLaunchUrl":
      result(Self.launchURL?.absoluteString)
    case "getDeviceContext":
      result(Self.deviceContext())
    case "getInstallReferrer":
      result(nil)
    case "getAdServicesToken":
      // attributionToken() can block on a system call; keep it off the main thread.
      DispatchQueue.global(qos: .utility).async {
        let token = Self.adServicesToken()
        DispatchQueue.main.async { result(token) }
      }
    case "updateConversionValue":
      let args = call.arguments as? [String: Any] ?? [:]
      let fine = (args["fine"] as? NSNumber)?.intValue ?? 0
      let coarse = args["coarse"] as? String ?? "low"
      let lockWindow = (args["lockWindow"] as? NSNumber)?.boolValue ?? false
      Task {
        await Self.updateConversionValue(fine: fine, coarse: coarse, lockWindow: lockWindow)
        DispatchQueue.main.async { result(nil) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Launch URL (FlutterSceneLifeCycleDelegate)

  public func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    if let options = connectionOptions {
      Self.record(options.urlContexts.first?.url)
      for activity in options.userActivities where activity.activityType == NSUserActivityTypeBrowsingWeb {
        Self.record(activity.webpageURL)
      }
    }
    // Not consumed: other plugins still receive the connection options.
    return false
  }

  public func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    Self.record(URLContexts.first?.url)
    return false
  }

  public func scene(_ scene: UIScene, continue userActivity: NSUserActivity) -> Bool {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb {
      Self.record(userActivity.webpageURL)
    }
    return false
  }

  // MARK: - Launch URL (FlutterApplicationLifeCycleDelegate, apps without UIScene)

  public func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [AnyHashable: Any] = [:]
  ) -> Bool {
    let url = launchOptions[UIApplication.LaunchOptionsKey.url] ?? launchOptions[UIApplication.LaunchOptionsKey.url.rawValue]
    Self.record(url as? URL)
    return true
  }

  public func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    Self.record(url)
    // Not handled: let the app and other plugins handle the link.
    return false
  }

  public func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([Any]) -> Void
  ) -> Bool {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb {
      Self.record(userActivity.webpageURL)
    }
    return false
  }

  // MARK: - Attribution

  private static func adServicesToken() -> String? {
    if #available(iOS 14.3, *) {
      return try? AAAttribution.attributionToken()
    }
    return nil
  }

  private static func updateConversionValue(fine: Int, coarse: String, lockWindow: Bool) async {
    let value = max(0, min(63, fine))
    // Ads served through AdAttributionKit and through SKAdNetwork each read
    // their own framework's value, so update both where available.
    #if canImport(AdAttributionKit)
    if #available(iOS 17.4, *) {
      let coarseValue: CoarseConversionValue = coarse == "high" ? .high : coarse == "medium" ? .medium : .low
      try? await Postback.updateConversionValue(value, coarseConversionValue: coarseValue, lockPostback: lockWindow)
    }
    #endif
    if #available(iOS 16.1, *) {
      let coarseValue: SKAdNetwork.CoarseConversionValue = coarse == "high" ? .high : coarse == "medium" ? .medium : .low
      try? await SKAdNetwork.updatePostbackConversionValue(value, coarseValue: coarseValue, lockWindow: lockWindow)
    } else if #available(iOS 15.4, *) {
      try? await SKAdNetwork.updatePostbackConversionValue(value)
    } else if #available(iOS 14.0, *) {
      SKAdNetwork.updateConversionValue(value)
    }
  }

  // MARK: - Device

  private static func deviceContext() -> [String: String] {
    var out: [String: String] = [:]
    let info = Bundle.main.infoDictionary ?? [:]
    if let version = info["CFBundleShortVersionString"] as? String { out["appVersion"] = version }
    if let build = info["CFBundleVersion"] as? String { out["build"] = build }
    out["osVersion"] = UIDevice.current.systemVersion
    out["deviceModel"] = modelIdentifier()
    return out
  }

  /// Hardware identifier such as "iPhone16,2" (the simulated model on a simulator).
  private static func modelIdentifier() -> String {
    if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
      return simulated
    }
    var systemInfo = utsname()
    uname(&systemInfo)
    return withUnsafePointer(to: &systemInfo.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) {
        String(cString: $0)
      }
    }
  }
}
