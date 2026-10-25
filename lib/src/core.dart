/// Platform-independent client: install id, sessions, offline queue,
/// batching and retries. The Flutter entry point (`appeeky.dart`) injects
/// storage, the device context, the native bridge and app lifecycle; tests
/// inject fakes. Nothing in this file imports Flutter.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Version of this SDK, sent with every batch as `flutter/<version>`.
const String sdkVersion = '0.1.0';

/// Appeeky's hosted ingest endpoint; self-hosted servers pass their own.
const String defaultEndpoint = 'https://ingest.appeeky.com/v1/ingest';

const String _stateKey = 'appeeky_analytics.state';
const String _queueKey = 'appeeky_analytics.queue';
const int _maxBatch = 100;
const int _maxBackoffMs = 5 * 60 * 1000;
const Duration _attributionTimeout = Duration(seconds: 3);
const Duration _requestTimeout = Duration(seconds: 30);

/// A single foreground stretch longer than this is clamped (clock jumps, stuck timers).
const int _maxForegroundMs = 4 * 60 * 60 * 1000;
final Uri _adServicesUrl = Uri.parse('https://api-adservices.apple.com/api/v1/');

/// Apple may answer 404 until the attribution record is ready.
const int _adServicesAttempts = 3;
const Duration _adServicesRetry = Duration(seconds: 5);
const int _dayMs = 24 * 60 * 60 * 1000;

// Conversion value schema; keep in step with packages/core/src/skan.ts.
const int conversionOpened = 1;
const int conversionReturned = 2;
const int conversionTrial = 8;
const int conversionPurchaseBase = 16;

/// Event names the server accepts; others make it reject the whole batch.
final RegExp _eventName = RegExp(r'^[A-Za-z0-9_.:-]+$');

/// Small async key/value store for the SDK's state and queue.
abstract class KeyValueStorage {
  Future<String?> getItem(String key);
  Future<void> setItem(String key, String value);
}

/// Device fields sent with every batch. Empty values are left out.
class DeviceContext {
  const DeviceContext({
    this.platform,
    this.appVersion,
    this.build,
    this.osVersion,
    this.deviceModel,
    this.locale,
  });

  /// `ios` or `android`.
  final String? platform;
  final String? appVersion;
  final String? build;
  final String? osVersion;
  final String? deviceModel;

  /// BCP 47 tag, for example `tr-TR`.
  final String? locale;

  /// Fields of [other] win where set.
  DeviceContext merge(DeviceContext? other) {
    if (other == null) return this;
    return DeviceContext(
      platform: other.platform ?? platform,
      appVersion: other.appVersion ?? appVersion,
      build: other.build ?? build,
      osVersion: other.osVersion ?? osVersion,
      deviceModel: other.deviceModel ?? deviceModel,
      locale: other.locale ?? locale,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    void put(String key, String? value, int max) {
      final text = value?.trim();
      if (text != null && text.isNotEmpty) out[key] = truncate(text, max);
    }

    if (platform == 'ios' || platform == 'android') out['platform'] = platform;
    put('appVersion', appVersion, 64);
    put('build', build, 64);
    put('osVersion', osVersion, 64);
    put('deviceModel', deviceModel, 128);
    put('locale', locale, 35);
    return out;
  }
}

/// SKAdNetwork / AdAttributionKit coarse conversion value.
typedef CoarseValue = String;

/// Native capabilities (the plugin's method channel); every one is optional.
class NativeBridge {
  const NativeBridge({this.getAdServicesToken, this.getInstallReferrer, this.updateConversionValue});

  /// iOS: AAAttribution.attributionToken().
  final Future<String?> Function()? getAdServicesToken;

  /// Android: Play Install Referrer.
  final Future<String?> Function()? getInstallReferrer;

  /// iOS: SKAdNetwork / AdAttributionKit conversion value update.
  /// `coarse` is `low`, `medium` or `high`.
  final Future<void> Function(int fine, CoarseValue coarse, bool lockWindow)? updateConversionValue;
}

/// Timers, injectable so tests run without real time.
abstract class AppeekyScheduler {
  Object periodic(Duration interval, void Function() fn);
  void cancel(Object handle);
  void after(Duration delay, void Function() fn);
}

/// [AppeekyScheduler] on `dart:async` timers.
class TimerScheduler implements AppeekyScheduler {
  const TimerScheduler();

  @override
  Object periodic(Duration interval, void Function() fn) => Timer.periodic(interval, (_) => fn());

