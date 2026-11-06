import 'package:shared_preferences/shared_preferences.dart';

class PreferenceService {
  static const String _keyUsername = 'saved_username';

  // Save the username to local storage
  static Future<bool> saveUsername(String username) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return await prefs.setString(_keyUsername, username);
  }

  // Retrieve the username (returns null if never saved)
  static Future<String?> getUsername() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyUsername);
  }

  // Clear the username (useful for logging out or resetting)
  static Future<bool> clearUsername() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return await prefs.remove(_keyUsername);
  }
}
