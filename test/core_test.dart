import 'dart:async';
import 'dart:convert';

import 'package:appeeky_analytics/src/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Sent {
  _Sent(this.url, this.headers, this.body);

  final String url;
  final Map<String, String> headers;
  final Map<String, dynamic> body;

  List<Map<String, dynamic>> get events => (body['events'] as List).cast<Map<String, dynamic>>();
  Map<String, dynamic>? get attribution => body['attribution'] as Map<String, dynamic>?;
  Map<String, dynamic> get context => body['context'] as Map<String, dynamic>;
}

class _MemoryStorage implements KeyValueStorage {
  final Map<String, String> store = <String, String>{};

  @override
  Future<String?> getItem(String key) async => store[key];

  @override
  Future<void> setItem(String key, String value) async => store[key] = value;
}

/// Periodic timers never fire; delayed callbacks run as soon as possible.
class _FakeScheduler implements AppeekyScheduler {
  @override
  Object periodic(Duration interval, void Function() fn) => 1;

  @override
  void cancel(Object handle) {}

  @override
  void after(Duration delay, void Function() fn) => scheduleMicrotask(fn);
}

class _Harness {
  _Harness({
    this.options = const _Opts(),
    List<int> statuses = const <int>[],
    this.adServices,
    this.native,
    this.device = const DeviceContext(platform: 'ios', osVersion: '18.1', locale: 'tr-TR', appVersion: ''),
    this.responseBody = '',
  }) : _responses = List<int>.of(statuses);

  final _Opts options;
  final http.Response Function()? adServices;
  final NativeBridge? native;
  final DeviceContext device;

  /// Body of every ingest response.
  final String responseBody;
  final List<String> logs = <String>[];
  final List<int> _responses;
  final _MemoryStorage storage = _MemoryStorage();
  final List<_Sent> sent = <_Sent>[];
  int clock = 1000000;
  int _ids = 0;
  int adServicesCalls = 0;

  void advance(int ms) => clock += ms;

  List<Map<String, dynamic>> get allEvents => sent.expand((s) => s.events).toList();

  late final http.Client client = MockClient((request) async {
    if (request.url.host == 'api-adservices.apple.com') {
      adServicesCalls++;
      return adServices?.call() ?? http.Response('', 404);
    }
    sent.add(_Sent(request.url.toString(), request.headers, jsonDecode(request.body) as Map<String, dynamic>));
    final status = _responses.isEmpty ? 202 : _responses.removeAt(0);
    if (status == -1) throw http.ClientException('offline');
    return http.Response(responseBody, status);
  });

  AppeekyAnalytics make() => AppeekyAnalytics(
        AppeekyOptions(
          key: 'apk_test',
          endpoint: options.endpoint ?? 'https://analytics.test/v1/ingest',
          flushAt: options.flushAt,
          maxQueueSize: options.maxQueueSize,
          sessionTimeout: options.sessionTimeout,
          getAdServicesToken: options.getAdServicesToken,
          resolveAdServicesOnDevice: options.resolveAdServicesOnDevice,
          context: options.context,
          testDevice: options.testDevice,
          disabled: options.disabled,
          debug: options.debug,
        ),
        CoreDeps(
          native: native,
          storage: storage,
          httpClient: client,
          now: () => clock,
          randomId: () => 'id${++_ids}',
          deviceContext: () async => device,
          launchUrl: () async => 'myapp://open?aky_c=launch',
          scheduler: _FakeScheduler(),
          logger: logs.add,
        ),
      );

  List<dynamic> storedQueue() => jsonDecode(storage.store[queueStorageKey] ?? '[]') as List<dynamic>;

  List<String> queuedNames() => storedQueue().map((e) => (e as Map<String, dynamic>)['name'] as String).toList();

  Map<String, dynamic> storedState() => jsonDecode(storage.store[stateStorageKey] ?? '{}') as Map<String, dynamic>;
}

class _Opts {
  const _Opts({
    this.endpoint,
    this.flushAt = 1000,
    this.maxQueueSize = 1000,
    this.sessionTimeout = const Duration(minutes: 30),
    this.getAdServicesToken,
    this.resolveAdServicesOnDevice = true,
    this.context,
    this.testDevice,
    this.disabled = false,
    this.debug = false,
  });