  @override
  void cancel(Object handle) {
    if (handle is Timer) handle.cancel();
  }

  @override
  void after(Duration delay, void Function() fn) {
    Timer(delay, fn);
  }
}

class AppeekyOptions {
  const AppeekyOptions({
    required this.key,
    this.endpoint = defaultEndpoint,
    this.flushInterval = const Duration(seconds: 10),
    this.flushAt = 20,
    this.maxQueueSize = 1000,
    this.sessionTimeout = const Duration(minutes: 30),
    this.getAdServicesToken,
    this.resolveAdServicesOnDevice = true,
    this.getInstallReferrer,
    this.context,
    this.disabled = false,
    this.debug = false,
  });

  /// Publishable key of the app (starts with `apk_`).
  final String key;

  /// Ingest URL. Defaults to Appeeky's hosted service; a self-hosted server
  /// passes its own, e.g. `https://analytics.example.com/v1/ingest`.
  final String endpoint;

  /// Flush at least this often while the app is open.
  final Duration flushInterval;

  /// Flush as soon as this many events are queued.
  final int flushAt;

  /// Oldest events are dropped past this many queued events.
  final int maxQueueSize;

  /// A new session starts after this much time in the background.
  final Duration sessionTimeout;

  /// iOS: overrides the plugin's AAAttribution.attributionToken().
  final Future<String?> Function()? getAdServicesToken;

  /// Exchange the AdServices token with Apple from the device. The token is
  /// sent too, so the server can still try if this fails.
  final bool resolveAdServicesOnDevice;

  /// Android: overrides the plugin's Play Install Referrer.
  final Future<String?> Function()? getInstallReferrer;

  /// Override or fill in device context fields.
  final DeviceContext? context;

  /// Collect nothing and send nothing (e.g. the user opted out).
  final bool disabled;

  /// Log rejected batches, network errors and sends.
  final bool debug;
}

class CoreDeps {
  CoreDeps({
    this.native,
    required this.storage,
    required this.httpClient,
    required this.now,
    required this.randomId,
    required this.deviceContext,
    this.launchUrl,
    this.scheduler = const TimerScheduler(),
    void Function(String message)? logger,
  }) : logger = logger ?? _printLogger;

  final NativeBridge? native;
  final KeyValueStorage storage;
  final http.Client httpClient;

  /// Milliseconds since the epoch.
  final int Function() now;
  final String Function() randomId;
  final Future<DeviceContext> Function() deviceContext;

  /// URL the app was opened with, for campaign links.
  final Future<String?> Function()? launchUrl;
  final AppeekyScheduler scheduler;
  final void Function(String message) logger;
}

void _printLogger(String message) {
  // ignore: avoid_print
  print(message);
}

class _State {
  _State(this.installId);

  final String installId;
  String? userId;
  String? sessionId;
  int? lastActiveAt;
  bool attributionSent = false;

  /// First launch time; "came back on a later day" is measured from it.
  int? installedAt;

  /// Highest SKAdNetwork fine conversion value written so far.
  int? conversionValue;

  /// The deferred deep link was already handed to the app.
  bool deepLinkDelivered = false;

  static _State? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['installId'];
    if (id is! String || id.isEmpty) return null;
    return _State(id)
      ..userId = _asString(json['userId'])
      ..sessionId = _asString(json['sessionId'])
      ..lastActiveAt = _asInt(json['lastActiveAt'])
      ..attributionSent = json['attributionSent'] == true
      ..installedAt = _asInt(json['installedAt'])
      ..conversionValue = _asInt(json['conversionValue'])
      ..deepLinkDelivered = json['deepLinkDelivered'] == true;
  }

  Map<String, Object?> toJson() => _withoutNulls({
        'installId': installId,
        'userId': userId,
        'sessionId': sessionId,
        'lastActiveAt': lastActiveAt,
        'attributionSent': attributionSent ? true : null,
        'installedAt': installedAt,
        'conversionValue': conversionValue,
        'deepLinkDelivered': deepLinkDelivered ? true : null,
      });
}

class _Event {
  _Event({required this.id, required this.name, required this.ts, this.sessionId, this.screen, this.props, this.value});

  final String id;
  final String name;
  final int ts;
  final String? sessionId;
  final String? screen;
  final Map<String, Object?>? props;
  final num? value;

