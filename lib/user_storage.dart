import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class UserStorage {
  static const String _keyUsers = 'registered_users';

  static Future<List<Map<String, dynamic>>> getUsers() async {
    final prefs = await SharedPreferences.getInstance();
    final String? usersJson = prefs.getString(_keyUsers);
    if (usersJson == null) return [];
    
    List<dynamic> decoded = json.decode(usersJson);
    return decoded.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  static Future<void> saveUser(String username, String password) async {
    final prefs = await SharedPreferences.getInstance();
    List<Map<String, dynamic>> users = await getUsers();
    
    bool userExists = users.any((u) => u['username'] == username);
    if (userExists) {
      throw Exception("Exist na ang username na ito.");
    }

    users.add({'username': username, 'password': password});
    await prefs.setString(_keyUsers, json.encode(users));
  }

  static Future<bool> loginUser(String username, String password) async {
    List<Map<String, dynamic>> users = await getUsers();
    return users.any((u) => u['username'] == username && u['password'] == password);
  }
}
