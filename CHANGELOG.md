# Changelog

## 0.1.0

First version of the Flutter SDK, with the same behavior as the React Native
SDK (`@appeeky/analytics-expo` 0.1.2):

- Install id, persisted state and offline event queue (shared_preferences).
- Batching (every 10 s, at 20 queued events, on background), retries with
  backoff on network errors, 429 and 5xx, and dropping of batches the server
  rejects with another 4xx.
- Sessions with `session_start`, `app_background` (`foreground_ms`) and a
  30-minute timeout, from the app lifecycle.
- `first_open`, `screen`, `track`, `identify`, `adRevenue`, and
  `AppeekyNavigatorObserver` for screens from route names.
- First-launch attribution: Apple Search Ads token (exchanged with Apple on
  device), Play Install Referrer and the launch URL, plus the deferred deep
  link from a smart link.
- SKAdNetwork / AdAttributionKit conversion values (`trialStarted`,
  `purchased`).
- iOS: CocoaPods and Swift Package Manager; UIScene and app delegate
  lifecycles. Android: Kotlin, Play Install Referrer 2.2.