  static _Event? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    final ts = _asInt(json['ts']);
    if (id is! String || name is! String || ts == null) return null;
    final props = json['props'];
    final value = json['value'];
    return _Event(
      id: id,
      name: name,
      ts: ts,
      sessionId: _asString(json['sessionId']),
      screen: _asString(json['screen']),
      props: props is Map ? props.map((k, v) => MapEntry(k.toString(), v)) : null,
      value: value is num ? value : null,
    );
  }

  Map<String, Object?> toJson() => _withoutNulls({
        'id': id,
        'name': name,
        'ts': ts,
        'sessionId': sessionId,
        'screen': screen,
        'props': props,
        'value': value,
      });
}

class _Attribution {
  String? adServicesToken;
  Map<String, Object?>? adServices;
  String? installReferrer;
  String? deepLinkUrl;

  bool get isEmpty => adServicesToken == null && adServices == null && installReferrer == null && deepLinkUrl == null;

  Map<String, Object?> toJson() => _withoutNulls({
        'adServicesToken': adServicesToken,
        'adServices': adServices,
        'installReferrer': installReferrer,
        'deepLinkUrl': deepLinkUrl,
      });
}

/// The SDK client. Most apps use the static `Appeeky` facade instead.
class AppeekyAnalytics {
  AppeekyAnalytics(this._opts, this._deps);

  final AppeekyOptions _opts;
  final CoreDeps _deps;

  _State? _state;
  List<_Event> _queue = <_Event>[];
  _Attribution? _attribution;
  DeviceContext _context = const DeviceContext();
  Future<void>? _ready;

  /// Completes once first-launch attribution is collected; batches wait for it.
  Future<void> _attributionReady = Future<void>.value();

  /// In-app destination from the smart link that brought this install, if any.
  String? _deferredDeepLink;
  Future<void>? _flushing;
  Object? _timer;
  int _backoffMs = 0;

  /// When the app last came to the foreground; null while in the background.
  int? _foregroundSince;
  int _retryAt = 0;

  /// The random install id, once the client has started; null before.
  String? get installId => _state?.installId;

  /// Load state, record first_open on a new install and start the first session.
  Future<void> start() {
    if (_opts.disabled) return Future<void>.value();
    return _ready ??= _boot();
  }

  Future<void> _boot() async {
    final stored = await Future.wait(<Future<String?>>[
      _safeGet(_queueKey),
      _safeGet(_stateKey),
    ]);
    final rawQueue = _parseJson(stored[0]);
    _queue = rawQueue is List ? rawQueue.map(_Event.fromJson).whereType<_Event>().toList() : <_Event>[];
    final saved = _State.fromJson(_parseJson(stored[1]));
    final isNewInstall = saved == null;
    final state = saved ?? _State(_deps.randomId());
    _state = state;
    final device = await _withTimeout(_deps.deviceContext, _attributionTimeout);
    _context = (device ?? const DeviceContext()).merge(_opts.context);

    if (!state.attributionSent) {
      _attributionReady = _collectAttribution().catchError((Object err) {
        _log('attribution failed: $err');
        _attribution = _Attribution();
      });
    }

    // Session first, so first_open carries the session id.
    _ensureSession();
    _foregroundSince = _deps.now();
    if (isNewInstall) {
      state.installedAt = _deps.now();
      _enqueue('first_open');
      unawaited(_raiseConversionValue(conversionOpened));
    }
    await _persist();

    _timer = _deps.scheduler.periodic(_opts.flushInterval, () => unawaited(flush()));
    unawaited(flush());
  }

  /// Record a custom event. [value] is an optional number (for example revenue in USD).
  void track(String name, [Map<String, Object?>? properties, num? value]) {
    if (name.trim().isEmpty) return;
    _whenReady(() {
      _ensureSession();
      _enqueue(name, props: cleanProps(properties), value: value != null && value.isFinite ? value : null);
    });
  }

  /// Record a screen view.
  void screen(String name, [Map<String, Object?>? properties]) {
    if (name.trim().isEmpty) return;
    _whenReady(() {
      _ensureSession();
      _enqueue('screen', screen: truncate(name, 128), props: cleanProps(properties));
    });
  }

  /// Ad revenue from one impression or ad unit callback, in USD (for example
  /// AdMob's paid event: valueMicros / 1e6 when the currency is USD).
  void adRevenue(double valueUsd, {String? network, String? adUnit, String? format}) {
    if (!valueUsd.isFinite || valueUsd < 0) return;
    track(
      'ad_revenue',
      <String, Object?>{'network': network, 'ad_unit': adUnit, 'format': format},
      (valueUsd * 1e6).roundToDouble() / 1e6,
    );
  }

