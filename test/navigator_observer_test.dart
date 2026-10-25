import 'package:appeeky_analytics/appeeky_analytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('records page routes on push, replace and pop back', (tester) async {
    final screens = <String>[];
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      navigatorObservers: <NavigatorObserver>[AppeekyNavigatorObserver(onScreen: screens.add)],
      initialRoute: 'Home',
      onGenerateRoute: (settings) => MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => Text('${settings.name}', textDirection: TextDirection.ltr),
      ),
    ));
    expect(screens, <String>['Home']);

    navigatorKey.currentState!.pushNamed('Paywall');
    await tester.pumpAndSettle();
    expect(screens, <String>['Home', 'Paywall']);

    // A dialog is not a screen, and closing it is not a new view.
    showDialog<void>(context: navigatorKey.currentContext!, builder: (_) => const Text('dialog'));
    await tester.pumpAndSettle();
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(screens, <String>['Home', 'Paywall']);

    navigatorKey.currentState!.pushReplacementNamed('Settings');
    await tester.pumpAndSettle();
    expect(screens, <String>['Home', 'Paywall', 'Settings']);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(screens, <String>['Home', 'Paywall', 'Settings', 'Home']);
  });

  testWidgets('skips unnamed routes and uses a custom name', (tester) async {
    final screens = <String>[];
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      navigatorObservers: <NavigatorObserver>[
        AppeekyNavigatorObserver(
          onScreen: screens.add,
          nameExtractor: (settings) => settings.name == null ? null : 'screen:${settings.name}',
        ),
      ],
      home: const Text('home', textDirection: TextDirection.ltr),
    ));
    navigatorKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Text('anon')));
    await tester.pumpAndSettle();
    navigatorKey.currentState!.push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'Detail'),
      builder: (_) => const Text('detail'),
    ));
    await tester.pumpAndSettle();
    // `home` is the route named "/".
    expect(screens, <String>['screen:/', 'screen:Detail']);
  });
}
