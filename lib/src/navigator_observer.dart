import 'package:flutter/widgets.dart';

import 'appeeky.dart';

/// Screen name for a route; null skips it.
typedef AppeekyScreenNameExtractor = String? Function(RouteSettings settings);

/// Which routes count as screens.
typedef AppeekyRouteFilter = bool Function(Route<dynamic> route);

String? _defaultName(RouteSettings settings) => settings.name;

bool _defaultFilter(Route<dynamic> route) => route is PageRoute;

/// Records a screen view each time the visible page route changes: push,
/// replace, and pop back to the previous page. Dialogs, bottom sheets and
/// other non-page routes are skipped by default, and so are routes without
/// a name.
///
///     MaterialApp(navigatorObservers: [AppeekyNavigatorObserver()], ...)
class AppeekyNavigatorObserver extends NavigatorObserver {
  AppeekyNavigatorObserver({
    AppeekyScreenNameExtractor nameExtractor = _defaultName,
    AppeekyRouteFilter routeFilter = _defaultFilter,
    @visibleForTesting void Function(String name)? onScreen,
  })  : _nameExtractor = nameExtractor,
        _routeFilter = routeFilter,
        _onScreen = onScreen ?? Appeeky.screen;

  final AppeekyScreenNameExtractor _nameExtractor;
  final AppeekyRouteFilter _routeFilter;
  final void Function(String name) _onScreen;

  void _record(Route<dynamic>? route) {
    if (route == null || !_routeFilter(route)) return;
    final name = _nameExtractor(route.settings);
    if (name == null || name.trim().isEmpty) return;
    _onScreen(name);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _record(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => _record(newRoute);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // Closing a dialog leaves the same page on screen: not a new view.
    if (_routeFilter(route)) _record(previousRoute);
  }
}