  final String? endpoint;
  final int flushAt;
  final int maxQueueSize;
  final Duration sessionTimeout;
  final Future<String?> Function()? getAdServicesToken;
  final bool resolveAdServicesOnDevice;
  final DeviceContext? context;
  final bool? testDevice;
  final bool disabled;
  final bool debug;
}

/// Let queued callbacks, microtasks and mock HTTP round trips run.
Future<void> tick() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<String?> _token() async => 'tok';

const String _mismatchText = "[appeeky-analytics] this key belongs to an app on the other store. Use the iOS app's key "
    "in the iOS build and the Android app's key in the Android build; until then both platforms are mixed in one "
    "app's reports.";
const String _mismatchBody = '{"ok":true,"warnings":["platform_mismatch","something_new",7]}';
const DeviceContext _testDevice = DeviceContext(platform: 'ios', testDevice: true);

void main() {
  test('first launch sends first_open, session_start and attribution once', () async {
    final h = _Harness(options: const _Opts(getAdServicesToken: _token, resolveAdServicesOnDevice: false));
    final sdk = h.make();
    await sdk.start();
    await sdk.flush(force: true);

    expect(h.sent, hasLength(1));
    final first = h.sent[0];
    expect(first.headers['X-Appeeky-Key'], 'apk_test');
    expect(first.headers['Content-Type'], 'application/json');
    expect(first.events.map((e) => e['name']), <String>['session_start', 'first_open']);
    expect(first.events.every((e) => e['sessionId'] != null), isTrue, reason: 'every event carries the session id');
    expect(first.attribution, <String, Object?>{'adServicesToken': 'tok', 'deepLinkUrl': 'myapp://open?aky_c=launch'});
    expect(first.context, <String, Object?>{'platform': 'ios', 'osVersion': '18.1', 'locale': 'tr-TR'},
        reason: 'empty fields are left out');
    expect(first.body['sdk'], 'flutter/0.3.0');
    expect(first.body['sdk'], 'flutter/$sdkVersion');
    expect(first.body['installId'], sdk.installId);

    sdk.screen('Paywall');
    await tick();
    await sdk.flush(force: true);
    expect(h.sent, hasLength(2));
    expect(h.sent[1].attribution, isNull);
    expect(h.sent[1].body.containsKey('attribution'), isFalse);
    expect(h.sent[1].events[0]['screen'], 'Paywall');
  });

  test('a relaunch keeps the install id and skips first_open', () async {
    final h = _Harness();
    final first = h.make();
    await first.start();
    await first.flush(force: true);
    first.shutdown();

    final second = h.make();
    await second.start();
    second.track('opened_again');
    await tick();
    await second.flush(force: true);
    expect(second.installId, first.installId);
    final names = h.sent.skip(1).expand((s) => s.events).map((e) => e['name']).toList();
    expect(names, isNot(contains('first_open')));
    expect(names, contains('opened_again'));
  });

  test('keeps the queue on network errors and 5xx, drops it on 4xx', () async {
    final h = _Harness(statuses: <int>[-1, 503, 202]);
    final sdk = h.make();
    await sdk.start();
    await sdk.flush(force: true); // joins the boot flush: offline
    await sdk.flush(force: true); // 503
    await sdk.flush(force: true); // 202
    expect(h.sent, hasLength(3));
    expect(h.sent[2].events.map((e) => e['name']), <String>['session_start', 'first_open']);
    expect(h.storedQueue(), isEmpty);

    final rejected = _Harness(statuses: <int>[400]);
    final sdk2 = rejected.make();
    await sdk2.start();
    await sdk2.flush(force: true);
    expect(rejected.storedQueue(), isEmpty);
    expect(rejected.sent, hasLength(1), reason: 'the attribution is not resent alone');
  });

  test('keeps the batch on 429', () async {
    final h = _Harness(statuses: <int>[429]);
    final sdk = h.make();
    await sdk.start();
    await sdk.flush(force: true);
    expect(h.storedQueue(), hasLength(2));
    await sdk.flush(force: true);
    expect(h.storedQueue(), isEmpty);
    expect(h.sent, hasLength(2));
  });

  test('backs off after a failure until forced', () async {
    final h = _Harness(statuses: <int>[500]);
    final sdk = h.make();
    await sdk.start();
    await sdk.flush(); // within backoff window: no request
    expect(h.sent, hasLength(1));
    h.advance(6000);
    await sdk.flush();
    expect(h.sent, hasLength(2));
  });

  test('starts a new session after the timeout and carries identify()', () async {
    final h = _Harness(options: const _Opts(sessionTimeout: Duration(seconds: 1)));
    final sdk = h.make();
    await sdk.start();
    await sdk.flush(force: true);
    final firstSession = h.sent[0].events[0]['sessionId'];

    sdk.identify('rc_user_1');
    sdk.onBackground();
    await tick();
    h.advance(5000);
    sdk.onForeground();
    sdk.track('after_resume');
    await tick();
    await sdk.flush(force: true);

    final last = h.sent.last;
    expect(last.context['userId'], 'rc_user_1');
    final resumed = last.events.firstWhere((e) => e['name'] == 'after_resume');
    expect(resumed['sessionId'], isNot(firstSession));
    expect(h.allEvents.where((e) => e['name'] == 'session_start').length, greaterThanOrEqualTo(2));
    expect(h.allEvents.map((e) => e['name']), contains('identify'));
  });

  test('identify(null) clears the user id and sends reset', () async {
    final h = _Harness();
    final sdk = h.make();
    await sdk.start();
    sdk.identify('rc_user_1');
    sdk.identify(null);
    await tick();
    await sdk.flush(force: true);
    expect(h.sent.last.context.containsKey('userId'), isFalse);
    expect(h.allEvents.map((e) => e['name']), containsAllInOrder(<String>['identify', 'reset']));
  });

  test('identify() with the stored id sends nothing, also after a relaunch', () async {
    final h = _Harness();
    final first = h.make();
    await first.start();
    first.identify('rc_user_1');
    first.identify('rc_user_1');
    first.identify('  rc_user_1  ');
    await tick();
    await first.flush(force: true);
    first.shutdown();
    expect(h.allEvents.where((e) => e['name'] == 'identify'), hasLength(1));

    final second = h.make();
    await second.start();
    await second.flush(force: true);
    final before = h.sent.length;
    second.identify('rc_user_1');
    await tick();
    await second.flush(force: true);
    expect(h.sent, hasLength(before), reason: 'no event and no flush for an unchanged id');
    expect(h.queuedNames(), isEmpty);

    second.track('later');
    await tick();
    await second.flush(force: true);
    expect(h.sent.last.context['userId'], 'rc_user_1', reason: 'the id still rides on every batch');

    second.identify('rc_user_2');
    await tick();
    await second.flush(force: true);
    expect(h.sent.last.context['userId'], 'rc_user_2');
    expect(h.allEvents.where((e) => e['name'] == 'identify'), hasLength(2));

    second.identify(null);
    second.identify(null);
    await tick();
    await second.flush(force: true);
    expect(h.allEvents.where((e) => e['name'] == 'reset'), hasLength(1));
    expect(h.sent.last.context.containsKey('userId'), isFalse);
  });

  test('a test device sends testDevice: true and other devices leave it out', () async {
    final detected = _Harness(device: _testDevice);
    final sdk = detected.make();
    await sdk.start();
    await sdk.flush(force: true);
    expect(detected.sent[0].context, <String, Object?>{'platform': 'ios', 'testDevice': true});

    final plain = _Harness();
    final sdk2 = plain.make();
    await sdk2.start();
    await sdk2.flush(force: true);
    expect(plain.sent[0].context.containsKey('testDevice'), isFalse);

    final notTest = _Harness(device: const DeviceContext(platform: 'ios', testDevice: false));
    final sdk3 = notTest.make();
    await sdk3.start();
    await sdk3.flush(force: true);
    expect(notTest.sent[0].context.containsKey('testDevice'), isFalse, reason: 'false is never sent');
  });

  test('the testDevice option overrides the detected value', () async {
    final off = _Harness(device: _testDevice, options: const _Opts(testDevice: false));
    final sdk = off.make();
    await sdk.start();
    await sdk.flush(force: true);
    expect(off.sent[0].context.containsKey('testDevice'), isFalse);

    final on = _Harness(options: const _Opts(testDevice: true));
    final sdk2 = on.make();
    await sdk2.start();
    await sdk2.flush(force: true);
    expect(on.sent[0].context['testDevice'], isTrue);

    final viaContext = _Harness(options: const _Opts(context: DeviceContext(testDevice: true)));
    final sdk3 = viaContext.make();
    await sdk3.start();
    await sdk3.flush(force: true);
    expect(viaContext.sent[0].context['testDevice'], isTrue);
  });

  test('a platform_mismatch warning is logged once per launch on a test device', () async {
    final h = _Harness(device: _testDevice, responseBody: _mismatchBody);
    final sdk = h.make();
    await sdk.start();
    await sdk.flush(force: true);
    sdk.track('again');
    await tick();
    await sdk.flush(force: true);
    expect(h.sent, hasLength(2));
    expect(h.logs, <String>[_mismatchText], reason: 'unknown warnings are ignored');
    expect(h.storedQueue(), isEmpty);
  });

  test('server warnings are logged with debug, also on a 402, and not otherwise', () async {
    final debug = _Harness(options: const _Opts(debug: true), statuses: <int>[402], responseBody: _mismatchBody);
    final sdk = debug.make();
    await sdk.start();
    await sdk.flush(force: true);
    expect(debug.logs.where((l) => l == _mismatchText), hasLength(1));

    final quiet = _Harness(responseBody: _mismatchBody);
    final sdk2 = quiet.make();
    await sdk2.start();
    await sdk2.flush(force: true);
    expect(quiet.logs, isEmpty);

    final rejected = _Harness(device: _testDevice, statuses: <int>[400], responseBody: _mismatchBody);
    final sdk3 = rejected.make();
    await sdk3.start();
    await sdk3.flush(force: true);
    expect(rejected.logs, isEmpty, reason: 'only stored batches carry warnings');
  });

  test('a missing or invalid response body means no warnings', () async {
    for (final body in <String>['', 'not json', '[]', '{"warnings":"platform_mismatch"}', '{"warnings":[1,null]}']) {
      final h = _Harness(device: _testDevice, responseBody: body);
      final sdk = h.make();
      await sdk.start();
      await sdk.flush(force: true);
      expect(h.logs, isEmpty, reason: body);
      expect(h.storedQueue(), isEmpty, reason: 'the batch still counts as sent: $body');
    }
    expect(warningsFrom('{"warnings":["a",2,"b"]}'), <String>['a', 'b']);
    expect(warningsFrom('null'), isEmpty);
  });

  test('disabled sends nothing', () async {
    final h = _Harness(options: const _Opts(disabled: true));
    final sdk = h.make();
    await sdk.start();
    sdk.track('x');
    await tick();
    await sdk.flush(force: true);
    expect(h.sent, isEmpty);
    expect(await sdk.getDeferredDeepLink(), isNull);
    expect(sdk.installId, isNull);
  });

  test("exchanges the AdServices token on device and sends Apple's answer", () async {
    final h = _Harness(
      options: const _Opts(getAdServicesToken: _token),
      adServices: () => http.Response(
        jsonEncode(<String, Object?>{
          'attribution': true,
          'campaignId': 42,
          'keywordId': 7,
          'nested': <String, int>{'x': 1},
        }),
        200,
      ),
    );
    final sdk = h.make();
    await sdk.start();
    await sdk.flush(force: true);
    expect(h.adServicesCalls, 1);
    expect(h.sent[0].attribution?['adServices'], <String, Object?>{'attribution': true, 'campaignId': 42, 'keywordId': 7});
    expect(h.sent[0].attribution?['adServicesToken'], 'tok');
  });

  test('falls back to sending only the token when Apple keeps answering 404', () async {
    final h = _Harness(options: const _Opts(getAdServicesToken: _token));
    final sdk = h.make();
    await sdk.start();
    await sdk.flush(force: true);
    expect(h.adServicesCalls, 3);
    expect(h.sent[0].attribution?.containsKey('adServices'), isFalse);
    expect(h.sent[0].attribution?['adServicesToken'], 'tok');
  });

  test('stops asking Apple after a 400', () async {
    final h = _Harness(options: const _Opts(getAdServicesToken: _token), adServices: () => http.Response('', 400));
    final sdk = h.make();
    await sdk.start();
    await sdk.flush(force: true);
    expect(h.adServicesCalls, 1);
    expect(h.sent[0].attribution?['adServicesToken'], 'tok');
  });

  test('app_background reports foreground time once per background', () async {
    final h = _Harness();
    final sdk = h.make();
    await sdk.start();
    h.advance(42000);
    sdk.onBackground();
    sdk.onBackground(); // a second background without a foreground adds nothing
    await tick();
    h.advance(10000);
    sdk.onForeground();
    await tick();
    h.advance(5000);
    sdk.onBackground();
    await tick();
    await sdk.flush(force: true);
    final backgrounds = h.allEvents
        .where((e) => e['name'] == 'app_background')
        .map((e) => (e['props'] as Map<String, dynamic>)['foreground_ms'])
        .toList();
    expect(backgrounds, <int>[42000, 5000]);
  });

  test('adRevenue sends a USD value and drops invalid amounts', () async {
    final h = _Harness();
    final sdk = h.make();
    await sdk.start();
    sdk.adRevenue(0.0123456789, network: 'admob', format: 'rewarded');
    sdk.adRevenue(-1);
    sdk.adRevenue(double.nan);
    await tick();
    await sdk.flush(force: true);
    final ads = h.allEvents.where((e) => e['name'] == 'ad_revenue').toList();
    expect(ads, hasLength(1));
    expect(ads[0]['value'], 0.012346);
    expect((ads[0]['props'] as Map<String, dynamic>)['network'], 'admob');
    expect((ads[0]['props'] as Map<String, dynamic>)['ad_unit'], isNull);
  });

  test("sends to Appeeky's hosted endpoint unless one is given", () async {
    final h = _Harness(options: const _Opts(endpoint: defaultEndpoint));
    final sdk = h.make();
    await sdk.start();
    await sdk.flush(force: true);
    expect(h.sent[0].url, defaultEndpoint);
    expect(defaultEndpoint, 'https://ingest.appeeky.com/v1/ingest');
    expect(const AppeekyOptions(key: 'apk_x').endpoint, defaultEndpoint);
  });

  test("hands the Play referrer's deep link to the app once", () async {
    final referrer =
        'utm_source=appeeky&aky_c=spring&aky_l=Ab3dE9x&aky_click=c1&aky_dl=${Uri.encodeComponent('myapp://offer/42')}';
    final h = _Harness(native: NativeBridge(getInstallReferrer: () async => referrer));
    final sdk = h.make();
    expect(await sdk.getDeferredDeepLink(), 'myapp://offer/42');
    expect(await sdk.getDeferredDeepLink(), isNull);
    await sdk.flush(force: true);
    expect(h.sent[0].attribution?['installReferrer'], referrer);
  });

  test('raises the SKAdNetwork conversion value and never lowers it', () async {
    final updates = <List<Object>>[];
    final h = _Harness(
      options: const _Opts(sessionTimeout: Duration(seconds: 1)),
      native: NativeBridge(updateConversionValue: (fine, coarse, lockWindow) async => updates.add(<Object>[fine, coarse])),
    );
    final sdk = h.make();
    await sdk.start();
    sdk.purchased(29.99);
    sdk.trialStarted(); // lower than the purchase: ignored
    await tick();
    h.advance(25 * 60 * 60 * 1000);
    sdk.onForeground(); // came back a day later: also lower, ignored
    await tick();
    expect(updates, <List<Object>>[
      <Object>[1, 'low'],
      <Object>[30, 'high'], // purchaseFineValue(29.99) in packages/core/src/skan.ts
    ]);
  });

  test('day-later return raises the value when nothing higher was set', () async {
    final updates = <int>[];
    final h = _Harness(
      options: const _Opts(sessionTimeout: Duration(seconds: 1)),
      native: NativeBridge(updateConversionValue: (fine, coarse, lockWindow) async => updates.add(fine)),
    );
    final sdk = h.make();
    await sdk.start();
    await tick();
    h.advance(25 * 60 * 60 * 1000);
    sdk.onForeground();
    await tick();
    expect(updates, <int>[1, 2]);
  });

  test('purchase values cap at 63 and trials are medium', () async {
    final updates = <List<Object>>[];
    final h = _Harness(
      native: NativeBridge(updateConversionValue: (fine, coarse, lockWindow) async => updates.add(<Object>[fine, coarse])),
    );
    final sdk = h.make();
    await sdk.start();
    sdk.trialStarted();
    sdk.purchased(500);
    await tick();
    expect(updates, <List<Object>>[
      <Object>[1, 'low'],
      <Object>[8, 'medium'],
      <Object>[63, 'high'],
    ]);
  });

  test('drops the oldest ordinary events past maxQueueSize and keeps first_open', () async {
    final h = _Harness(options: const _Opts(maxQueueSize: 3), statuses: <int>[-1]);
    final sdk = h.make();
    await sdk.start();
    await sdk.flush(force: true); // offline: everything stays queued
    for (var i = 0; i < 5; i++) {
      sdk.track('e$i');
    }
    await tick();
    expect(h.storedQueue().map((e) => (e as Map<String, dynamic>)['name']), <String>['first_open', 'e3', 'e4']);
  });

  test('past the quota (402) the install is delivered and other events wait in the queue', () async {
    final h = _Harness(statuses: <int>[402, 402, 202]);
    final sdk = h.make();
    await sdk.start();
    await sdk.flush(force: true);
    // The server stored the install, its attribution and first_open.
    expect(h.sent, hasLength(1));
    expect(h.sent[0].attribution, isNotNull);
    expect(h.queuedNames(), <String>['session_start']);
    expect(h.storedState()['attributionSent'], isTrue);

    // While waiting, only critical events go out, without the attribution.
    sdk.screen('Paywall');
    sdk.adRevenue(0.02);
    await tick();
    await sdk.flush(force: true);
    expect(h.sent, hasLength(2));
    expect(h.sent[1].events.map((e) => e['name']), <String>['ad_revenue']);
    expect(h.sent[1].body.containsKey('attribution'), isFalse);
    expect(h.queuedNames(), <String>['session_start', 'screen']);

    // Nothing ordinary is sent before the wait is over, even when forced.
    await sdk.flush(force: true);
    expect(h.sent, hasLength(2));

    h.advance(16 * 60 * 1000);
    await sdk.flush();
    expect(h.sent, hasLength(3));
    expect(h.sent[2].events.map((e) => e['name']), <String>['session_start', 'screen']);
    expect(h.queuedNames(), isEmpty);
  });

  test('a second quota answer doubles the wait and keeps the queue', () async {
    final h = _Harness(statuses: <int>[402, 402, 402]);
    final sdk = h.make();
    await sdk.start();
    await sdk.flush(force: true);
    h.advance(16 * 60 * 1000);
    await sdk.flush();
    expect(h.sent, hasLength(2));
    h.advance(16 * 60 * 1000); // the wait is 30 minutes now
    await sdk.flush();
    expect(h.sent, hasLength(2));
    h.advance(15 * 60 * 1000);
    await sdk.flush();
    expect(h.sent, hasLength(3));
    expect(h.queuedNames(), <String>['session_start']);
  });

  test('a rejected batch does not give up the attribution at once', () async {
    final h = _Harness(statuses: <int>[400, 202]);
    final sdk = h.make();
    await sdk.start();
    await sdk.flush(force: true);
    expect(h.sent, hasLength(1));
    expect(h.queuedNames(), isEmpty);
    expect(h.storedState()['attributionSent'], isNot(true));
    expect(h.storedState()['attributionRejects'], 1);

    sdk.screen('Home');
    await tick();
    await sdk.flush(force: true);
    expect(h.sent, hasLength(2));
    expect(h.sent[1].attribution, <String, Object?>{'deepLinkUrl': 'myapp://open?aky_c=launch'});
    expect(h.storedState()['attributionSent'], isTrue);
    expect(h.storedState().containsKey('attributionRejects'), isFalse);
  });

  test('the attribution is given up after three rejected batches', () async {
    final h = _Harness(statuses: <int>[400, 400, 400, 202]);
    final sdk = h.make();
    await sdk.start();
    await sdk.flush(force: true);
    for (final name in <String>['a', 'b']) {
      sdk.track(name);
      await tick();
      await sdk.flush(force: true);
    }
    expect(h.sent, hasLength(3));
    expect(h.storedState()['attributionSent'], isTrue);
    sdk.track('c');
    await tick();
    await sdk.flush(force: true);
    expect(h.sent[3].body.containsKey('attribution'), isFalse);
  });

  test('a full queue evicts ordinary events before first_open and ad revenue', () async {
    final h = _Harness(options: const _Opts(maxQueueSize: 3), statuses: <int>[-1]);
    final sdk = h.make();
    await sdk.start();
    await sdk.flush(force: true); // offline: session_start and first_open stay queued
    sdk.adRevenue(0.01);
    sdk.screen('A');
    sdk.screen('B');
    await tick();
    expect(h.queuedNames(), <String>['first_open', 'ad_revenue', 'screen']);
  });

  test("over-long attribution values are cut to the server's limits", () async {
    final h = _Harness(
      options: _Opts(getAdServicesToken: () async => 't' * 5000, resolveAdServicesOnDevice: false),
      native: NativeBridge(getInstallReferrer: () async => 'utm_source=${'x' * 3000}'),
    );
    final sdk = h.make();
    await sdk.start();
    await sdk.flush(force: true);
    expect((h.sent[0].attribution?['installReferrer'] as String).length, 2048);
    expect(h.sent[0].attribution?.containsKey('adServicesToken'), isFalse, reason: 'a cut token is useless');
  });

  test('flushes as soon as flushAt events are queued', () async {
    final h = _Harness(options: const _Opts(flushAt: 3));
    final sdk = h.make();
    await sdk.start();
    await sdk.flush(force: true);
    final before = h.sent.length;
    sdk.track('a');
    sdk.track('b');
    sdk.track('c');
    await tick();
    expect(h.sent.length, before + 1);
    expect(h.sent.last.events.map((e) => e['name']), <String>['a', 'b', 'c']);
  });

  test('cleans props, values and names to what the server accepts', () async {
    final h = _Harness();
    final sdk = h.make();
    await sdk.start();
    sdk.track('export', <String, Object?>{
      'k' * 70: 'v' * 600,
      'n': double.infinity,
      'ok': true,
      'none': null,
      'when': DateTime.utc(2026, 1, 2),
    }, double.nan);
    sdk.track('   ');
    sdk.screen('');
    sdk.screen('S' * 200);
    await tick();
    await sdk.flush(force: true);
    final events = h.allEvents.where((e) => e['name'] == 'export' || e['name'] == 'screen').toList();
    expect(events, hasLength(2));
    final props = events[0]['props'] as Map<String, dynamic>;
    expect(props['k' * 64], 'v' * 512);
    expect(props.containsKey('n'), isFalse);
    expect(props['ok'], isTrue);
    expect(props.containsKey('none'), isTrue);
    expect(props['when'], '2026-01-02 00:00:00.000Z');
    expect(events[0].containsKey('value'), isFalse);
    expect(events[1]['screen'], 'S' * 128);
  });

  test('a stored queue survives a restart and is sent', () async {
    final h = _Harness(statuses: <int>[-1]);
    final first = h.make();
    await first.start();
    first.track('offline_event');
    await tick();
    first.shutdown();

    final second = h.make();
    await second.start();
    await second.flush(force: true);
    expect(h.sent.last.events.map((e) => e['name']), containsAll(<String>['first_open', 'offline_event']));
    expect(h.sent.last.attribution, isNotNull, reason: 'attribution was never stored, so it goes again');
  });

  group('helpers', () {
    test('deferredDeepLinkFrom', () {
      expect(deferredDeepLinkFrom('aky_l=x&aky_dl=myapp%3A%2F%2Fa', null), 'myapp://a');
      expect(deferredDeepLinkFrom('utm_source=google-play&utm_medium=organic', null), isNull);
      expect(deferredDeepLinkFrom(null, 'myapp://open?aky_l=abc'), 'myapp://open?aky_l=abc');
      expect(deferredDeepLinkFrom(null, 'myapp://open?aky_c=launch'), isNull);
      expect(deferredDeepLinkFrom('aky_dl=%E0%A4%A', null), '%E0%A4%A', reason: 'malformed encoding falls back to raw');
    });

    test('truncate keeps surrogate pairs whole', () {
      expect(truncate('ab😀', 3), 'ab');
      expect(truncate('abc', 3), 'abc');
    });
  });
}
