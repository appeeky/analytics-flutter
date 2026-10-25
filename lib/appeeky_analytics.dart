/// Appeeky Analytics for Flutter.
///
///     Appeeky.init(key: 'apk_...');
///     Appeeky.screen('Paywall');
///     Appeeky.track('onboarding_completed', {'step': 3});
///     Appeeky.identify(await Purchases.appUserID);
library;

export 'src/appeeky.dart' show Appeeky;
export 'src/core.dart'
    show
        AppeekyAnalytics,
        AppeekyOptions,
        AppeekyScheduler,
        CoreDeps,
        DeviceContext,
        KeyValueStorage,
        NativeBridge,
        TimerScheduler,
        defaultEndpoint,
        sdkVersion;
export 'src/navigator_observer.dart';
export 'src/storage.dart' show SharedPreferencesStorage;