  /// The in-app destination of the smart link that brought this install
  /// (Android, from the Play referrer) or opened the app on first launch.
  /// Returns it once, on the first launch; null afterwards or when there is none.
  Future<String?> getDeferredDeepLink() async {
    if (_opts.disabled) return null;
    await start();
    await _attributionReady;
    final state = _state;
    final link = _deferredDeepLink;
    if (state == null || state.deepLinkDelivered || link == null) return null;
    state.deepLinkDelivered = true;
    unawaited(_persist());
    return link;
  }

  /// A trial started: raises the SKAdNetwork conversion value (revenue still comes from RevenueCat).
  void trialStarted() {
    _whenReady(() => unawaited(_raiseConversionValue(conversionTrial)));
  }

  /// A purchase in USD: raises the SKAdNetwork conversion value (revenue still comes from RevenueCat).
  void purchased(double valueUsd) {
    if (!valueUsd.isFinite || valueUsd < 0) return;
    final fine = conversionPurchaseBase + (valueUsd / 2).floor();
    _whenReady(() => unawaited(_raiseConversionValue(fine > 63 ? 63 : fine)));
  }

  /// Link this install to your RevenueCat app_user_id (or Superwall user id)
  /// so purchases get a source. Pass null on logout.
  void identify(String? userId) {
    _whenReady(() {
      final state = _state;
      if (state == null) return;
      final id = userId?.trim();
      final hasId = id != null && id.isNotEmpty;
      state.userId = hasId ? truncate(id, 256) : null;
      unawaited(_persist());
      // The user id rides on every batch's context; this event makes sure a
      // batch goes out soon so the install is linked before the first purchase.
      _enqueue(hasId ? 'identify' : 'reset');
      _deps.scheduler.after(const Duration(seconds: 1), () => unawaited(flush()));
    });
  }

  /// Call when the app comes to the foreground.
  void onForeground() {
    _whenReady(() {
      _ensureSession();
      _foregroundSince ??= _deps.now();
    });
  }

  /// Call when the app goes to the background: marks activity and flushes.
  void onBackground() {
    _whenReady(() {
      final now = _deps.now();
      _state?.lastActiveAt = now;
      // Time on screen since the last foreground; sessions add these up.
      final since = _foregroundSince;
      if (since != null) {
        final foregroundMs = (now - since).clamp(0, _maxForegroundMs);
        _foregroundSince = null;
        _enqueue('app_background', props: <String, Object?>{'foreground_ms': foregroundMs});
      }
      unawaited(_persist());
      unawaited(flush(force: true));
    });
  }

  /// Send everything queued now. Completes when the queue is empty or a send
  /// failed. Without [force], does nothing while backing off after a failure.
  Future<void> flush({bool force = false}) {
    if (_opts.disabled || _state == null) return Future<void>.value();
    final current = _flushing;
    if (current != null) return current;
    if (!force && _deps.now() < _retryAt) return Future<void>.value();
    final run = _drain().catchError((Object err) => _log('flush failed: $err')).whenComplete(() {
      _flushing = null;
    });
    _flushing = run;
    return run;
  }

  /// Stop the flush timer.
  void shutdown() {
    final timer = _timer;
    if (timer != null) _deps.scheduler.cancel(timer);
    _timer = null;
  }

  // ─── internals ────────────────────────────────────────────────────────────

  /// SKAdNetwork fine values only go up, so a later, weaker signal never
  /// overwrites a purchase. Schema shared with the server (core/skan.ts).
  Future<void> _raiseConversionValue(int fine) async {
    final update = _deps.native?.updateConversionValue;
    final state = _state;
    if (update == null || state == null) return;
    if ((state.conversionValue ?? 0) >= fine) return;
    state.conversionValue = fine;
    unawaited(_persist());
    final coarse = fine >= conversionPurchaseBase
        ? 'high'
        : fine >= conversionReturned
            ? 'medium'
            : 'low';
    try {
      await update(fine, coarse, false);
    } catch (err) {
      _log('conversion value update failed: $err');
    }
  }

