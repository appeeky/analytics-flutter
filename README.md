# appeeky_analytics

Flutter SDK for Appeeky Analytics. It records installs, sessions, screens and
your own events, and links each install to the RevenueCat or Superwall
customer, so your Appeeky Analytics server can show revenue by install
source: Apple Search Ads, a campaign or smart link, the Google Play referrer,
or organic store traffic.

- No IDFA, no App Tracking Transparency prompt. The install id is a random id
  stored in the app.
- Events are queued on the device and sent in batches. They survive offline
  periods and app restarts.
- The client runs in Dart. The plugin's native code (Swift on iOS, Kotlin on
  Android) only supplies the Apple Search Ads token, SKAdNetwork /
  AdAttributionKit conversion value updates, the Play Install Referrer, the
  URL that opened the app and device fields.

The package is not on pub.dev yet; add it from this repository.

## Install

Requires Flutter 3.38 or later, iOS 13+ and Android 5.0 (API 21)+.

```sh
flutter pub add appeeky_analytics
```

It depends on `http` and `shared_preferences`, nothing else.

### iOS

The plugin works with both CocoaPods and Swift Package Manager. Nothing has
to be added to `AppDelegate` or `SceneDelegate`: the plugin registers for
URL events itself, on the UIScene lifecycle (the default for new Flutter
apps) and on the older app delegate lifecycle.

To have iOS send copies of winning SKAdNetwork and AdAttributionKit
postbacks to Appeeky, add these keys to `ios/Runner/Info.plist`:

```xml
<key>NSAdvertisingAttributionReportEndpoint</key>
<string>https://appeeky.com</string>
<key>AdAttributionKit</key>
<dict>
  <key>AttributionCopyEndpoint</key>
  <string>https://appeeky.com</string>
</dict>
```

