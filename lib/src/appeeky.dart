import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'core.dart';
import 'native.dart';
import 'storage.dart';

/// Static entry point. Call [init] once, as early as possible (in `main`).
class Appeeky {
  Appeeky._();

  static AppeekyAnalytics? _client;
  static _Lifecycle? _lifecycle;

  /// Start the SDK. Later calls return the first client.
  ///
  /// [key] is the app's publishable key (`apk_…`). [endpoint] defaults to
  /// Appeeky's hosted ingest; self-hosted servers pass their own
  /// `https://…/v1/ingest`. [getLaunchUrl] is a fallback for the URL that
  /// opened the app when the plugin did not see it (for example an iOS app
  /// on UIScene lifecycle: pass your deep link package's initial link).
  static AppeekyAnalytics init({
    required String key,
    String endpoint = defaultEndpoint,
    bool debug = false,
    Duration flushInterval = const Duration(seconds: 10),
    int flushAt = 20,
    int maxQueueSize = 1000,
    Duration sessionTimeout = const Duration(minutes: 30),
    bool resolveAdServicesOnDevice = true,
    Future<String?> Function()? getAdServicesToken,
    Future<String?> Function()? getInstallReferrer,
    Future<String?> Function()? getLaunchUrl,
    DeviceContext? context,
    bool disabled = false,
  }) {
    final existing = _client;
    if (existing != null) return existing;
    WidgetsFlutterBinding.ensureInitialized();

    final client = AppeekyAnalytics(
      AppeekyOptions(
        key: key,
        endpoint: endpoint,
        debug: debug,
        flushInterval: flushInterval,
        flushAt: flushAt,
        maxQueueSize: maxQueueSize,
        sessionTimeout: sessionTimeout,
        resolveAdServicesOnDevice: resolveAdServicesOnDevice,
        getAdServicesToken: getAdServicesToken,
        getInstallReferrer: getInstallReferrer,
        context: context,
        disabled: disabled,
      ),
      CoreDeps(
        native: AppeekyNativeChannel.bridge(),
        storage: SharedPreferencesStorage(),
        httpClient: http.Client(),
        now: () => DateTime.now().millisecondsSinceEpoch,
        randomId: _uuidV4,
        deviceContext: AppeekyNativeChannel.deviceContext,
        launchUrl: () async => await AppeekyNativeChannel.launchUrl() ?? await getLaunchUrl?.call(),
        logger: (message) => debugPrint(message),
      ),
    );
    _client = client;
    final lifecycle = _Lifecycle(client);
    WidgetsBinding.instance.addObserver(lifecycle);
    _lifecycle = lifecycle;
    unawaited(client.start());
    return client;
  }

  static AppeekyAnalytics? _require(String method) {
    final client = _client;
    if (client == null && kDebugMode) {
      debugPrint('[appeeky-analytics] $method() called before init(); ignored.');
    }
    return client;
  }

  /// Record a custom event. Names may use letters, digits, `_ . : -` (up to
  /// 64 characters); property values are strings, numbers, booleans or null.
  static void track(String name, [Map<String, Object?>? properties, num? value]) =>
      _require('track')?.track(name, properties, value);

  /// Record a screen view (or use [AppeekyNavigatorObserver]).
  static void screen(String name, [Map<String, Object?>? properties]) =>
      _require('screen')?.screen(name, properties);

  /// Link the install to your RevenueCat app user id (or the id you give
  /// Superwall). Pass null on logout.
  static void identify(String? userId) => _require('identify')?.identify(userId);

  /// The smart link destination that brought this install (Android Play
  /// referrer, or the link that opened the app on first launch). Returns it
  /// once, on the first launch; null otherwise.
  static Future<String?> getDeferredDeepLink() =>
      _require('getDeferredDeepLink')?.getDeferredDeepLink() ?? Future<String?>.value();

  /// A trial started: raises the SKAdNetwork conversion value.
  static void trialStarted() => _require('trialStarted')?.trialStarted();

  /// A purchase in USD: raises the SKAdNetwork conversion value. Revenue
  /// itself comes from RevenueCat or Superwall.
  static void purchased(double valueUsd) => _require('purchased')?.purchased(valueUsd);

  /// Ad revenue in USD from one impression (e.g. an AdMob paid event).
  static void adRevenue(double valueUsd, {String? network, String? adUnit, String? format}) =>
      _require('adRevenue')?.adRevenue(valueUsd, network: network, adUnit: adUnit, format: format);

  /// Send everything queued now, even while backing off after a failure.
  static Future<void> flush() => _require('flush')?.flush(force: true) ?? Future<void>.value();

  /// The random install id; null before [init] has loaded it.
  static String? get installId => _client?.installId;

  /// Stop timers and the lifecycle observer (tests, or switching keys).
  static void shutdown() {
    final lifecycle = _lifecycle;
    if (lifecycle != null) WidgetsBinding.instance.removeObserver(lifecycle);
    _lifecycle = null;
    _client?.shutdown();
    _client = null;
  }
}

class _Lifecycle with WidgetsBindingObserver {
  _Lifecycle(this.client) : _previous = WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;

  final AppeekyAnalytics client;
  AppLifecycleState _previous;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _previous != AppLifecycleState.resumed) {
      client.onForeground();
    }
    if (state == AppLifecycleState.paused && _previous != AppLifecycleState.paused) {
      client.onBackground();
    }
    _previous = state;
  }
}

final Random _random = Random.secure();

String _uuidV4() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}
