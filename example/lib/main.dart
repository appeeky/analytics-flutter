import 'package:appeeky_analytics/appeeky_analytics.dart';
import 'package:flutter/material.dart';

// Pass your key and, when self-hosting, your server:
//   flutter run --dart-define=APPEEKY_KEY=apk_... \
//     --dart-define=APPEEKY_ENDPOINT=http://localhost:8787/v1/ingest
const String _key = String.fromEnvironment('APPEEKY_KEY', defaultValue: 'apk_example');
const String _endpoint = String.fromEnvironment('APPEEKY_ENDPOINT', defaultValue: defaultEndpoint);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Appeeky.init(key: _key, endpoint: _endpoint, debug: true);
  // With RevenueCat: Appeeky.identify(await Purchases.appUserID);
  Appeeky.identify('example_user');
  runApp(const ExampleApp());

  // First launch from a smart link: route to where the link pointed.
  final destination = await Appeeky.getDeferredDeepLink();
  if (destination != null) debugPrint('deferred deep link: $destination');
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Appeeky example',
      navigatorObservers: <NavigatorObserver>[AppeekyNavigatorObserver()],
      initialRoute: 'Home',
      routes: <String, WidgetBuilder>{
        'Home': (_) => const HomeScreen(),
        'Paywall': (_) => const PaywallScreen(),
      },
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('Install id: ${Appeeky.installId ?? '…'}'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).pushNamed('Paywall'),
              child: const Text('Open paywall'),
            ),
            TextButton(
              onPressed: () => Appeeky.track('onboarding_completed', <String, Object?>{'step': 3}),
              child: const Text('Track event'),
            ),
            const TextButton(onPressed: Appeeky.flush, child: Text('Flush')),
          ],
        ),
      ),
    );
  }
}

class PaywallScreen extends StatelessWidget {
  const PaywallScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Paywall')),
      body: Center(
        child: FilledButton(
          onPressed: () {
            // After a successful purchase: raises the SKAdNetwork conversion value.
            Appeeky.purchased(29.99);
            Navigator.of(context).pop();
          },
          child: const Text('Buy (demo)'),
        ),
      ),
    );
  }
}