When self-hosting, use your server's registrable domain instead (see the
[self-hosting guide](https://docs.appeeky.com/docs/analytics-self-hosting)). Leave them out if another provider
already receives the copies: an app can name only one endpoint.

For campaign links that open the app, register its URL scheme
(`CFBundleURLTypes`) or associated domains as usual. If you use Flutter's
built-in deep linking (`FlutterDeepLinkingEnabled`) or a deep link package,
it keeps working: the plugin only reads the URL and never consumes it.

### Android

Nothing to add. The plugin uses the Play Install Referrer library (2.2) and
reads the data URI of the Intent that opened the app. Declare your
intent filters for app links or custom schemes as usual.

## Set up

Get the app's publishable key (`apk_…`): in Appeeky, turn on Analytics for
the app; on a self-hosted server, create the app (see the
[self-hosting guide](https://docs.appeeky.com/docs/analytics-self-hosting)). The key ships inside your app, so it
can only write events for that app.

```dart
import 'package:appeeky_analytics/appeeky_analytics.dart';
import 'package:flutter/material.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Appeeky.init(key: 'apk_...');
  // Self-hosted:
  // Appeeky.init(key: 'apk_...', endpoint: 'https://analytics.example.com/v1/ingest');

  // Link the install to RevenueCat so purchases get a source.
  Appeeky.identify(await Purchases.appUserID);
  runApp(const MyApp());
}
```

Call `identify` again with the new id after `Purchases.logIn()`, and pass
`null` on logout. With Superwall, pass the same user id you give
`Superwall.shared.identify(userId: ...)`; Superwall's webhook events are
matched to the install by it.

### Screens and events

```dart
Appeeky.screen('Paywall');
Appeeky.track('onboarding_completed', {'step': 3});
Appeeky.track('export', {'format': 'pdf'}, 1);
```

To record screens from route names, add the observer:

```dart
MaterialApp(
  navigatorObservers: [AppeekyNavigatorObserver()],
  // ...
)
```

It records a screen when a page route is pushed or replaced and when the
user goes back to the previous page. Dialogs, bottom sheets and routes
without a name are skipped. Pass `nameExtractor` to map `RouteSettings` to
your own screen names (return `null` to skip a route), or `routeFilter` to
change which routes count. With go_router, give your routes a `name` or add
the observer to the `GoRouter(observers: [...])` list.

Event names may use letters, digits, `_`, `.`, `:` and `-`, up to 64
characters. Prop values are strings (up to 512 characters), numbers, booleans
or `null`; other values are sent as their `toString()`.

### What is collected automatically

| Event | When |
| --- | --- |
| `first_open` | First launch after install |
| `session_start` | Launch, or returning after `sessionTimeout` in the background |
| `app_background` | Going to the background, with `foreground_ms`: time on screen since the app came to the foreground. Session time is the sum per session. |
| `identify` / `reset` | `identify(id)` / `identify(null)` |
| `ad_revenue` | `adRevenue(valueUsd, ...)` |

### Smart links and deep links

Create a smart link for a campaign in Appeeky (or `POST /v1/apps/:id/links`
on your server). One link works everywhere:

- **Android:** sends the visitor to Google Play with the campaign and the
  in-app destination in the install referrer. On the first launch after
  install, `getDeferredDeepLink()` returns that destination, and the install
  is attributed to the link exactly.
- **iOS:** opens the app through its URL scheme when it is installed (the
  campaign is appended to the URL), otherwise the App Store. iOS has no
  deferred deep link here: matching an App Store install back to a click
  needs device fingerprinting, which Apple doesn't allow.

```dart
// First launch: route the user to where the link pointed.
final destination = await Appeeky.getDeferredDeepLink();
if (destination != null) {
  // e.g. navigatorKey.currentState?.pushNamed(Uri.parse(destination).path);
}
```

The URL that opened the app on its first launch is sent as attribution, so
`aky_c=<campaign>` and `utm_*` parameters on any link are attributed too. If
your app gets the launch URL some other way that the plugin can't see, pass
`getLaunchUrl` to `init`; it is used when the plugin has no URL.

### SKAdNetwork conversion values

On iOS the SDK keeps the SKAdNetwork / AdAttributionKit conversion value up
to date so paid campaigns report what installs did. Values only go up:

| Fine value | Coarse | Set by |
| --- | --- | --- |
| 1 | low | first launch (automatic) |
| 2 | medium | came back on a later day (automatic) |
| 8 | medium | `Appeeky.trialStarted()` |
| 16–63 | high | `Appeeky.purchased(valueUsd)`: 16 + $2 steps, capped at $94+ |

```dart
// After a RevenueCat purchase succeeds:
Appeeky.purchased(29.99);
```

`purchased()` and `trialStarted()` only update the conversion value; revenue
itself comes from RevenueCat or Superwall, so nothing is counted twice.

### Ad revenue

```dart
// google_mobile_ads paid event
onPaidEvent: (ad, valueMicros, precision, currencyCode) {
  if (currencyCode == 'USD') {
    Appeeky.adRevenue(valueMicros / 1e6, network: 'admob', adUnit: 'rewarded_home', format: 'rewarded');
  }
},
```

## Attribution

| Source | How it is detected |
| --- | --- |
| Campaign link | The URL the app was first opened with carries `aky_c=<campaign>` or `utm_*` parameters. |
| Smart link | Android: the Play install referrer names the link. iOS: the link opened the app on its first launch. |
| Apple Search Ads | Automatic on iOS 14.3+. The SDK exchanges the token with Apple for the campaign, ad group and keyword, and sends both. If Apple doesn't answer yet, the server retries with the token for up to 24 hours. |
| Google Play referrer | Automatic on Android. Appeeky reads the `utm_*` parameters. |
| Organic | Everything else: store search, browse, and installs with no campaign. |

Attribution is collected once, on the first launch. Each source has 3
seconds to answer. `getAdServicesToken` and `getInstallReferrer` in `init`
replace the plugin's own.

## API

| | |
| --- | --- |
| `Appeeky.init(key:, endpoint:, debug:, ...)` | Start the SDK; later calls return the first client |
| `Appeeky.screen(name, [properties])` | Screen view |
| `Appeeky.track(name, [properties, value])` | Custom event |
| `Appeeky.identify(userId)` | RevenueCat / Superwall user id, or `null` |
| `Appeeky.getDeferredDeepLink()` | Smart link destination on first launch, once |
| `Appeeky.trialStarted()`, `Appeeky.purchased(valueUsd)` | SKAdNetwork conversion value |
| `Appeeky.adRevenue(valueUsd, network:, adUnit:, format:)` | Ad revenue in USD |
| `Appeeky.flush()` | Send queued events now |
| `Appeeky.installId` | Random install id (null until the SDK has loaded it) |
| `Appeeky.shutdown()` | Stop timers and the lifecycle observer |
| `AppeekyNavigatorObserver` | Screens from route names |

### `init` options

| Option | Default | |
| --- | --- | --- |
| `key` | required | Publishable key (`apk_…`) |
| `endpoint` | Appeeky hosted | A self-hosted server's ingest URL, ending in `/v1/ingest` |
| `debug` | `false` | Log sends, rejected batches and network errors |
| `resolveAdServicesOnDevice` | `true` | Exchange the AdServices token with Apple from the device |
| `flushInterval` | 10 s | How often queued events are sent while the app is open |
| `flushAt` | `20` | Send as soon as this many events are queued |
| `maxQueueSize` | `1000` | Oldest events are dropped beyond this |
| `sessionTimeout` | 30 min | Time in the background before a new session starts |
| `context` | | `DeviceContext` fields that override the detected ones |
| `getLaunchUrl` | | Fallback for the URL that opened the app |
| `disabled` | `false` | Collect and send nothing, for example after an opt-out |

## Privacy

The SDK sends the install id, app version and build, OS version, device
model, locale and the events you track. It never reads advertising
identifiers. In App Store Connect, declare **Usage Data → Product
Interaction** and **Purchases** as *not linked to the user's identity* and
*not used for tracking*. If your RevenueCat app user id is a real account id,
declare those data types as *linked* instead. On Google Play, declare the
same in the Data safety form (App activity, Purchase history).

## Develop

```sh
flutter pub get
flutter analyze
flutter test
cd example
flutter create --platforms=ios,android .   # platform folders stay local
flutter run --dart-define=APPEEKY_KEY=apk_... --dart-define=APPEEKY_ENDPOINT=http://localhost:8787/v1/ingest
```

## License

[FSL-1.1-MIT](LICENSE).
