import 'package:shared_preferences/shared_preferences.dart';

class PreferenceService {
  static const String _usernameKey = 'saved_username';
  static const String _roomSecretKey = 'family_room_secret';

  static Future<void> saveSettings({
    required String username,
    required String roomSecret,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_usernameKey, username.trim());
    await prefs.setString(_roomSecretKey, roomSecret.trim());
  }

  static Future<String?> getUsername() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_usernameKey);
  }

  static Future<String?> getRoomSecret() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_roomSecretKey);
  }

  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_usernameKey);
    await prefs.remove(_roomSecretKey);
  }
}
