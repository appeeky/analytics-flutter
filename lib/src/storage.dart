import 'package:shared_preferences/shared_preferences.dart';

import 'core.dart';

/// [KeyValueStorage] on shared_preferences (NSUserDefaults / SharedPreferences).
class SharedPreferencesStorage implements KeyValueStorage {
  Future<SharedPreferences>? _prefs;

  Future<SharedPreferences> get _instance => _prefs ??= SharedPreferences.getInstance();

  @override
  Future<String?> getItem(String key) async => (await _instance).getString(key);

  @override
  Future<void> setItem(String key, String value) async {
    await (await _instance).setString(key, value);
  }
}
