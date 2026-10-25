import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'core.dart';

/// The plugin's method channel: Apple Search Ads token, SKAdNetwork /
/// AdAttributionKit conversion values, Play Install Referrer, launch URL and
/// device fields. Every call returns null where the platform has no answer
/// (other platforms, or the plugin missing from the build).
class AppeekyNativeChannel {
  AppeekyNativeChannel._();

  static const MethodChannel channel = MethodChannel('appeeky_analytics');

  static bool get _isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Capabilities for the current platform.
  static NativeBridge bridge() => NativeBridge(
        getAdServicesToken: _isIOS ? () => _string('getAdServicesToken') : null,
        getInstallReferrer: _isAndroid ? () => _string('getInstallReferrer') : null,
        updateConversionValue: _isIOS
            ? (fine, coarse, lockWindow) => channel.invokeMethod<void>(
                  'updateConversionValue',
                  <String, Object?>{'fine': fine, 'coarse': coarse, 'lockWindow': lockWindow},
                )
            : null,
      );

  /// The first URL that opened the app (custom scheme or universal / app link).
  static Future<String?> launchUrl() => _string('getLaunchUrl');

  /// App version, build, OS version and device model from the platform.
  static Future<DeviceContext> deviceContext() async {
    Map<String, Object?>? raw;
    try {
      raw = await channel.invokeMapMethod<String, Object?>('getDeviceContext');
    } catch (_) {
      raw = null;
    }
    String? field(String key) {
      final value = raw?[key];
      return value?.toString();
    }

    String? locale;
    try {
      final tag = PlatformDispatcher.instance.locale.toLanguageTag();
      locale = tag == 'und' ? null : tag;
    } catch (_) {
      locale = null;
    }
    return DeviceContext(
      platform: _isIOS ? 'ios' : (_isAndroid ? 'android' : null),
      appVersion: field('appVersion'),
      build: field('build'),
      osVersion: field('osVersion'),
      deviceModel: field('deviceModel'),
      locale: locale,
    );
  }

  static Future<String?> _string(String method) async {
    try {
      return await channel.invokeMethod<String>(method);
    } catch (_) {
      return null;
    }
  }
}