  Future<void> _collectAttribution() async {
    final native = _deps.native;
    final results = await Future.wait(<Future<String?>>[
      _withTimeout(_opts.getAdServicesToken ?? native?.getAdServicesToken, _attributionTimeout),
      _withTimeout(_opts.getInstallReferrer ?? native?.getInstallReferrer, _attributionTimeout),
      _withTimeout(_deps.launchUrl, _attributionTimeout),
    ]);
    final adServicesToken = _nonEmpty(results[0], 4096);
    final installReferrer = _nonEmpty(results[1], 2048);
    final deepLinkUrl = _nonEmpty(results[2], 2048);
    _deferredDeepLink = deferredDeepLinkFrom(installReferrer, deepLinkUrl);
    final attribution = _Attribution();
    if (adServicesToken != null) {
      attribution.adServicesToken = adServicesToken;
      if (_opts.resolveAdServicesOnDevice) {
        final resolved = await _resolveAdServices(adServicesToken);
        if (resolved != null) attribution.adServices = resolved;
      }
    }
    attribution.installReferrer = installReferrer;
    attribution.deepLinkUrl = deepLinkUrl;
    _attribution = attribution;
  }

  Future<Map<String, Object?>?> _resolveAdServices(String token) async {
    for (var attempt = 1; attempt <= _adServicesAttempts; attempt++) {
      try {
        final request = http.Request('POST', _adServicesUrl)
          ..headers['Content-Type'] = 'text/plain'
          ..bodyBytes = utf8.encode(token);
        final response = await http.Response.fromStream(await _deps.httpClient.send(request).timeout(_requestTimeout));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final body = jsonDecode(response.body);
          final out = <String, Object?>{};
          if (body is Map) {
            for (final entry in body.entries.take(20)) {
              final v = entry.value;
              final k = entry.key.toString();
              if (v == null || v is num || v is bool) {
                out[k] = v;
              } else if (v is String) {
                out[k] = truncate(v, 256);
              }
            }
          }
          return out;
        }
        if (response.statusCode == 400) return null;
      } catch (err) {
        _log('AdServices request failed: $err');
      }
      if (attempt < _adServicesAttempts) {
        final wait = Completer<void>();
        _deps.scheduler.after(_adServicesRetry, wait.complete);
        await wait.future;
      }
    }
    return null;
  }

  void _whenReady(void Function() fn) {
    if (_opts.disabled) return;
    start().then((_) => fn()).catchError((Object err) => _log('error: $err'));
  }

  void _ensureSession() {
    final state = _state;
    if (state == null) return;
    final now = _deps.now();
    final last = state.lastActiveAt;
    final expired = last == null || now - last > _opts.sessionTimeout.inMilliseconds;
    if (state.sessionId == null || expired) {
      state.sessionId = _deps.randomId();
      state.lastActiveAt = now;
      _enqueue('session_start');
      final installedAt = state.installedAt;
      if (installedAt != null && now - installedAt >= _dayMs) {
        unawaited(_raiseConversionValue(conversionReturned));
      }
    }
    state.lastActiveAt = now;
  }

  void _enqueue(String name, {String? screen, Map<String, Object?>? props, num? value}) {
    final state = _state;
    if (state == null) return;
    final cleanName = truncate(name.trim(), 64);
    if (!_eventName.hasMatch(cleanName)) {
      _log('event name "$cleanName" has characters other than letters, digits, _ . : - and will be rejected');
    }
    _queue.add(_Event(
      id: _deps.randomId(),
      name: cleanName,
      ts: _deps.now(),
      sessionId: state.sessionId,
      screen: screen,
      props: props,
      value: value,
    ));
    if (_queue.length > _opts.maxQueueSize) {
      _queue.removeRange(0, _queue.length - _opts.maxQueueSize);
    }
    unawaited(_persistQueue());
    if (_queue.length >= _opts.flushAt) unawaited(flush());
  }

  Future<void> _drain() async {
    if (_state != null && !_state!.attributionSent) await _attributionReady;
    while (true) {
      final state = _state;
      if (state == null) return;
      final attribution = _attribution;
      final sendAttribution = !state.attributionSent && attribution != null;
      final batch = _queue.take(_maxBatch).toList();
      if (batch.isEmpty && !sendAttribution) return;

      final context = _context.toJson();
      if (state.userId != null) context['userId'] = state.userId;
      final body = <String, Object?>{
        'installId': state.installId,
        'sdk': 'flutter/$sdkVersion',
        'context': context,
        'events': batch.map((e) => e.toJson()).toList(),
      };
      if (sendAttribution && !attribution.isEmpty) body['attribution'] = attribution.toJson();

      var status = 0;
      try {
        final request = http.Request('POST', Uri.parse(_opts.endpoint))
          ..headers['Content-Type'] = 'application/json'
          ..headers['X-Appeeky-Key'] = _opts.key
          ..bodyBytes = utf8.encode(jsonEncode(body));
        final response = await _deps.httpClient.send(request).timeout(_requestTimeout);
        status = response.statusCode;
        await response.stream.drain<void>();
      } catch (err) {
        _log('network error: $err');
      }

      final retryable = status == 0 || status == 429 || status >= 500;
      if (retryable) {
        _backoffMs = _backoffMs == 0 ? 5000 : _backoffMs * 2;
        if (_backoffMs > _maxBackoffMs) _backoffMs = _maxBackoffMs;
        _retryAt = _deps.now() + _backoffMs;
        if (status != 0) _log('batch not stored (HTTP $status); retrying in ${_backoffMs ~/ 1000}s');
        return;
      }
      // 2xx: stored. Other 4xx: the server will never accept this batch, so
      // drop it rather than retrying forever.
      if (status >= 400) {
        _log('batch rejected with HTTP $status');
      } else {
        _log('sent ${batch.length} events');
      }
      _backoffMs = 0;
      _retryAt = 0;
      final sent = batch.map((e) => e.id).toSet();
      _queue = _queue.where((e) => !sent.contains(e.id)).toList();
      if (sendAttribution) {
        state.attributionSent = true;
        _attribution = null;
      }
      await Future.wait(<Future<void>>[_persist(), _persistQueue()]);
    }
  }

  Future<String?> _safeGet(String key) async {
    try {
      return await _deps.storage.getItem(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _persist() async {
    final state = _state;
    if (state == null) return;
    try {
      await _deps.storage.setItem(_stateKey, jsonEncode(state.toJson()));
    } catch (_) {}
  }

  Future<void> _persistQueue() async {
    try {
      await _deps.storage.setItem(_queueKey, jsonEncode(_queue.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  void _log(String message) {
    if (!_opts.debug) return;
    _deps.logger('[appeeky-analytics] $message');
  }
}

/// Storage keys, exposed for tests.
const String stateStorageKey = _stateKey;
const String queueStorageKey = _queueKey;

/// Props the server accepts: keys up to 64 characters, strings up to 512,
/// finite numbers, booleans and null. Other values are sent as strings.
Map<String, Object?>? cleanProps(Map<String, Object?>? props) {
  if (props == null) return null;
  final out = <String, Object?>{};
  props.forEach((key, value) {
    final k = truncate(key, 64);
    if (value == null || value is bool) {
      out[k] = value;
    } else if (value is num) {
      if (value.isFinite) out[k] = value;
    } else if (value is String) {
      out[k] = truncate(value, 512);
    } else {
      out[k] = truncate(value.toString(), 512);
    }
  });
  return out.isEmpty ? null : out;
}

/// Cut [text] to [max] UTF-16 code units without splitting a surrogate pair.
String truncate(String text, int max) {
  if (text.length <= max) return text;
  var end = max;
  final last = text.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return text.substring(0, end);
}

/// `aky_dl` from a Play referrer, or the opening URL when it came from a smart link.
String? deferredDeepLinkFrom(String? installReferrer, String? openUrl) {
  if (installReferrer != null) {
    final dl = queryParam(installReferrer, 'aky_dl');
    if (dl != null && dl.isNotEmpty) return dl;
  }
  if (openUrl != null && RegExp(r'[?&]aky_l=').hasMatch(openUrl)) return openUrl;
  return null;
}

/// First value of [key] in a query string (`a=1&b=2`), form-decoded.
String? queryParam(String query, String key) {
  for (final part in query.split('&')) {
    final eq = part.indexOf('=');
    final rawKey = eq < 0 ? part : part.substring(0, eq);
    if (_decodeComponent(rawKey) != key) continue;
    return eq < 0 ? '' : _decodeComponent(part.substring(eq + 1));
  }
  return null;
}

String _decodeComponent(String value) {
  try {
    return Uri.decodeQueryComponent(value);
  } catch (_) {
    return value.replaceAll('+', ' ');
  }
}

Future<T?> _withTimeout<T>(Future<T?> Function()? fn, Duration timeout) async {
  if (fn == null) return null;
  try {
    // then<T?> widens a Future<String> from `() async => '…'`, so the
    // null timeout value fits.
    return await fn().then<T?>((value) => value).timeout(timeout, onTimeout: () => null);
  } catch (_) {
    return null;
  }
}

String? _nonEmpty(String? value, int max) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;
  return truncate(text, max);
}

Object? _parseJson(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

String? _asString(Object? value) => value is String ? value : null;

int? _asInt(Object? value) => value is num ? value.toInt() : null;

Map<String, Object?> _withoutNulls(Map<String, Object?> map) {
  map.removeWhere((_, v) => v == null);
  return map;
}
