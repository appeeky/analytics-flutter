# Changelog

## 0.2.0

- When the account's event quota is used up (HTTP 402), the SDK no longer
  drops the queue. The server still stores the install, its source and the
  `first_open` and `ad_revenue` events; the other events wait on the device
  and are sent again later (after 15 minutes, doubling up to 6 hours).
  `first_open` and `ad_revenue` keep being sent while waiting.
- A batch the server rejects with another 4xx no longer loses the install
  source at once: the attribution is sent again with the next batches and is
  given up only after three rejections.
- A full queue drops the oldest ordinary events first; `first_open` and
  `ad_revenue` are dropped only when nothing else is left.
- An Apple Search Ads token longer than the server accepts (4096 characters)
  is left out instead of being cut.

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
