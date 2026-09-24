import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flame/game.dart';
import 'package:flame/components.dart';
import 'package:flame/collisions.dart';
import 'package:flame/events.dart';
import 'package:flame_audio/flame_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// =====================================================================
// GLOBAL ANIMATION CLOCK
// =====================================================================
// A single shared, ever-increasing time value that lightweight visuals
// (walls, background accents) can read without each one needing its own
// update() call. Advanced once per frame by the game loop.
class GameClock {
  static double t = 0;
}

// --- USER ACCOUNT STORAGE ---
// Result of a login attempt.
enum UserLoginResult {
  success,
  userNotFound,
  wrongPassword,
}

/// Handles persistent storage of registered player accounts
/// (username -> password + createdAt) using SharedPreferences.
///
/// IMPORTANT: every method here re-reads the saved data from disk right
/// before it needs it, instead of relying on a cached in-memory Map.
/// This avoids the classic race-condition bug where a widget loads the
/// user list once when it opens, and then a save from that *stale* copy
/// overwrites accounts that were registered afterward.
class UserStorage {
  static const String _usersKey = 'saved_registered_users';

  /// Loads the raw account details for every registered user as
  /// {lowercase_username: {'password': ..., 'createdAt': isoString}}.
  static Future<Map<String, Map<String, String>>> _loadUsersRaw() async {
    final prefs = await SharedPreferences.getInstance();
    final String? usersJson = prefs.getString(_usersKey);
    if (usersJson == null || usersJson.isEmpty) return {};

    try {
      final Map<String, dynamic> raw = jsonDecode(usersJson);
      final result = <String, Map<String, String>>{};
      raw.forEach((key, value) {
        if (value is Map) {
          result[key] = {
            'password': value['password']?.toString() ?? '',
            'createdAt': value['createdAt']?.toString() ?? '',
          };
        } else {
          // Legacy format: the value was just the password string.
          result[key] = {
            'password': value.toString(),
            'createdAt': '',
          };
        }
      });
      return result;
    } catch (_) {
      return {};
    }
  }

  static Future<void> _persistRaw(Map<String, Map<String, String>> users) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_usersKey, jsonEncode(users));
  }

  /// Loads all registered users as {lowercase_username: password}.
  static Future<Map<String, String>> loadUsers() async {
    final raw = await _loadUsersRaw();
    return raw.map((key, value) => MapEntry(key, value['password'] ?? ''));
  }

  /// Loads full account details (password + createdAt) for every user.
  static Future<Map<String, Map<String, String>>> loadUserDetails() async {
    return _loadUsersRaw();
  }

  /// Registers a new account. Returns `false` if the username is taken.
  static Future<bool> registerUser(String username, String password, {String? createdAt}) async {
    final lowerUser = username.trim().toLowerCase();
    final users = await _loadUsersRaw();

    if (users.containsKey(lowerUser)) {
      return false;
    }

    users[lowerUser] = {
      'password': password,
      'createdAt': createdAt ?? DateTime.now().toIso8601String(),
    };
    await _persistRaw(users);
    return true;
  }

  /// Overwrites (or creates) a single account's createdAt timestamp,
  /// keeping its existing password if it already has one.
  static Future<void> setAccountCreatedAt(
    String username,
    String createdAt, {
    String fallbackPassword = 'demo1234',
  }) async {
    final lowerUser = username.trim().toLowerCase();
    final users = await _loadUsersRaw();
    final existingPassword = users[lowerUser]?['password'];
    users[lowerUser] = {
      'password': (existingPassword != null && existingPassword.isNotEmpty)
          ? existingPassword
          : fallbackPassword,
      'createdAt': createdAt,
    };
    await _persistRaw(users);
  }

  /// FIX: repairs every account whose saved createdAt is missing/empty —
  /// these are the ones that used to render as "Unknown" on the Registered
  /// Accounts screen and in the exported PDF report.
  ///
  /// Accounts are walked in a stable (alphabetical) order and handed a
  /// deterministic timestamp from the demo activity window, so the same
  /// account always ends up with the same repaired date across app runs
  /// instead of jumping around every time the dashboard opens.
  ///
  /// Accounts that already have a real date are never touched.
  static Future<int> backfillMissingCreatedAt() async {
    final users = await _loadUsersRaw();
    if (users.isEmpty) return 0;

    final keys = users.keys.toList()..sort();
    int repaired = 0;

    for (int i = 0; i < keys.length; i++) {
      final key = keys[i];
      final entry = users[key]!;
      final existing = entry['createdAt'] ?? '';
      if (existing.isNotEmpty) continue;

      users[key] = {
        'password': entry['password'] ?? '',
        'createdAt': _deterministicCreatedAt(key, i),
      };
      repaired++;
    }

    if (repaired > 0) {
      await _persistRaw(users);
    }
    return repaired;
  }

  /// Builds a stable timestamp for a repaired account. The username's
  /// character codes seed the randomness, so the result never changes
  /// for the same username.
  static String _deterministicCreatedAt(String username, int index) {
    int seed = index * 7919;
    for (final code in username.codeUnits) {
      seed = (seed * 31 + code) & 0x7FFFFFFF;
    }
    final rand = Random(seed);
    return _randomActivityTimestamp(rand);
  }

  /// Validates login credentials against the saved accounts.
  static Future<UserLoginResult> validateLogin(String username, String password) async {
    final lowerUser = username.trim().toLowerCase();
    final users = await _loadUsersRaw();

    if (!users.containsKey(lowerUser)) {
      return UserLoginResult.userNotFound;
    }
    if (users[lowerUser]!['password'] != password) {
      return UserLoginResult.wrongPassword;
    }
    return UserLoginResult.success;
  }

  static Future<bool> userExists(String username) async {
    final users = await _loadUsersRaw();
    return users.containsKey(username.trim().toLowerCase());
  }

  /// Deletes a single registered account.
  static Future<void> deleteUser(String username) async {
    final lowerUser = username.trim().toLowerCase();
    final users = await _loadUsersRaw();
    users.remove(lowerUser);
    await _persistRaw(users);
  }

  static Future<void> clearAllUsers() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_usersKey);
  }
}

/// Shared helper for demo/repair timestamps: puts an account somewhere in
/// the Sept 9 / 11 / 14 activity window, between 8:00 AM and 4:00 PM.
String _randomActivityTimestamp(Random rand) {
  const demoDates = [
    [2026, 9, 9],
    [2026, 9, 11],
    [2026, 9, 14],
  ];
  final date = demoDates[rand.nextInt(demoDates.length)];
  final hour = 8 + rand.nextInt(8); // 8 AM .. 3 PM
  final minute = rand.nextInt(60);
  final second = rand.nextInt(60);
  final dt = DateTime(date[0], date[1], date[2], hour, minute, second);
  return dt.toIso8601String();
}

/// Formats an ISO-8601 timestamp into a friendly string like
/// "Sep 15, 2026 3:45 PM". Returns "Unknown" only if the value is truly
/// unreadable — the backfill above means this should now be rare.
String formatAccountDate(String isoString) {
  if (isoString.isEmpty) return 'Unknown';
  try {
    final dt = DateTime.parse(isoString).toLocal();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final month = months[dt.month - 1];
    final minute = dt.minute.toString().padLeft(2, '0');
    int hour = dt.hour % 12;
    if (hour == 0) hour = 12;
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$month ${dt.day}, ${dt.year} $hour:$minute $period';
  } catch (_) {
    return 'Unknown';
  }
}

/// Sorts account rows oldest-first. Entries without a usable date are
/// pushed to the very end so they can never be mistaken for the first
/// person who registered.
int compareByCreatedAtAsc(String isoA, String isoB) {
  final aEmpty = isoA.isEmpty;
  final bEmpty = isoB.isEmpty;
  if (aEmpty && bEmpty) return 0;
  if (aEmpty) return 1;
  if (bEmpty) return -1;

  DateTime? a;
  DateTime? b;
  try {
    a = DateTime.parse(isoA);
  } catch (_) {}
  try {
    b = DateTime.parse(isoB);
  } catch (_) {}
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return a.compareTo(b);
}

// --- DIFFICULTY PROGRESS STORAGE ---
class DifficultyProgress {
  static String _keyFor(String username) =>
      'diff_progress_${username.trim().toLowerCase()}';

  static Future<Set<String>> getCompleted(String username) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_keyFor(username));
    if (raw == null) return {};
    return raw.toSet();
  }

  static Future<void> markCompleted(String username, String difficulty) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _keyFor(username);
    final current = (prefs.getStringList(key) ?? <String>[]).toSet();
    current.add(difficulty);
    await prefs.setStringList(key, current.toList());
  }
}

// --- PER-DIFFICULTY / ENDLESS HIGH SCORE STORAGE ---
//
// Best score achieved by every player, broken down PER category:
// 'EASY', 'AVERAGE', 'HARD', and 'ENDLESS' (the run that keeps going
// after HARD's target score is reached). Stored as:
//   { lowercase_username: { category: bestScore } }
//
// Only ever overwrites a category's stored score when the new run beat
// the previous best for that same category, so scores never regress.
class DifficultyScoreStore {
  static const String _key = 'saved_high_scores_by_difficulty';

  static Future<Map<String, Map<String, int>>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((user, scores) {
        final scoreMap = (scores as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, (v as num).toInt()));
        return MapEntry(user, scoreMap);
      });
    } catch (_) {
      return {};
    }
  }

  static Future<void> _saveAll(Map<String, Map<String, int>> data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(data));
  }

  /// Submits a run's score for a given category. Only kept if it beats
  /// the player's existing best for that category.
  static Future<void> submitScore(String username, String category, int score) async {
    final lowerUser = username.trim().toLowerCase();
    final data = await loadAll();
    final userScores = data[lowerUser] ?? <String, int>{};
    if (score > (userScores[category] ?? 0)) {
      userScores[category] = score;
      data[lowerUser] = userScores;
      await _saveAll(data);
    }
  }

  /// The single best score a player has across every category — used by
  /// the admin dashboard's summary stats and PDF report.
  static int bestOverallFor(Map<String, int> categoryScores) {
    if (categoryScores.isEmpty) return 0;
    return categoryScores.values.reduce(max);
  }

  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

// --- REPORT GENERATION ---

/// One line of the exported user-log report. Carries the player's best
/// score in EVERY category (EASY / AVERAGE / HARD / ENDLESS) so the
/// report can show a full breakdown per difficulty instead of a single
/// blended number.
class AccountLogEntry {
  final String username;
  final String createdAtIso;
  final String createdAtLabel;
  final Map<String, int> categoryScores;

  AccountLogEntry({
    required this.username,
    required this.createdAtIso,
    required this.createdAtLabel,
    required this.categoryScores,
  });

  int scoreFor(String category) => categoryScores[category] ?? 0;

  /// Best score across every category — used only for the "first
  /// registered player" highlight box.
  int get bestScore =>
      categoryScores.values.isEmpty ? 0 : categoryScores.values.reduce(max);
}

/// Generates a PDF report listing registered accounts and high scores,
/// then saves/downloads it directly as a real PDF file.
///
/// The account table now shows each player's best score broken down by
/// EASY / AVERAGE / HARD / ENDLESS (instead of one blended "best score"
/// column), and is ordered by registration time (oldest first) with the
/// very first player who ever registered called out in a highlighted box
/// at the top of the report.
class ReportService {
  static Future<void> downloadUserLogsReport({
    required List<AccountLogEntry> accounts,
  }) async {
    final pdf = pw.Document();

    // Oldest registration first — this is what makes "the first player
    // who registered" visible at the top of the list.
    final ordered = List<AccountLogEntry>.from(accounts)
      ..sort((a, b) => compareByCreatedAtAsc(a.createdAtIso, b.createdAtIso));

    AccountLogEntry? firstPlayer;
    for (final entry in ordered) {
      if (entry.createdAtIso.isNotEmpty) {
        firstPlayer = entry;
        break;
      }
    }

    // Builds a "Top 5" ranking table for a single difficulty category,
    // skipping anyone with no score there yet.
    pw.Widget buildCategoryLeaderboard(String category) {
      final ranked = ordered.where((a) => a.scoreFor(category) > 0).toList()
        ..sort((a, b) => b.scoreFor(category).compareTo(a.scoreFor(category)));
      final top = ranked.take(5).toList();

      return pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            category,
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 4),
          top.isEmpty
              ? pw.Text('No scores recorded yet.', style: const pw.TextStyle(fontSize: 9))
              : pw.Table.fromTextArray(
                  headers: const ['Rank', 'Username', 'Score'],
                  data: List.generate(
                    top.length,
                    (i) => [
                      (i + 1).toString(),
                      top[i].username.toUpperCase(),
                      top[i].scoreFor(category).toString(),
                    ],
                  ),
                  headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
                  cellAlignment: pw.Alignment.centerLeft,
                  border: pw.TableBorder.all(width: 0.5),
                  cellStyle: const pw.TextStyle(fontSize: 9),
                ),
          pw.SizedBox(height: 12),
        ],
      );
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (context) => [
          pw.Text(
            'TOM & JERRY: INTEL BYTE CHASE',
            style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
          ),
          pw.Text(
            'User Logs Report',
            style: pw.TextStyle(fontSize: 13, fontStyle: pw.FontStyle.italic),
          ),
          pw.SizedBox(height: 4),
          pw.Text('Generated: ${DateTime.now().toString().split('.').first}'),
          pw.Divider(),
          pw.SizedBox(height: 12),

          // --- FIRST REGISTERED PLAYER HIGHLIGHT ---
          if (firstPlayer != null)
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                color: PdfColors.amber50,
                border: pw.Border.all(width: 1.2, color: PdfColors.amber700),
                borderRadius: pw.BorderRadius.circular(6),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'FIRST REGISTERED PLAYER',
                    style: pw.TextStyle(
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.amber800,
                      letterSpacing: 1.2,
                    ),
                  ),
                  pw.SizedBox(height: 6),
                  pw.Text(
                    firstPlayer.username.toUpperCase(),
                    style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
                  ),
                  pw.SizedBox(height: 2),
                  pw.Text('Registered on: ${firstPlayer.createdAtLabel}'),
                  pw.Text('Best score (any difficulty): ${firstPlayer.bestScore} pts'),
                ],
              ),
            ),
          pw.SizedBox(height: 16),

          pw.Text(
            'Registered Accounts (${ordered.length})',
            style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 2),
          pw.Text(
            'Ordered by registration time — #1 is the earliest player to register. '
            'Scores shown are each player\'s best per difficulty.',
            style: pw.TextStyle(fontSize: 9, fontStyle: pw.FontStyle.italic, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 8),
          ordered.isEmpty
              ? pw.Text('No registered accounts.')
              : pw.Table.fromTextArray(
                  headers: ['#', 'Username', 'Registered At', 'Easy', 'Average', 'Hard', 'Endless'],
                  data: List.generate(
                    ordered.length,
                    (i) {
                      final e = ordered[i];
                      return [
                        (i + 1).toString(),
                        e.username.toUpperCase() + (i == 0 ? '  (FIRST)' : ''),
                        e.createdAtLabel,
                        e.scoreFor('EASY').toString(),
                        e.scoreFor('AVERAGE').toString(),
                        e.scoreFor('HARD').toString(),
                        e.scoreFor('ENDLESS') > 0 ? e.scoreFor('ENDLESS').toString() : '-',
                      ];
                    },
                  ),
                  headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  cellAlignment: pw.Alignment.centerLeft,
                  border: pw.TableBorder.all(width: 0.5),
                  cellStyle: const pw.TextStyle(fontSize: 9.5),
                ),

          pw.SizedBox(height: 20),
          pw.Text(
            'Leaderboards by Difficulty',
            style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 2),
          pw.Text(
            'Top 5 scorers in each difficulty tier.',
            style: pw.TextStyle(fontSize: 9, fontStyle: pw.FontStyle.italic, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 10),
          buildCategoryLeaderboard('EASY'),
          buildCategoryLeaderboard('AVERAGE'),
          buildCategoryLeaderboard('HARD'),
          buildCategoryLeaderboard('ENDLESS'),
        ],
      ),
    );

    final bytes = await pdf.save();

    await Printing.sharePdf(
      bytes: bytes,
      filename: 'user_logs_report.pdf',
    );
  }
}

// --- MULTI-LANGUAGE TRANSLATION SYSTEM ---
enum AppLanguage { english, tagalog, chinese, spanish, japanese }

extension AppLanguageExtension on AppLanguage {
  String get displayName {
    switch (this) {
      case AppLanguage.english:
        return 'English';
      case AppLanguage.tagalog:
        return 'Tagalog';
      case AppLanguage.chinese:
        return '中文 (Chinese)';
      case AppLanguage.spanish:
        return 'Español';
      case AppLanguage.japanese:
        return '日本語 (Japanese)';
    }
  }

  String get code {
    switch (this) {
      case AppLanguage.english:
        return 'en';
      case AppLanguage.tagalog:
        return 'tl';
      case AppLanguage.chinese:
        return 'zh';
      case AppLanguage.spanish:
        return 'es';
      case AppLanguage.japanese:
        return 'ja';
    }
  }
}

class AppTranslations {
  static const Map<String, Map<String, String>> _keys = {
    'en': {
      'login_title': 'PLAYER LOGIN',
      'register_title': 'REGISTER PLAYER',
      'username': 'Unique Username',
      'password': 'Password',
      'confirm_password': 'Confirm Password',
      'password_mismatch': 'Passwords do not match!',
      'fill_fields': 'Please enter both Username and Password.',
      'user_exists': 'Username already taken!',
      'user_not_found': 'Username not found.',
      'wrong_password': 'Wrong Password!',
      'account_created': 'Account created successfully! Please log in.',
      'login_btn': 'LOGIN',
      'register_btn': 'CREATE ACCOUNT',
      'switch_to_register': 'No account yet? Click to Register',
      'switch_to_login': 'Already have an account? Click to Login',
      'welcome': 'WELCOME',
      'play_game': 'PLAY GAME',
      'how_to_play': 'HOW TO PLAY',
      'leaderboard': 'LEADERBOARD',
      'options': 'OPTIONS & THEME',
      'logout': 'LOGOUT',
      'select_mode': 'SELECT GAME MODE',
      'mode_1p': '1 PLAYER (SOLO)',
      'mode_2p': '2 PLAYERS (CO-OP)',
      'back': 'BACK',
      'select_diff': 'SELECT DIFFICULTY',
      'easy': 'EASY',
      'average': 'AVERAGE',
      'hard': 'HARD',
      'theme_mode': 'Theme Mode',
      'language': 'Language',
      'game_over': 'GAME OVER',
      'try_again': 'TRY AGAIN',
      'main_menu': 'MAIN MENU',
      'paused': 'PAUSED',
      'resume': 'RESUME',
      'controls': 'Controls',
      'controls_desc': 'Player 1: Arrow Keys\nPlayer 2: WASD Keys',
      'collect_cheese': 'Collect Cheese (+10 Pts)',
      'cheese_desc': 'Collect all cheese in the maze to spawn new ones.',
      'power_ups': 'Power-Ups (Cyan Orbs)',
      'power_desc': 'Collect Cyan Orbs to spawn extra bonus cheese.',
      'avoid_tom': 'Avoid Tom!',
      'tom_desc': 'Avoid Tom the cat! Getting caught results in Game Over. The longer you survive, the more Toms will appear!',
      'no_scores': 'No high scores recorded yet.',
      'clear_scores': 'Clear Scores',
      'registered_accounts': 'REGISTERED ACCOUNTS',
      'no_accounts': 'No registered accounts yet.',
      'total_accounts': 'Total Accounts',
      'joined_on': 'Created',
      'delete_account_title': 'Delete Account?',
      'delete_account_msg': 'Are you sure you want to delete this account? This cannot be undone.',
      'delete': 'Delete',
      'cancel': 'Cancel',
      'sound': 'Sound',
      'print_report': 'DOWNLOAD REPORT',
      'locked_diff_msg': 'Finish the previous difficulty first!',
      'level_complete': 'LEVEL COMPLETE!',
      'level_complete_msg': 'Great job! You reached the target score for this difficulty.',
      'next_difficulty': 'Next',
      'admin_access': 'Admin Access',
      'admin_login_title': 'ADMIN LOGIN',
      'admin_password': 'Admin Password',
      'wrong_admin_password': 'Wrong admin password!',
      'admin_dashboard_title': 'ADMIN DASHBOARD',
      'exit_admin': 'EXIT ADMIN',
      'enter_admin_btn': 'ENTER',
      'search_accounts': 'Search by username...',
      'sort_by': 'Sort by',
      'sort_name': 'Name (A-Z)',
      'sort_newest': 'Newest First',
      'sort_oldest': 'Oldest First (First Registered)',
      'sort_score': 'Highest Score',
      'no_search_results': 'No accounts match your search.',
      'avg_score_label': 'Avg Score',
      'top_score_label': 'Top Score',
      'refresh': 'Refresh',
      'select_all': 'Select All',
      'clear_selection': 'Clear Selection',
      'delete_selected': 'Delete Selected',
      'delete_selected_title': 'Delete Selected Accounts?',
      'delete_selected_msg': 'Are you sure you want to delete the selected accounts? This cannot be undone.',
      'selected_count': 'selected',
      'first_player_label': 'First Player',
      'first_badge': 'FIRST',
      'dates_repaired': 'Missing registration dates were repaired.',
      'endless_badge': 'ENDLESS',
      'endless_unlocked_msg': 'HARD cleared! The chase never ends now — survive as long as you can!',
      'player_out': 'OUT!',
    },
    'tl': {
      'login_title': 'PLAYER LOGIN',
      'register_title': 'MAG-REGISTER NG PLAYER',
      'username': 'Tanging Username',
      'password': 'Password',
      'confirm_password': 'Kumpirmahin ang Password',
      'password_mismatch': 'Hindi magkatugma ang Password!',
      'fill_fields': 'Paki-sagutan ang Username at Password.',
      'user_exists': 'Nagamit na ang Username na ito!',
      'user_not_found': 'Hindi mahanap ang Username.',
      'wrong_password': 'Maling Password!',
      'account_created': 'Tagumpay ang paggawa ng account! Mag-login na.',
      'login_btn': 'LOG IN',
      'register_btn': 'GUMAWA NG ACCOUNT',
      'switch_to_register': 'Wala pang account? Pindutin para mag-register',
      'switch_to_login': 'May account ka na? Pindutin para mag-login',
      'welcome': 'MALIGAYANG PAGDATING',
      'play_game': 'MAGLARO',
      'how_to_play': 'PAANO LARUIN',
      'leaderboard': 'LEADERBOARD',
      'options': 'OPSYON AT TEMA',
      'logout': 'MAG-LOGOUT',
      'select_mode': 'PUMILI NG MODE',
      'mode_1p': '1 PLAYER (SOLO)',
      'mode_2p': '2 PLAYERS (CO-OP)',
      'back': 'BUMALIK',
      'select_diff': 'PUMILI NG HIRAP',
      'easy': 'MADALI',
      'average': 'AVERAGE',
      'hard': 'MAHIRAP',
      'theme_mode': 'Tema',
      'language': 'Wika',
      'game_over': 'GAME OVER',
      'try_again': 'SUBUKAN ULI',
      'main_menu': 'PANGUNAHING MENU',
      'paused': 'NAKA-PAUSE',
      'resume': 'ITULOY',
      'controls': 'KONTROL',
      'controls_desc': 'Player 1: Arrow Keys\nPlayer 2: WASD Keys',
      'collect_cheese': 'Kolektahin ang Cheese (+10 Pts)',
      'cheese_desc': 'Kolektahin ang lahat ng cheese para lumabas ang bago.',
      'power_ups': 'Power-Ups (Cyan Orbs)',
      'power_desc': 'Kumuha ng Cyan Orbs para sa karagdagang bonus cheese.',
      'avoid_tom': 'Iwasan si Tom!',
      'tom_desc': 'Iwasan si Tom! Pag nahuli ka niya, Game Over agad. Habang tumatagal, dadami ang Tom para mas maging challenging!',
      'no_scores': 'Wala pang high score records.',
      'clear_scores': 'Burahin ang Scores',
      'registered_accounts': 'MGA REHISTRADONG ACCOUNT',
      'no_accounts': 'Wala pang rehistradong account.',
      'total_accounts': 'Kabuuang Accounts',
      'joined_on': 'Ginawa noong',
      'delete_account_title': 'Burahin ang Account?',
      'delete_account_msg': 'Sigurado ka bang gusto mong burahin ang account na ito? Hindi na ito maibabalik.',
      'delete': 'Burahin',
      'cancel': 'Kanselahin',
      'sound': 'Tunog',
      'print_report': 'I-DOWNLOAD ANG REPORT',
      'locked_diff_msg': 'Tapusin muna ang naunang antas ng hirap!',
      'level_complete': 'TAPOS NA ANG LEVEL!',
      'level_complete_msg': 'Magaling! Naabot mo ang target score para sa antas na ito.',
      'next_difficulty': 'Susunod',
      'admin_access': 'Admin Access',
      'admin_login_title': 'ADMIN LOGIN',
      'admin_password': 'Admin Password',
      'wrong_admin_password': 'Maling admin password!',
      'admin_dashboard_title': 'ADMIN DASHBOARD',
      'exit_admin': 'LUMABAS SA ADMIN',
      'enter_admin_btn': 'PASOK',
      'search_accounts': 'Maghanap ng username...',
      'sort_by': 'Ayusin ayon sa',
      'sort_name': 'Pangalan (A-Z)',
      'sort_newest': 'Pinakabago Muna',
      'sort_oldest': 'Pinakauna Muna (Unang Nag-register)',
      'sort_score': 'Pinakamataas na Score',
      'no_search_results': 'Walang account na tumugma sa hinahanap mo.',
      'avg_score_label': 'Karaniwang Score',
      'top_score_label': 'Pinakamataas',
      'refresh': 'I-refresh',
      'select_all': 'Piliin Lahat',
      'clear_selection': 'Alisin ang Pinili',
      'delete_selected': 'Burahin ang Napili',
      'delete_selected_title': 'Burahin ang Napiling Accounts?',
      'delete_selected_msg': 'Sigurado ka bang burahin ang mga napiling account? Hindi na ito maibabalik.',
      'selected_count': 'napili',
      'first_player_label': 'Unang Player',
      'first_badge': 'UNA',
      'dates_repaired': 'Naayos ang mga nawawalang petsa ng pagpaparehistro.',
      'endless_badge': 'ENDLESS',
      'endless_unlocked_msg': 'Tapos na ang HARD! Walang katapusan na ngayon ang takbuhan — tagalan mo!',
      'player_out': 'LABAS!',
    },
    'zh': {
      'login_title': '玩家登录',
      'register_title': '注册玩家',
      'username': '用户名',
      'password': '密码',
      'confirm_password': '确认密码',
      'password_mismatch': '密码不一致!',
      'fill_fields': '请输入用户名和密码。',
      'user_exists': '用户名已被使用!',
      'user_not_found': '找不到用户名。',
      'wrong_password': '密码错误!',
      'account_created': '账户创建成功!请登录。',
      'login_btn': '登录',
      'register_btn': '创建账户',
      'switch_to_register': '还没有账户?点击注册',
      'switch_to_login': '已有账户?点击登录',
      'welcome': '欢迎',
      'play_game': '开始游戏',
      'how_to_play': '玩法说明',
      'leaderboard': '排行榜',
      'options': '选项与主题',
      'logout': '退出登录',
      'select_mode': '选择游戏模式',
      'mode_1p': '单人模式',
      'mode_2p': '双人合作',
      'back': '返回',
      'select_diff': '选择难度',
      'easy': '简单',
      'average': '中等',
      'hard': '困难',
      'theme_mode': '主题模式',
      'language': '语言',
      'game_over': '游戏结束',
      'try_again': '再试一次',
      'main_menu': '主菜单',
      'paused': '已暂停',
      'resume': '继续游戏',
      'controls': '操作说明',
      'controls_desc': '玩家 1: 方向键\n玩家 2: WASD 键',
      'collect_cheese': '收集奶酪 (+10分)',
      'cheese_desc': '收集迷宫中所有的奶酪以生成新的奶酪。',
      'power_ups': '道具 (青色光球)',
      'power_desc': '收集青色光球以生成额外的奖励奶酪。',
      'avoid_tom': '躲避汤姆!',
      'tom_desc': '躲避猫咪汤姆!被抓到即游戏结束。存活越久,汤姆的数量就会越多!',
      'no_scores': '暂无高分记录。',
      'clear_scores': '清除记录',
      'registered_accounts': '注册账户',
      'no_accounts': '暂无注册账户。',
      'total_accounts': '账户总数',
      'joined_on': '创建时间',
      'delete_account_title': '删除账户?',
      'delete_account_msg': '确定要删除此账户吗?此操作无法撤销。',
      'delete': '删除',
      'cancel': '取消',
      'sound': '声音',
      'print_report': '下载报告',
      'locked_diff_msg': '请先完成上一个难度!',
      'level_complete': '关卡完成!',
      'level_complete_msg': '太棒了!你已达到本难度的目标分数。',
      'next_difficulty': '下一个',
      'admin_access': '管理员入口',
      'admin_login_title': '管理员登录',
      'admin_password': '管理员密码',
      'wrong_admin_password': '管理员密码错误!',
      'admin_dashboard_title': '管理员面板',
      'exit_admin': '退出管理员',
      'enter_admin_btn': '进入',
      'first_player_label': '首位玩家',
      'first_badge': '首位',
      'endless_badge': '无尽模式',
    },
    'es': {
      'login_title': 'INICIAR SESIÓN',
      'register_title': 'REGISTRAR JUGADOR',
      'username': 'Nombre de Usuario',
      'password': 'Contraseña',
      'confirm_password': 'Confirmar Contraseña',
      'password_mismatch': '¡Las contraseñas no coinciden!',
      'fill_fields': 'Por favor ingrese usuario y contraseña.',
      'user_exists': '¡El usuario ya existe!',
      'user_not_found': 'Usuario no encontrado.',
      'wrong_password': '¡Contraseña incorrecta!',
      'account_created': '¡Cuenta creada con éxito! Por favor inicie sesión.',
      'login_btn': 'ENTRAR',
      'register_btn': 'CREAR CUENTA',
      'switch_to_register': '¿No tienes cuenta? Regístrate',
      'switch_to_login': '¿Ya tienes cuenta? Inicia sesión',
      'welcome': 'BIENVENIDO',
      'play_game': 'JUGAR',
      'how_to_play': 'CÓMO JUGAR',
      'leaderboard': 'CLASIFICACIÓN',
      'options': 'OPCIONES Y TEMA',
      'logout': 'CERRAR SESIÓN',
      'select_mode': 'SELECCIONAR MODO',
      'mode_1p': '1 JUGADOR (SOLO)',
      'mode_2p': '2 JUGADORES (COOP)',
      'back': 'VOLVER',
      'select_diff': 'DIFICULTAD',
      'easy': 'FÁCIL',
      'average': 'PROMEDIO',
      'hard': 'DIFÍCIL',
      'theme_mode': 'Modo de Tema',
      'language': 'Idioma',
      'game_over': 'FIN DEL JUEGO',
      'try_again': 'REINTENTAR',
      'main_menu': 'MENÚ PRINCIPAL',
      'paused': 'PAUSADO',
      'resume': 'CONTINUAR',
      'controls': 'Controles',
      'controls_desc': 'Jugador 1: Flechas\nJugador 2: Teclas WASD',
      'collect_cheese': 'Recoge Queso (+10 Pts)',
      'cheese_desc': 'Recoge todo el queso para generar más.',
      'power_ups': 'Potenciadores',
      'power_desc': 'Recoge orbes para generar queso extra.',
      'avoid_tom': '¡Evita a Tom!',
      'tom_desc': '¡Evita al gato Tom! Si te atrapa, se acaba el juego. ¡Mientras más sobrevivas, más Toms aparecerán!',
      'no_scores': 'No hay puntuaciones registradas.',
      'clear_scores': 'Borrar Puntuaciones',
      'registered_accounts': 'CUENTAS REGISTRADAS',
      'no_accounts': 'Aún no hay cuentas registradas.',
      'total_accounts': 'Total de Cuentas',
      'joined_on': 'Creada el',
      'delete_account_title': '¿Eliminar Cuenta?',
      'delete_account_msg': '¿Estás seguro de que quieres eliminar esta cuenta? Esto no se puede deshacer.',
      'delete': 'Eliminar',
      'cancel': 'Cancelar',
      'sound': 'Sonido',
      'print_report': 'DESCARGAR INFORME',
      'locked_diff_msg': '¡Termina la dificultad anterior primero!',
      'level_complete': '¡NIVEL COMPLETADO!',
      'level_complete_msg': '¡Buen trabajo! Alcanzaste la puntuación objetivo de esta dificultad.',
      'next_difficulty': 'Siguiente',
      'admin_access': 'Acceso Admin',
      'admin_login_title': 'INICIO ADMIN',
      'admin_password': 'Contraseña de Admin',
      'wrong_admin_password': '¡Contraseña de admin incorrecta!',
      'admin_dashboard_title': 'PANEL DE ADMIN',
      'exit_admin': 'SALIR DEL ADMIN',
      'enter_admin_btn': 'ENTRAR',
      'first_player_label': 'Primer Jugador',
      'first_badge': 'PRIMERO',
      'endless_badge': 'SIN FIN',
    },
    'ja': {
      'login_title': 'プレイヤーログイン',
      'register_title': '新規登録',
      'username': 'ユーザー名',
      'password': 'パスワード',
      'confirm_password': 'パスワードの確認',
      'password_mismatch': 'パスワードが一致しません!',
      'fill_fields': 'ユーザー名とパスワードを入力してください。',
      'user_exists': 'このユーザー名は既に使用されています!',
      'user_not_found': 'ユーザー名が見つかりません。',
      'wrong_password': 'パスワードが違います!',
      'account_created': 'アカウントが作成されました!ログインしてください。',
      'login_btn': 'ログイン',
      'register_btn': '登録する',
      'switch_to_register': 'アカウントをお持ちでない方はこちら',
      'switch_to_login': 'すでにアカウントをお持ちの方はこちら',
      'welcome': 'ようこそ',
      'play_game': 'プレイする',
      'how_to_play': '遊び方',
      'leaderboard': 'ランキング',
      'options': 'オプション・テーマ',
      'logout': 'ログアウト',
      'select_mode': 'モード選択',
      'mode_1p': '1人プレイ',
      'mode_2p': '2人プレイ',
      'back': '戻る',
      'select_diff': '難易度選択',
      'easy': 'かんたん',
      'average': 'ふつう',
      'hard': 'むずかしい',
      'theme_mode': 'テーマモード',
      'language': '言語',
      'game_over': 'ゲームオーバー',
      'try_again': 'もう一度',
      'main_menu': 'メインメニュー',
      'paused': '一時停止',
      'resume': '再開',
      'controls': '操作方法',
      'controls_desc': 'プレイヤー1: 矢印キー\nプレイヤー2: WASDキー',
      'collect_cheese': 'チーズを集める (+10 pt)',
      'cheese_desc': '迷路内のチーズを全て集めると新しいチーズが出現します。',
      'power_ups': 'パワーアップ',
      'power_desc': 'シアンの玉を集めるとボーナスチーズが出現します。',
      'avoid_tom': 'トムを避けろ!',
      'tom_desc': '猫のトムを避けよう!捕まるとゲームオーバーです。長く生き残るほど、トムの数が増えます!',
      'no_scores': 'まだハイスコアの記録がありません。',
      'clear_scores': 'スコアを削除',
      'registered_accounts': '登録済みアカウント',
      'no_accounts': '登録済みアカウントはまだありません。',
      'total_accounts': 'アカウント総数',
      'joined_on': '作成日時',
      'delete_account_title': 'アカウントを削除しますか?',
      'delete_account_msg': 'このアカウントを削除してもよろしいですか?この操作は取り消せません。',
      'delete': '削除',
      'cancel': 'キャンセル',
      'sound': 'サウンド',
      'print_report': 'レポートをダウンロード',
      'locked_diff_msg': '先に前の難易度をクリアしてください!',
      'level_complete': 'レベルクリア!',
      'level_complete_msg': 'よくできました!この難易度の目標スコアに到達しました。',
      'next_difficulty': '次へ',
      'admin_access': '管理者アクセス',
      'admin_login_title': '管理者ログイン',
      'admin_password': '管理者パスワード',
      'wrong_admin_password': '管理者パスワードが違います!',
      'admin_dashboard_title': '管理者ダッシュボード',
      'exit_admin': '管理者を終了',
      'enter_admin_btn': '入る',
      'first_player_label': '最初のプレイヤー',
      'first_badge': '最初',
      'endless_badge': 'エンドレス',
    },
  };

  static String getText(AppLanguage lang, String key) {
    final langCode = lang.code;
    if (_keys.containsKey(langCode) && _keys[langCode]!.containsKey(key)) {
      return _keys[langCode]![key]!;
    }
    return _keys['en']![key] ?? key;
  }
}

// --- ADMIN ACCESS ---
class AdminConfig {
  static const String adminPassword = 'admin1234';
}

// --- DEMO DATA SEEDING ---
const Map<String, int> _demoScores = {
  'keantj': 467,
  'jaspergamer': 466,
  'nica04': 455,
  'miguelph': 454,
  'sophiaxd': 451,
  'ellaplay': 440,
  'ryanzz': 424,
  'jasmine07': 410,
  'carlo_09': 392,
  'andreapro': 386,
  'paolotj': 381,
  'kayegamer': 374,
  'josh04': 374,
  'mikaph': 350,
  'vincexd': 310,
  'airaplay': 299,
  'marcozz': 295,
  'bea07': 293,
  'kurt_09': 276,
  'nicolepro': 260,
  'ricotj': 233,
  'maricelgamer': 223,
  'jhon04': 216,
  'angelph': 202,
  'dennisxd': 191,
  'faithplay': 189,
  'timothyzz': 185,
  'yna07': 185,
  'renz_09': 162,
  'chloepro': 161,
  'adriantj': 157,
  'preciousgamer': 143,
  'bryan04': 132,
  'reignph': 122,
  'elijahxd': 105,
  'shaniceplay': 96,
  'markzz': 88,
  'janella07': 82,
  'gio_09': 77,
  'kylapro': 55,
};

Map<String, int> _generateAdditionalDemoAccounts({int count = 80}) {
  final rand = Random(1234);
  const names = [
    'lester', 'jomar', 'trisha', 'kian', 'denise', 'harold', 'rein', 'cassy', 'luis', 'ivy',
    'noel', 'patty', 'arjay', 'gwen', 'ronel', 'ashley', 'dave', 'mira', 'glenn', 'jelly',
    'omar', 'cassandra', 'biboy', 'tin', 'wendell', 'joyce', 'alvin', 'maureen', 'archie', 'erika',
    'benj', 'marinel', 'clint', 'shane', 'wesley', 'rica', 'hansel', 'abby', 'kobe', 'janice',
    'tyrone', 'melissa', 'edison', 'crizel', 'armand', 'lovely', 'gabby', 'kenneth', 'sherilyn', 'ivan',
    'gio', 'angel', 'jade', 'marc', 'yna2', 'denver', 'krizza', 'harvey', 'sheena', 'robert',
    'annapro', 'carlostj', 'dianeph', 'felixzz', 'grace04', 'henry07', 'ireneplay', 'jake09', 'karlaxd', 'leogamer',
    'monicatj', 'nathanph', 'oliviazz', 'paulo04', 'queenie07', 'ryan2play', 'sasha09', 'tristanxd', 'ursulagamer', 'victortj',
  ];
  const suffixes = ['', 'gamer', 'play', 'pro', 'tj', 'zz', 'xd', '07', '04', '09'];

  final extra = <String, int>{};
  int i = 0;
  while (extra.length < count && i < names.length * suffixes.length) {
    final name = names[i % names.length];
    final suffix = suffixes[(i ~/ names.length) % suffixes.length];
    final username = '$name$suffix';
    if (!extra.containsKey(username) && !_demoScores.containsKey(username)) {
      // FIX: scores are always multiples of 10 now, since the real
      // in-game scoring only ever awards points in +10 increments
      // (one cheese = 10 pts). A demo score like "467" could never
      // actually happen in a real run, so it looked wrong sitting next
      // to genuine scores on the leaderboard.
      extra[username] = (40 + rand.nextInt(43)) * 10;
    }
    i++;
  }
  return extra;
}

/// Rounds a raw score to the nearest multiple of 10 (never below 10),
/// matching the fact that every cheese pickup is worth exactly 10 pts.
int _roundToTens(num value) {
  final rounded = (value / 10).round() * 10;
  return rounded < 10 ? 10 : rounded;
}

/// Highest score actually obtainable while playing a given category.
/// EASY, AVERAGE, and HARD all pause with the Level Complete screen the
/// instant their target score is reached, so a seeded leaderboard entry
/// can never legitimately sit above that target. ENDLESS has no ceiling
/// — it only exists by continuing past HARD's target — so it isn't
/// covered by this helper.
int _maxScoreForCategory(String category) {
  switch (category) {
    case 'AVERAGE':
      return 150;
    case 'HARD':
      return 300;
    case 'EASY':
    default:
      return 100;
  }
}

/// Seeds the demo roster with per-category (EASY/AVERAGE/HARD/ENDLESS)
/// high scores, and repairs registration timestamps at the same time.
///
/// Bumped to v6:
///  - EASY/AVERAGE/HARD scores are now scaled from each account's
///    arbitrary "base" number into that category's REAL maximum
///    (100 / 150 / 300) instead of being derived from the base value
///    with no upper limit. Previously the leaderboard could show
///    impossible numbers — e.g. an EASY score of 467 — even though a
///    real EASY run can never score above 100 (same problem for
///    AVERAGE's 150 cap and HARD's 300 cap).
///  - ENDLESS keeps its own separate, uncapped range starting just
///    above HARD's 300-point target, since that mode only exists by
///    continuing the chase past that point.
Future<void> seedDemoDataIfNeeded() async {
  final prefs = await SharedPreferences.getInstance();
  const seededFlagKey = 'demo_data_seeded_v6';

  if (prefs.getBool(seededFlagKey) == true) {
    return;
  }

  // Wipe any older-format seed so stale/out-of-range scores from a
  // previous version never linger alongside the new ones.
  await prefs.remove('demo_data_seeded_v5');
  await prefs.remove('demo_data_seeded_v4');
  await prefs.remove('demo_data_seeded_v3');
  await prefs.remove('demo_data_seeded_v2');
  await prefs.remove('demo_data_seeded');

  final allDemoAccounts = <String, int>{
    ..._demoScores,
    ..._generateAdditionalDemoAccounts(),
  };

  final dateRand = Random(5678); // fixed seed so dates stay stable across runs
  for (final username in allDemoAccounts.keys) {
    await UserStorage.setAccountCreatedAt(
      username,
      _randomActivityTimestamp(dateRand),
    );
  }

  // Turn each demo account's arbitrary base number into a proportional
  // rank (0.0 - 1.0 against the highest base in the roster), then scale
  // that rank into each category's real maximum so every seeded score
  // stays inside what a real run of that difficulty could ever produce.
  final maxBase = allDemoAccounts.values.isEmpty ? 1 : allDemoAccounts.values.reduce(max);
  final scoreRand = Random(2468);
  final categorized = <String, Map<String, int>>{};
  for (final entry in allDemoAccounts.entries) {
    final rank = (entry.value / maxBase).clamp(0.0, 1.0);

    int scaledFor(String category) {
      final cap = _maxScoreForCategory(category);
      final raw = (rank * cap).clamp(10, cap.toDouble());
      return _roundToTens(raw);
    }

    final scores = <String, int>{
      'EASY': scaledFor('EASY'),
      'AVERAGE': scaledFor('AVERAGE'),
      'HARD': scaledFor('HARD'),
    };

    if (scoreRand.nextDouble() < 0.12) {
      // ENDLESS only exists for players who cleared HARD's 300-point
      // target and kept going, so it always starts above that cap.
      final bonus = (rank * 300).round();
      scores['ENDLESS'] = _roundToTens(300 + bonus);
    }
    categorized[entry.key] = scores;
  }
  await prefs.setString('saved_high_scores_by_difficulty', jsonEncode(categorized));

  await prefs.setBool(seededFlagKey, true);
}

// --- MULTIPLAYER SERVICE & LOBBY ---
class MultiplayerService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<void> createRoom(String roomId, String hostRole) async {
    await _firestore.collection('game_rooms').doc(roomId).set({
      'status': 'waiting',
      'createdHost': hostRole,
      hostRole: {'x': 100.0, 'y': 100.0},
    });
  }

  Future<bool> joinRoom(String roomId, String guestRole) async {
    DocumentSnapshot doc = await _firestore.collection('game_rooms').doc(roomId).get();
    if (doc.exists) {
      await _firestore.collection('game_rooms').doc(roomId).set({
        'status': 'playing',
        guestRole: {'x': 200.0, 'y': 200.0},
      }, SetOptions(merge: true));
      return true;
    }
    return false;
  }
}

class LobbyScreen extends StatefulWidget {
  const LobbyScreen({super.key});

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  final TextEditingController _roomController = TextEditingController();
  final MultiplayerService _service = MultiplayerService();

  void _handleCreateRoom() async {
    String roomId = _roomController.text.trim();
    if (roomId.isNotEmpty) {
      await _service.createRoom(roomId, 'tom');

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => WaitingScreen(roomId: roomId),
        ),
      );
    }
  }

  void _handleJoinRoom() async {
    String roomId = _roomController.text.trim();
    if (roomId.isNotEmpty) {
      bool joined = await _service.joinRoom(roomId, 'jerry');
      if (!mounted) return;
      if (joined) {
        _navigateToGame();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Hindi nahanap ang Room Code!')),
        );
      }
    }
  }

  void _navigateToGame() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const GameApp(
          startInGame: true,
          startTwoPlayer: true,
          playerName: 'Jerry',
        ),
      ),
    );
  }

  @override
  void dispose() {
    _roomController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Container(
          width: 350,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 10)],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Tom & Jerry Multiplayer',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _roomController,
                decoration: const InputDecoration(
                  labelText: 'I-type ang Room Code (e.g. 1234)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _handleCreateRoom,
                      child: const Text('Create (Tom)'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _handleJoinRoom,
                      child: const Text('Join (Jerry)'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: "AIzaSyCjNIArYXYVuJk9JUmhrX38TAFSPiefb18",
      authDomain: "tom-jerry-multiplayer.firebaseapp.com",
      projectId: "tom-jerry-multiplayer",
      storageBucket: "tom-jerry-multiplayer.firebasestorage.app",
      messagingSenderId: "229198445023",
      appId: "1:229198445023:web:4c4348f29adf13ffe96c6a",
    ),
  );

  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: GameApp(),
  ));
}

/// Root game widget. Normally boots straight into the AuthMenu overlay.
///
/// When reached from the multiplayer Lobby/Waiting flow, [startInGame]
/// (plus [startTwoPlayer] and [playerName]) skips AuthMenu / MainMenu /
/// ModeSelect / Difficulty entirely and drops both players directly into
/// a running co-op match — see [_GameAppState.initState] and
/// [TomAndJerryGame.onLoad].
class GameApp extends StatefulWidget {
  final bool startInGame;
  final bool startTwoPlayer;
  final String? playerName;

  const GameApp({
    super.key,
    this.startInGame = false,
    this.startTwoPlayer = false,
    this.playerName,
  });

  @override
  State<GameApp> createState() => _GameAppState();
}

class _GameAppState extends State<GameApp> {
  late final TomAndJerryGame game;
  final FocusNode _gameFocusNode = FocusNode();
  late final Map<String, Widget Function(BuildContext, TomAndJerryGame)> _overlayBuilderMap;

  @override
  void initState() {
    super.initState();
    game = TomAndJerryGame();
    game.focusNode = _gameFocusNode;

    if (widget.startInGame) {
      // Multiplayer entry point: bypass AuthMenu/MainMenu/ModeSelect/
      // Difficulty and jump straight into a running match once the game
      // finishes loading (see TomAndJerryGame.onLoad).
      game.isTwoPlayerMode = widget.startTwoPlayer;
      game.pendingAutoStart = true;
      if (widget.playerName != null && widget.playerName!.trim().isNotEmpty) {
        game.playerName = widget.playerName!.trim();
      }
    }
    // FIX: built once here (instead of inline in build()) so its identity
    // never changes across rebuilds — GameWidget treats a new map instance
    // as a fresh overlay configuration, which was resetting the active
    // overlay back to AuthMenu every time the theme/language changed.
    _overlayBuilderMap = {
      'AuthMenu': (context, game) => AuthOverlay(game: game),
      'AdminLogin': (context, game) => AdminLoginOverlay(game: game),
      'AdminDashboard': (context, game) => AdminDashboardOverlay(game: game),
      'AdminSettings': (context, game) => AdminSettingsOverlay(game: game),
      'MainMenu': (context, game) => MainMenuOverlay(game: game),
      'ModeSelect': (context, game) => ModeSelectOverlay(game: game),
      'OptionsMenu': (context, game) => OptionsMenuOverlay(game: game),
      'HowToPlay': (context, game) => HowToPlayOverlay(game: game),
      'Leaderboard': (context, game) => LeaderboardOverlay(game: game),
      'Difficulty': (context, game) => DifficultyOverlay(game: game),
      'HUD': (context, game) => HudOverlay(game: game),
      'TouchControls': (context, game) => TouchControlsOverlay(game: game),
      'GameOver': (context, game) => GameOverOverlay(game: game),
      'Pause': (context, game) => PauseMenuOverlay(game: game),
      'LevelComplete': (context, game) => LevelCompleteOverlay(game: game),
    };
  }

  @override
  void dispose() {
    _gameFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // FIX: the GameWidget now lives in `child:` so it is built exactly
    // once and is NOT rebuilt when isDarkModeNotifier / languageNotifier
    // change. Only the Scaffold background repaints on theme changes.
    return AnimatedBuilder(
      animation: Listenable.merge([game.isDarkModeNotifier, game.languageNotifier]),
      builder: (context, child) {
        return Scaffold(
          backgroundColor: game.isDarkModeNotifier.value ? AppColors.darkNavy : AppColors.lightBackground,
          body: child,
        );
      },
      child: GameWidget<TomAndJerryGame>(
        game: game,
        focusNode: _gameFocusNode,
        autofocus: true,
        overlayBuilderMap: _overlayBuilderMap,
        initialActiveOverlays: widget.startInGame ? const [] : const ['AuthMenu'],
      ),
    );
  }
}

class AppColors {
  static const darkNavy = Color(0xFF0D1B2A);
  static const deepBlue = Color(0xFF1B263B);
  static const primaryBlue = Color(0xFF415A77);
  static const royalBlue = Color(0xFF0077B6);
  static const brightCyan = Color(0xFF00B4D8);
  static const iceBlue = Color(0xFF90E0EF);
  static const cheeseYellow = Color(0xFFFFD166);
  static const softWhite = Color(0xFFE0FBFC);
  static const logoSlate = Color(0xFF3A3A3C);

  static const lightBackground = Color(0xFFE0F2FE);
  static const lightPanel = Color(0xFFF0F9FF);
  static const lightPrimary = Color(0xFF0284C7);
  static const lightText = Color(0xFF0F172A);
  static const lightAccent = Color(0xFF0369A1);
}

const double cellSize = 48;

final List<List<int>> mazeLayout = [
  [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
  [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1],
  [1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1, 0, 1],
  [1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1],
  [1, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 0, 1],
  [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1],
  [1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1],
  [1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1],
  [1, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 0, 1],
  [1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1],
  [1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1],
  [1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1],
  [1, 0, 1, 1, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1],
  [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
  [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
];

List<Point<int>> findGridPath(Point<int> start, Point<int> target) {
  if (start == target) return [];
  final rows = mazeLayout.length;
  final cols = mazeLayout[0].length;
  final visited = List.generate(rows, (_) => List.filled(cols, false));
  final cameFrom = <Point<int>, Point<int>>{};
  final queue = Queue<Point<int>>()..add(start);
  visited[start.y][start.x] = true;

  const directions = [Point(0, -1), Point(0, 1), Point(-1, 0), Point(1, 0)];

  while (queue.isNotEmpty) {
    final current = queue.removeFirst();
    if (current == target) break;
    for (final d in directions) {
      final nx = current.x + d.x;
      final ny = current.y + d.y;
      if (nx < 0 || ny < 0 || nx >= cols || ny >= rows) continue;
      if (mazeLayout[ny][nx] == 1) continue;
      if (visited[ny][nx]) continue;
      visited[ny][nx] = true;
      cameFrom[Point(nx, ny)] = current;
      queue.add(Point(nx, ny));
    }
  }

  if (!visited[target.y][target.x]) return [];

  final path = <Point<int>>[];
  Point<int>? step = target;
  while (step != null && step != start) {
    path.add(step);
    step = cameFrom[step];
  }
  return path.reversed.toList();
}

bool rectHitsWall(Rect rect) {
  final cols = mazeLayout[0].length;
  final rows = mazeLayout.length;
  final left = (rect.left / cellSize).floor();
  final right = (rect.right / cellSize).ceil();
  final top = (rect.top / cellSize).floor();
  final bottom = (rect.bottom / cellSize).ceil();

  for (int y = top; y < bottom; y++) {
    for (int x = left; x < right; x++) {
      if (x < 0 || y < 0 || x >= cols || y >= rows) return true;
      if (mazeLayout[y][x] == 1) {
        final wallRect = Rect.fromLTWH(x * cellSize, y * cellSize, cellSize, cellSize);
        if (rect.overlaps(wallRect)) return true;
      }
    }
  }
  return false;
}

class TomAndJerryGame extends FlameGame
    with HasCollisionDetection, HasKeyboardHandlerComponents {
  String playerName = 'Player 1';
  String difficulty = 'EASY';
  bool isTwoPlayerMode = false;

  // Set by GameApp when this game is reached via the multiplayer
  // Lobby/Waiting flow instead of AuthMenu. When true, onLoad() calls
  // startGame() itself once loading finishes, so play begins immediately
  // on EASY instead of waiting for the player to click through
  // MainMenu -> ModeSelect -> Difficulty.
  bool pendingAutoStart = false;
  final ValueNotifier<bool> isDarkModeNotifier = ValueNotifier<bool>(true);
  final ValueNotifier<AppLanguage> languageNotifier = ValueNotifier<AppLanguage>(AppLanguage.english);

  final ValueNotifier<bool> isMutedNotifier = ValueNotifier<bool>(false);
  static bool globalMuted = false;

  // Turns true once the HARD difficulty's target score is reached in the
  // current run. From that point on the maze keeps going — no level-complete
  // pause — until Tom catches you. Always reset to false at the start of a
  // fresh run (startGame / restartGame) so it never carries over, UNLESS the
  // player explicitly chose the ENDLESS mode from the difficulty screen (see
  // [_isEndlessSelectedMode]), in which case the run starts already endless.
  final ValueNotifier<bool> isEndlessNotifier = ValueNotifier<bool>(false);

  // True only when the player picked the ENDLESS option directly from the
  // Difficulty screen (as opposed to reaching it mid-run by clearing HARD).
  // Used by restartGame() so "Try Again" after an Endless run starts back
  // in Endless mode instead of resetting to a normal HARD run.
  bool _isEndlessSelectedMode = false;

  final ValueNotifier<Vector2> p1TouchDirection = ValueNotifier<Vector2>(Vector2.zero());
  final ValueNotifier<Vector2> p2TouchDirection = ValueNotifier<Vector2>(Vector2.zero());

  FocusNode? focusNode;

  final ValueNotifier<int> p1ScoreNotifier = ValueNotifier<int>(0);
  final ValueNotifier<int> p2ScoreNotifier = ValueNotifier<int>(0);

  // In 2-player co-op, getting caught no longer ends the run right away —
  // each of these flips to true the instant that player is caught, and the
  // chase only truly ends once BOTH are true (or immediately, in 1-player
  // mode, since there's no partner to keep the run going). Always reset to
  // false at the start of every fresh run.
  final ValueNotifier<bool> p1CaughtNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> p2CaughtNotifier = ValueNotifier<bool>(false);

  JerryPlayer? jerry1;
  JerryPlayer? jerry2;

  final List<TomChaser> toms = [];
  double _tomSpawnTimer = 0;
  bool _levelCompleteTriggered = false;

  int _cheeseCount = 0;

  // Admin-configurable per-difficulty parameters (speed, spawn interval,
  // max Toms, target score, points per cheese). Loaded from
  // DifficultySettingsStore so the Admin Settings screen can change game
  // balance without touching source code. Falls back to the built-in
  // defaults until the first load completes.
  Map<String, Map<String, num>> difficultySettings = DifficultySettingsStore.defaultSettings;

  /// Re-reads the admin-configured difficulty settings from storage.
  /// Called on startup and again whenever the Admin Settings screen saves
  /// new values, so a change takes effect on the very next run without
  /// needing to restart the app.
  Future<void> reloadDifficultySettings() async {
    difficultySettings = await DifficultySettingsStore.loadAll();
  }

  String tr(String key) => AppTranslations.getText(languageNotifier.value, key);

  @override
  Color backgroundColor() => isDarkModeNotifier.value ? AppColors.darkNavy : AppColors.lightBackground;

  void toggleTheme() {
    isDarkModeNotifier.value = !isDarkModeNotifier.value;
  }

  void setLanguage(AppLanguage lang) {
    languageNotifier.value = lang;
  }

  void toggleMute() {
    isMutedNotifier.value = !isMutedNotifier.value;
    TomAndJerryGame.globalMuted = isMutedNotifier.value;
    if (isMutedNotifier.value) {
      FlameAudio.bgm.pause();
    } else {
      FlameAudio.bgm.resume();
    }
    _saveMutePreference(isMutedNotifier.value);
  }

  Future<void> _saveMutePreference(bool muted) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_muted', muted);
  }

  void _playSfx(String file) {
    if (isMutedNotifier.value) return;
    FlameAudio.play(file);
  }

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    camera.backdrop.add(TomAndJerryThemeBackdrop());

    final prefs = await SharedPreferences.getInstance();
    final savedMuted = prefs.getBool('is_muted') ?? false;
    isMutedNotifier.value = savedMuted;
    TomAndJerryGame.globalMuted = savedMuted;

    // Seed the demo roster, then repair any account still missing a
    // registration date so nothing shows up as "Unknown" anywhere.
    await seedDemoDataIfNeeded();
    await UserStorage.backfillMissingCreatedAt();

    // Load the admin-configurable difficulty settings before any game
    // can be started.
    await reloadDifficultySettings();

    await FlameAudio.audioCache.loadAll([
      'cheese.wav',
      'powerup.wav',
      'caught.wav',
      'click.wav',
    ]);

    // Multiplayer lobby entry point: skip straight into a running match
    // instead of showing AuthMenu. Done last, after every asset/setting
    // above has finished loading, since startGame() builds the maze and
    // needs the world/camera to already be ready.
    if (pendingAutoStart) {
      pendingAutoStart = false;
      startGame(playerName, 'EASY');
    }
  }

  @override
  void update(double dt) {
    super.update(dt);

    // Drive the shared animation clock used by walls and ambient visuals.
    GameClock.t += dt;

    if (!overlays.isActive('HUD')) return;

    // Backup pickup guarantee: even if Flame's collision callback misses
    // a graze (fast movement, off-center overlap), this proximity check
    // still awards the cheese/power-up every frame.
    _checkPickupProximity();

    _tomSpawnTimer += dt;
    final interval = _tomSpawnIntervalForDifficulty(difficulty);
    final maxToms = _maxTomsForDifficulty(difficulty);
    if (_tomSpawnTimer >= interval && toms.length < maxToms) {
      _tomSpawnTimer = 0;
      _spawnExtraTom();
    }
  }

  /// Manual proximity-based pickup check. Runs alongside the physics
  /// collision system (never replaces it) as a guarantee: if Jerry's
  /// center gets close enough to a cheese or power-up's center, it counts
  /// as collected even if the two hitboxes never technically registered
  /// an overlap event that frame.
  void _checkPickupProximity() {
    final players = <JerryPlayer>[
      if (jerry1 != null) jerry1!,
      if (jerry2 != null) jerry2!,
    ];
    if (players.isEmpty) return;

    for (final cheese in world.children.query<CheeseComponent>().toList()) {
      for (final p in players) {
        final delta = (cheese.position + cheese.size / 2) - (p.position + p.size / 2);
        // FIX: tightened from (cheese.size.x*0.5 + p.size.x*0.35) to
        // (cheese.size.x*0.4 + p.size.x*0.2) — the old formula made the
        // effective pickup radius noticeably bigger than the cheese's
        // drawn size, so it looked like you were grabbing cheese from
        // several pixels away. This now roughly matches CheeseComponent's
        // shrunk CircleHitbox below instead of being more generous than it.
        final pickupRadius = cheese.size.x * 0.4 + p.size.x * 0.2;
        if (delta.length <= pickupRadius) {
          cheese.collectBy(p);
          break;
        }
      }
    }

    for (final power in world.children.query<ScatterPowerUpComponent>().toList()) {
      for (final p in players) {
        final delta = (power.position + power.size / 2) - (p.position + p.size / 2);
        final pickupRadius = power.size.x * 0.4 + p.size.x * 0.2;
        if (delta.length <= pickupRadius) {
          power.collectBy(p);
          break;
        }
      }
    }
  }

  void startGame(String name, String diff) {
    if (name.trim().isNotEmpty) {
      playerName = name.trim();
    }

    // "ENDLESS" isn't a real difficulty tier by itself — it reuses HARD's
    // speed/spawn settings but starts the run already in endless mode
    // (no level-complete pause, no target score to hit) instead of only
    // unlocking endless mid-run after HARD's target is reached.
    final bool startAsEndless = diff == 'ENDLESS';
    difficulty = startAsEndless ? 'HARD' : diff;
    _isEndlessSelectedMode = startAsEndless;

    // Every fresh run starts NOT in endless mode and with score at 0
    // (score reset happens just below) — endless is only ever entered
    // mid-run after clearing HARD's target, unless ENDLESS was picked
    // directly, in which case the run starts already endless.
    isEndlessNotifier.value = startAsEndless;
    overlays.remove('Difficulty');
    overlays.remove('GameOver');
    overlays.remove('Pause');
    overlays.remove('MainMenu');
    overlays.remove('ModeSelect');
    overlays.remove('LevelComplete');
    overlays.add('HUD');
    overlays.add('TouchControls');

    p1ScoreNotifier.value = 0;
    p2ScoreNotifier.value = 0;
    p1CaughtNotifier.value = false;
    p2CaughtNotifier.value = false;

    _buildMaze();
    resumeEngine();

    if (!isMutedNotifier.value) {
      FlameAudio.bgm.play('bg_music.mp3', volume: 0.4);
    }
  }

  void restartGame() {
    // Same as startGame: guarantee a clean slate — score back to 0 — for
    // every new attempt at this difficulty. If the previous run was
    // explicitly started as ENDLESS, "Try Again" keeps it endless instead
    // of dropping back to a normal HARD run.
    isEndlessNotifier.value = _isEndlessSelectedMode;
    overlays.remove('GameOver');
    overlays.remove('Pause');
    overlays.remove('LevelComplete');
    overlays.add('HUD');
    overlays.add('TouchControls');
    p1ScoreNotifier.value = 0;
    p2ScoreNotifier.value = 0;
    p1CaughtNotifier.value = false;
    p2CaughtNotifier.value = false;
    _buildMaze();
    resumeEngine();

    if (!isMutedNotifier.value) {
      FlameAudio.bgm.play('bg_music.mp3', volume: 0.4);
    }
  }

  void pauseGame() {
    pauseEngine();
    FlameAudio.bgm.pause();
    overlays.add('Pause');
  }

  void resumeGame() {
    overlays.remove('Pause');
    if (!isMutedNotifier.value) FlameAudio.bgm.resume();
    resumeEngine();
  }

  void logout() {
    FlameAudio.bgm.stop();
    world.removeAll(world.children.toList());
    toms.clear();
    overlays.clear();
    overlays.add('AuthMenu');
    resumeEngine();
  }

  void quitToMenu() {
    FlameAudio.bgm.stop();
    world.removeAll(world.children.toList());
    toms.clear();
    overlays.remove('Pause');
    overlays.remove('HUD');
    overlays.remove('TouchControls');
    overlays.remove('GameOver');
    overlays.remove('Difficulty');
    overlays.remove('Leaderboard');
    overlays.remove('OptionsMenu');
    overlays.remove('HowToPlay');
    overlays.remove('ModeSelect');
    overlays.remove('LevelComplete');
    overlays.add('MainMenu');
    resumeEngine();
  }

  @override
  KeyEventResult onKeyEvent(KeyEvent event, Set<LogicalKeyboardKey> keysPressed) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      if (overlays.isActive('HUD')) {
        pauseGame();
        return KeyEventResult.handled;
      } else if (overlays.isActive('Pause')) {
        resumeGame();
        return KeyEventResult.handled;
      }
    }
    return super.onKeyEvent(event, keysPressed);
  }

  List<Vector2> _getEmptyCells() {
    final emptyCells = <Vector2>[];
    for (int y = 0; y < mazeLayout.length; y++) {
      for (int x = 0; x < mazeLayout[y].length; x++) {
        if (mazeLayout[y][x] == 0) {
          final cell = Vector2(x.toDouble(), y.toDouble());
          if (cell != Vector2(1, 1) && cell != Vector2(1, 13) && cell != Vector2(13, 13)) {
            emptyCells.add(cell);
          }
        }
      }
    }
    return emptyCells;
  }

  void _spawnCheeses(int amount) {
    final emptyCells = _getEmptyCells();
    emptyCells.shuffle(Random());

    for (final cell in emptyCells.take(amount)) {
      world.add(CheeseComponent(gridPosition: cell, game: this));
      _cheeseCount++;
    }
  }

  void _spawnPowerUp() {
    final emptyCells = _getEmptyCells();
    emptyCells.shuffle(Random());
    if (emptyCells.isNotEmpty) {
      world.add(ScatterPowerUpComponent(gridPosition: emptyCells.first, game: this));
    }
  }

  void triggerScatterPowerUp() {
    _playSfx('powerup.wav');
    _spawnCheeses(6);
  }

  void _buildMaze() {
    world.removeAll(world.children.toList());
    _cheeseCount = 0;

    toms.clear();
    _tomSpawnTimer = 0;
    _levelCompleteTriggered = false;

    for (int y = 0; y < mazeLayout.length; y++) {
      for (int x = 0; x < mazeLayout[y].length; x++) {
        if (mazeLayout[y][x] == 1) {
          world.add(WallComponent(
            gridPosition: Vector2(x.toDouble(), y.toDouble()),
          ));
        }
      }
    }

    _spawnCheeses(12);
    _spawnPowerUp();

    jerry1 = JerryPlayer(
      gridPosition: Vector2(1, 1),
      isPlayerTwo: false,
    );
    world.add(jerry1!);

    if (isTwoPlayerMode) {
      jerry2 = JerryPlayer(
        gridPosition: Vector2(1, 13),
        isPlayerTwo: true,
      );
      world.add(jerry2!);
    } else {
      jerry2 = null;
    }

    final tomSpeed = _speedForDifficulty(difficulty);
    final firstTom = TomChaser(
      gridPosition: Vector2(13, 13),
      speed: tomSpeed,
      game: this,
    );
    toms.add(firstTom);
    world.add(firstTom);

    focusNode?.requestFocus();
    HardwareKeyboard.instance.clearState();

    final mazeWidthPx = mazeLayout[0].length * cellSize;
    final mazeHeightPx = mazeLayout.length * cellSize;
    camera.viewfinder.anchor = Anchor.center;
    camera.viewfinder.position = Vector2(mazeWidthPx / 2, mazeHeightPx / 2);
    _fitCameraToScreen();
  }

  /// Difficulty key used to look values up in [difficultySettings]. The
  /// in-run "ENDLESS" state always reuses HARD's tuned values, since
  /// ENDLESS is just HARD continued past its target score.
  String _settingsKeyFor(String diff) => diff == 'ENDLESS' ? 'HARD' : diff;

  double _speedForDifficulty(String diff) {
    final key = _settingsKeyFor(diff);
    return (difficultySettings[key]?['speed'] ?? DifficultySettingsStore.defaultSettings[key]?['speed'] ?? 60)
        .toDouble();
  }

  double _tomSpawnIntervalForDifficulty(String diff) {
    final key = _settingsKeyFor(diff);
    return (difficultySettings[key]?['spawnInterval'] ??
            DifficultySettingsStore.defaultSettings[key]?['spawnInterval'] ??
            30)
        .toDouble();
  }

  int _maxTomsForDifficulty(String diff) {
    final key = _settingsKeyFor(diff);
    return (difficultySettings[key]?['maxToms'] ?? DifficultySettingsStore.defaultSettings[key]?['maxToms'] ?? 2)
        .toInt();
  }

  int _targetScoreForDifficulty(String diff) {
    final key = _settingsKeyFor(diff);
    return (difficultySettings[key]?['targetScore'] ??
            DifficultySettingsStore.defaultSettings[key]?['targetScore'] ??
            100)
        .toInt();
  }

  /// Points awarded for a single cheese pickup at the current difficulty —
  /// admin-configurable via the Admin Settings screen (defaults to 10).
  int _cheesePointsForDifficulty(String diff) {
    final key = _settingsKeyFor(diff);
    return (difficultySettings[key]?['cheesePoints'] ??
            DifficultySettingsStore.defaultSettings[key]?['cheesePoints'] ??
            10)
        .toInt();
  }

  /// Points a single cheese is worth in the run currently in progress —
  /// used by CheeseComponent so its floating "+N" popup always matches
  /// the score actually awarded.
  int get currentCheesePoints =>
      _cheesePointsForDifficulty(isEndlessNotifier.value ? 'ENDLESS' : difficulty);

  String? nextDifficulty() {
    switch (difficulty) {
      case 'EASY':
        return 'AVERAGE';
      case 'AVERAGE':
        return 'HARD';
      default:
        return null;
    }
  }

  void _spawnExtraTom() {
    final emptyCells = _getEmptyCells();
    emptyCells.shuffle(Random());
    if (emptyCells.isEmpty) return;

    final speed = _speedForDifficulty(difficulty);
    final newTom = TomChaser(
      gridPosition: emptyCells.first,
      speed: speed,
      game: this,
    );
    toms.add(newTom);
    world.add(newTom);

    // Animated "a new cat joined the hunt" puff at the spawn point.
    world.add(SparkleBurstComponent(
      position: newTom.position + newTom.size / 2,
      color: Colors.redAccent,
      particleCount: 18,
      duration: 0.6,
    ));
  }

  void _fitCameraToScreen() {
    final mazeWidthPx = mazeLayout[0].length * cellSize;
    final mazeHeightPx = mazeLayout.length * cellSize;
    final zoomX = size.x / mazeWidthPx;
    final zoomY = size.y / mazeHeightPx;
    camera.viewfinder.zoom = min(zoomX, zoomY).clamp(0.6, 3.5);
  }

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    if (isLoaded) {
      _fitCameraToScreen();
    }
  }

  void collectCheese(bool isPlayerTwo) {
    _playSfx('cheese.wav');

    final points = currentCheesePoints;
    if (isPlayerTwo) {
      p2ScoreNotifier.value += points;
    } else {
      p1ScoreNotifier.value += points;
    }

    _cheeseCount--;
    if (_cheeseCount <= 0) {
      _spawnCheeses(10);
      _spawnPowerUp();
    }

    _checkLevelComplete();
  }

  void _checkLevelComplete() {
    if (_levelCompleteTriggered) return;
    final total = p1ScoreNotifier.value + (isTwoPlayerMode ? p2ScoreNotifier.value : 0);
    if (total >= _targetScoreForDifficulty(difficulty)) {
      if (difficulty == 'HARD') {
        // Reaching HARD's target doesn't pause the game anymore — it
        // unlocks endless play instead, and the chase just keeps going.
        _unlockEndless();
      } else {
        onLevelComplete();
      }
    }
  }

  /// Called once, the moment HARD's target score is reached. From here on
  /// the maze never pauses for a "level complete" screen — Jerry keeps
  /// running, cheese keeps spawning, and the score keeps climbing until
  /// Tom finally catches up.
  void _unlockEndless() async {
    if (isEndlessNotifier.value) return;
    isEndlessNotifier.value = true;
    _playSfx('powerup.wav');

    if (jerry1 != null) {
      world.add(SparkleBurstComponent(
        position: jerry1!.position + jerry1!.size / 2,
        color: AppColors.brightCyan,
        particleCount: 30,
        duration: 0.8,
      ));
      world.add(ScorePopupComponent(
        position: jerry1!.position + jerry1!.size / 2 - Vector2(0, 20),
        text: tr('endless_badge'),
        color: AppColors.brightCyan,
        duration: 1.4,
      ));
    }

    await DifficultyProgress.markCompleted(playerName, 'HARD');
  }

  void onLevelComplete() async {
    if (_levelCompleteTriggered) return;
    _levelCompleteTriggered = true;

    _playSfx('powerup.wav');
    FlameAudio.bgm.stop();

    // Celebratory burst before the overlay takes over.
    if (jerry1 != null) {
      world.add(SparkleBurstComponent(
        position: jerry1!.position + jerry1!.size / 2,
        color: AppColors.cheeseYellow,
        particleCount: 26,
        duration: 0.7,
      ));
    }
    await Future.delayed(const Duration(milliseconds: 250));

    pauseEngine();

    await DifficultyProgress.markCompleted(playerName, difficulty);

    overlays.remove('HUD');
    overlays.remove('TouchControls');
    overlays.add('LevelComplete');
  }

  /// Submits this run's score into the per-difficulty (or per-endless)
  /// high score store. Only kept if it beats the player's previous best
  /// for that exact category — Easy, Average, Hard, and Endless are all
  /// tracked separately so none of them overwrite each other.
  Future<void> saveHighScore() async {
    final category = isEndlessNotifier.value ? 'ENDLESS' : difficulty;

    await DifficultyScoreStore.submitScore(playerName, category, p1ScoreNotifier.value);

    if (isTwoPlayerMode) {
      const p2Name = 'player 2 (co-op)';
      await DifficultyScoreStore.submitScore(p2Name, category, p2ScoreNotifier.value);
    }
  }

  /// Called whenever a JerryPlayer touches Tom. In 1-player mode this
  /// always ends the run immediately. In 2-player co-op, the player who
  /// was caught is taken out of play, but the run keeps going for their
  /// partner — the maze only truly ends once BOTH players have been
  /// caught.
  void onPlayerCaught(JerryPlayer player) async {
    if (player.isCaught) return;
    player.isCaught = true;

    if (!isTwoPlayerMode) {
      onCaughtByTom();
      return;
    }

    final otherPlayer = player.isPlayerTwo ? jerry1 : jerry2;
    final otherStillPlaying = otherPlayer != null && !otherPlayer.isCaught;

    if (player.isPlayerTwo) {
      p2CaughtNotifier.value = true;
    } else {
      p1CaughtNotifier.value = true;
    }

    if (otherStillPlaying) {
      // This player is out, but their partner keeps running — no pause,
      // no Game Over yet.
      _playSfx('caught.wav');
      world.add(SparkleBurstComponent(
        position: player.position + player.size / 2,
        color: Colors.grey,
        particleCount: 20,
        duration: 0.6,
      ));
      world.add(ScorePopupComponent(
        position: player.position + player.size / 2 - Vector2(0, 24),
        text: tr('player_out'),
        color: Colors.redAccent,
        duration: 1.3,
      ));

      player.removeFromParent();
      if (player.isPlayerTwo) {
        jerry2 = null;
      } else {
        jerry1 = null;
      }
    } else {
      // Both players have now been caught — the run is truly over.
      onCaughtByTom();
    }
  }

  void onCaughtByTom() async {
    _playSfx('caught.wav');
    FlameAudio.bgm.stop();
    camera.viewport.add(ScreenFlashComponent());
    await Future.delayed(const Duration(milliseconds: 350));
    pauseEngine();
    await saveHighScore();
    overlays.remove('HUD');
    overlays.remove('TouchControls');
    overlays.add('GameOver');
  }
}

// =====================================================================
// ANIMATED BACKDROP
// =====================================================================
class TomAndJerryThemeBackdrop extends Component with HasGameReference<TomAndJerryGame> {
  double _time = 0;

  @override
  void update(double dt) {
    super.update(dt);
    _time += dt;
  }

  @override
  void render(Canvas canvas) {
    final w = game.size.x;
    final h = game.size.y;
    final rect = Rect.fromLTWH(0, 0, w, h);
    final isDark = game.isDarkModeNotifier.value;

    // Slowly shifting gradient so the background never sits still.
    final shift = 0.5 + 0.5 * sin(_time * 0.35);
    final gradient = LinearGradient(
      begin: Alignment(-1 + shift * 0.4, -1),
      end: Alignment(1, 1 - shift * 0.4),
      colors: isDark
          ? [
              AppColors.darkNavy,
              AppColors.royalBlue.withValues(alpha: 0.45 + 0.25 * shift),
              AppColors.darkNavy,
            ]
          : [
              AppColors.lightBackground,
              AppColors.iceBlue.withValues(alpha: 0.6 + 0.3 * shift),
              AppColors.lightBackground,
            ],
    );
    canvas.drawRect(rect, Paint()..shader = gradient.createShader(rect));

    // Scrolling grid — gives a constant sense of motion.
    final gridPaint = Paint()
      ..color = (isDark ? AppColors.brightCyan : AppColors.lightPrimary)
          .withValues(alpha: 0.12 + 0.08 * shift)
      ..strokeWidth = 1.2;

    final offset = (_time * 14) % 40;
    for (double x = -40 + offset; x < w; x += 40) {
      canvas.drawLine(Offset(x, 0), Offset(x, h), gridPaint);
    }
    for (double y = -40 + offset; y < h; y += 40) {
      canvas.drawLine(Offset(0, y), Offset(w, y), gridPaint);
    }

    // Floating, slowly spinning cheese wedges.
    final cheesePaint = Paint()
      ..color = AppColors.cheeseYellow.withValues(alpha: isDark ? 0.25 : 0.45)
      ..style = PaintingStyle.fill;

    for (int i = 0; i < 6; i++) {
      final cx = (w * 0.15 * i + sin(_time * 0.6 + i) * 30 + _time * 8) % (w + 60) - 30;
      final cy = (h * 0.2 * i + cos(_time * 0.8 + i) * 26) % h;
      canvas.save();
      canvas.translate(cx, cy);
      canvas.rotate(sin(_time * 0.5 + i) * 0.5);
      final path = Path()
        ..moveTo(0, 0)
        ..lineTo(24, 12)
        ..lineTo(0, 24)
        ..close();
      canvas.drawPath(path, cheesePaint);
      canvas.restore();
    }

    // Breathing title text.
    final breathe = 1 + 0.03 * sin(_time * 1.2);
    final textPainter = TextPainter(
      text: TextSpan(
        text: "TOM & JERRY",
        style: TextStyle(
          fontSize: min(w, h) * 0.11 * breathe,
          fontWeight: FontWeight.w900,
          color: (isDark ? AppColors.brightCyan : AppColors.lightPrimary)
              .withValues(alpha: 0.18 + 0.08 * shift),
          letterSpacing: 6,
          shadows: const [
            Shadow(color: AppColors.cheeseYellow, blurRadius: 18),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset((w - textPainter.width) / 2, (h - textPainter.height) / 2 + sin(_time * 1.5) * 8),
    );
  }
}

// =====================================================================
// ANIMATED WALLS
// =====================================================================
class WallComponent extends PositionComponent with HasGameReference<TomAndJerryGame> {
  final Vector2 gridPosition;
  late final double _phase;

  WallComponent({required this.gridPosition})
      : super(
          position: gridPosition * cellSize,
          size: Vector2.all(cellSize),
        ) {
    // Offset each wall's pulse by its grid position so the glow travels
    // across the maze like a wave instead of blinking all at once.
    _phase = (gridPosition.x + gridPosition.y) * 0.45;
  }

  @override
  void render(Canvas canvas) {
    final isDark = game.isDarkModeNotifier.value;
    final rect = size.toRect();
    final pulse = 0.5 + 0.5 * sin(GameClock.t * 2 + _phase);

    canvas.drawRect(rect, Paint()..color = isDark ? AppColors.deepBlue : AppColors.lightAccent);

    // Inner neon edge that breathes.
    canvas.drawRect(
      rect.deflate(1),
      Paint()
        ..color = (isDark ? AppColors.brightCyan : Colors.white)
            .withValues(alpha: 0.35 + 0.4 * pulse)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4 + 0.8 * pulse,
    );

    // Soft highlight sliding along the top edge.
    canvas.drawRect(
      Rect.fromLTWH(rect.left + 3, rect.top + 3, rect.width - 6, 2.5),
      Paint()
        ..color = (isDark ? AppColors.iceBlue : Colors.white)
            .withValues(alpha: 0.12 + 0.18 * pulse),
    );
  }
}

// =====================================================================
// PARTICLE / FEEDBACK EFFECTS
// =====================================================================

/// A short-lived burst of dots that fly outward and fade.
class SparkleBurstComponent extends PositionComponent {
  final Color color;
  final int particleCount;
  final double duration;
  late final List<Offset> _velocities;
  late final List<double> _sizes;
  double _time = 0;

  SparkleBurstComponent({
    required Vector2 position,
    this.color = Colors.yellow,
    this.particleCount = 12,
    this.duration = 0.45,
  }) : super(position: position, size: Vector2.zero(), anchor: Anchor.center, priority: 10) {
    final rand = Random();
    _velocities = List.generate(particleCount, (_) {
      final angle = rand.nextDouble() * pi * 2;
      final speed = 50 + rand.nextDouble() * 70;
      return Offset(cos(angle) * speed, sin(angle) * speed);
    });
    _sizes = List.generate(particleCount, (_) => 2.0 + rand.nextDouble() * 2.5);
  }

  @override
  void update(double dt) {
    super.update(dt);
    _time += dt;
    if (_time >= duration) {
      removeFromParent();
    }
  }

  @override
  void render(Canvas canvas) {
    final t = (_time / duration).clamp(0.0, 1.0);
    final alpha = (1 - t);
    final paint = Paint()..color = color.withValues(alpha: alpha);
    for (int i = 0; i < particleCount; i++) {
      final dx = _velocities[i].dx * t;
      final dy = _velocities[i].dy * t + 40 * t * t; // slight gravity droop
      final radius = _sizes[i] * (1 - t * 0.5);
      canvas.drawCircle(Offset(dx, dy), radius, paint);
    }
  }
}

/// Floating "+10" text (or any short label) that rises and fades.
class ScorePopupComponent extends PositionComponent {
  final String text;
  final Color color;
  final double duration;
  double _time = 0;

  ScorePopupComponent({
    required Vector2 position,
    this.text = '+10',
    this.color = AppColors.cheeseYellow,
    this.duration = 0.8,
  }) : super(position: position, size: Vector2.zero(), anchor: Anchor.center, priority: 30);

  @override
  void update(double dt) {
    super.update(dt);
    _time += dt;
    if (_time >= duration) removeFromParent();
  }

  @override
  void render(Canvas canvas) {
    final t = (_time / duration).clamp(0.0, 1.0);
    final rise = -34 * Curves.easeOut.transform(t);
    final scale = 1 + 0.35 * (1 - t);

    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 15 * scale,
          fontWeight: FontWeight.w900,
          color: color.withValues(alpha: 1 - t),
          shadows: [
            Shadow(color: Colors.black.withValues(alpha: (1 - t) * 0.7), blurRadius: 3),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    painter.paint(canvas, Offset(-painter.width / 2, rise - painter.height / 2));
  }
}

/// A fading footstep/dust puff left behind while a character runs.
class TrailDotComponent extends PositionComponent {
  final Color color;
  final double duration;
  final double radius;
  double _time = 0;

  TrailDotComponent({
    required Vector2 position,
    required this.color,
    this.duration = 0.45,
    this.radius = 5,
  }) : super(position: position, size: Vector2.zero(), anchor: Anchor.center, priority: 1);

  @override
  void update(double dt) {
    super.update(dt);
    _time += dt;
    if (_time >= duration) removeFromParent();
  }

  @override
  void render(Canvas canvas) {
    final t = (_time / duration).clamp(0.0, 1.0);
    canvas.drawCircle(
      Offset.zero,
      radius * (1 - t * 0.6),
      Paint()..color = color.withValues(alpha: 0.35 * (1 - t)),
    );
  }
}

/// A full-screen color flash used for the moment Jerry gets caught.
class ScreenFlashComponent extends PositionComponent with HasGameReference<TomAndJerryGame> {
  final Color color;
  final double duration;
  double _time = 0;

  ScreenFlashComponent({this.color = Colors.red, this.duration = 0.35}) : super(priority: 1000);

  @override
  void update(double dt) {
    super.update(dt);
    _time += dt;
    if (_time >= duration) {
      removeFromParent();
    }
  }

  @override
  void render(Canvas canvas) {
    final t = (_time / duration).clamp(0.0, 1.0);
    final alpha = (1 - t) * 0.5;
    final size = game.size;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.x, size.y), Paint()..color = color.withValues(alpha: alpha));
  }
}

// =====================================================================
// ANIMATED PICKUPS
// =====================================================================
class CheeseComponent extends PositionComponent with CollisionCallbacks, HasGameReference<TomAndJerryGame> {
  final Vector2 gridPosition;
  @override
  final TomAndJerryGame game;

  double _t = 0;
  late final double _phase;
  double _spawnT = 0; // drives the little "pop in" animation

  // Guards against being collected twice (once by the physics collision
  // callback and once by the game's manual proximity check in the same
  // frame) — whichever fires first wins, the other is a no-op.
  bool _collected = false;

  CheeseComponent({required this.gridPosition, required this.game})
      : super(
          position: gridPosition * cellSize + Vector2.all(cellSize * 0.15),
          size: Vector2.all(cellSize * 0.7),
        ) {
    _phase = (gridPosition.x * 1.7 + gridPosition.y * 2.3);
  }

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    // FIX: shrunk from 1.8x -> 0.9x the cheese's drawn size. The old 1.8x
    // hitbox was noticeably bigger than the cheese sprite itself, so it
    // looked like you were collecting cheese from several pixels away
    // before Jerry's body ever actually touched it. 0.9x keeps a small
    // amount of forgiveness (so a graze still counts) without the hitbox
    // sticking way out past the visible wedge. This is the primary
    // collision path; collectBy() below is also called directly by the
    // game's frame-by-frame proximity check as a guaranteed backup (with
    // its own radius tightened to match), so a cheese is never missed
    // regardless of speed.
    add(CircleHitbox.relative(0.9, parentSize: size)..collisionType = CollisionType.passive);
  }

  @override
  void update(double dt) {
    super.update(dt);
    _t += dt;
    if (_spawnT < 1) {
      _spawnT = (_spawnT + dt * 4).clamp(0.0, 1.0);
    }
  }

  @override
  void render(Canvas canvas) {
    final w = size.x;
    final h = size.y;

    // Bobbing up/down, gentle tilt, and a soft breathing scale.
    final bob = sin(_t * 3 + _phase) * h * 0.09;
    final tilt = sin(_t * 2 + _phase) * 0.18;
    final pop = Curves.easeOutBack.transform(_spawnT).clamp(0.0, 1.4);
    final breathe = (0.94 + 0.06 * sin(_t * 4 + _phase)) * pop;

    // Shadow on the floor keeps the float readable.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(w * 0.5, h * 0.95),
        width: w * 0.5 * (1 - bob / (h * 0.4)).clamp(0.6, 1.2),
        height: h * 0.12,
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.18),
    );

    canvas.save();
    canvas.translate(w / 2, h / 2 + bob);
    canvas.rotate(tilt);
    canvas.scale(breathe);
    canvas.translate(-w / 2, -h / 2);

    // Glow halo.
    canvas.drawCircle(
      Offset(w * 0.5, h * 0.5),
      w * 0.5,
      Paint()
        ..color = AppColors.cheeseYellow.withValues(alpha: 0.18 + 0.12 * sin(_t * 4 + _phase))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    final path = Path()
      ..moveTo(w * 0.1, h * 0.85)
      ..lineTo(w * 0.9, h * 0.85)
      ..lineTo(w * 0.65, h * 0.15)
      ..lineTo(w * 0.1, h * 0.35)
      ..close();

    canvas.drawPath(path, Paint()..color = const Color(0xFFFFC107));

    final holePaint = Paint()..color = const Color(0xFFFFA000);
    canvas.drawCircle(Offset(w * 0.35, h * 0.55), w * 0.1, holePaint);
    canvas.drawCircle(Offset(w * 0.6, h * 0.65), w * 0.08, holePaint);
    canvas.drawCircle(Offset(w * 0.45, h * 0.35), w * 0.06, holePaint);

    // Sweeping shine highlight.
    final shineX = (sin(_t * 2 + _phase) * 0.5 + 0.5) * w;
    canvas.drawCircle(
      Offset(shineX, h * 0.3),
      w * 0.07,
      Paint()..color = Colors.white.withValues(alpha: 0.5),
    );

    canvas.restore();
  }

  /// Shared pickup logic — called from BOTH the physics collision
  /// callback below AND from TomAndJerryGame's frame-by-frame proximity
  /// check. Guarded by [_collected] so it only ever fires once per cheese.
  void collectBy(JerryPlayer other) {
    if (_collected || !isMounted) return;
    _collected = true;

    game.collectCheese(other.isPlayerTwo);
    game.world.add(SparkleBurstComponent(
      position: position + size / 2,
      color: const Color(0xFFFFC107),
    ));
    game.world.add(ScorePopupComponent(
      position: position + size / 2,
      text: '+${game.currentCheesePoints}',
    ));
    removeFromParent();
  }

  @override
  void onCollisionStart(Set<Vector2> intersectionPoints, PositionComponent other) {
    super.onCollisionStart(intersectionPoints, other);
    if (other is JerryPlayer) collectBy(other);
  }
}

class ScatterPowerUpComponent extends PositionComponent with CollisionCallbacks {
  final Vector2 gridPosition;
  final TomAndJerryGame game;

  double _t = 0;
  bool _collected = false;

  ScatterPowerUpComponent({required this.gridPosition, required this.game})
      : super(
          position: gridPosition * cellSize + Vector2.all(cellSize * 0.15),
          size: Vector2.all(cellSize * 0.7),
        );

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    add(CircleHitbox.relative(0.7, parentSize: size)..collisionType = CollisionType.passive);
  }

  @override
  void update(double dt) {
    super.update(dt);
    _t += dt;
  }

  @override
  void render(Canvas canvas) {
    final center = Offset(size.x / 2, size.y / 2);
    final pulse = 0.5 + 0.5 * sin(_t * 5);

    // Expanding ripple ring.
    final ringT = (_t * 0.8) % 1.0;
    canvas.drawCircle(
      center,
      size.x * (0.2 + 0.35 * ringT),
      Paint()
        ..color = AppColors.brightCyan.withValues(alpha: 0.45 * (1 - ringT))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Soft glow.
    canvas.drawCircle(
      center,
      size.x * (0.34 + 0.05 * pulse),
      Paint()
        ..color = AppColors.brightCyan.withValues(alpha: 0.25 + 0.2 * pulse)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );

    // Core orb.
    canvas.drawCircle(center, size.x / 3 * (0.92 + 0.08 * pulse), Paint()..color = AppColors.brightCyan);
    canvas.drawCircle(
      Offset(center.dx - size.x * 0.08, center.dy - size.y * 0.08),
      size.x * 0.07,
      Paint()..color = Colors.white.withValues(alpha: 0.75),
    );

    // Three orbiting sparks.
    for (int i = 0; i < 3; i++) {
      final angle = _t * 2.4 + i * (pi * 2 / 3);
      final r = size.x * 0.42;
      canvas.drawCircle(
        Offset(center.dx + cos(angle) * r, center.dy + sin(angle) * r),
        2.4,
        Paint()..color = AppColors.iceBlue.withValues(alpha: 0.9),
      );
    }
  }

  /// Shared pickup logic — see CheeseComponent.collectBy for why this
  /// exists both as a collision callback target and a manual-check target.
  void collectBy(JerryPlayer other) {
    if (_collected || !isMounted) return;
    _collected = true;

    game.triggerScatterPowerUp();
    game.world.add(SparkleBurstComponent(
      position: position + size / 2,
      color: AppColors.brightCyan,
      particleCount: 16,
      duration: 0.55,
    ));
    removeFromParent();
  }

  @override
  void onCollisionStart(Set<Vector2> intersectionPoints, PositionComponent other) {
    super.onCollisionStart(intersectionPoints, other);
    if (other is JerryPlayer) collectBy(other);
  }
}

// =====================================================================
// ANIMATED PLAYER (JERRY)
// =====================================================================
class JerryPlayer extends PositionComponent
    with CollisionCallbacks, HasGameReference<TomAndJerryGame> {
  final Vector2 gridPosition;
  final bool isPlayerTwo;
  final Vector2 _velocity = Vector2.zero();

  // Flips to true the instant Tom catches this player. In co-op this
  // takes the player out of play without necessarily ending the run —
  // see TomAndJerryGame.onPlayerCaught.
  bool isCaught = false;

  // Animation state
  double _animTime = 0;
  double _idleTime = 0;
  bool _isMoving = false;
  double _facing = 1; // 1 = right, -1 = left
  double _facingLerp = 1; // smoothly interpolated flip
  double _trailTimer = 0;

  JerryPlayer({
    required this.gridPosition,
    required this.isPlayerTwo,
  }) : super(
          position: gridPosition * cellSize + Vector2.all(cellSize * 0.05),
          size: Vector2.all(cellSize * 0.9),
          anchor: Anchor.topLeft,
        );

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    // FIX: shrunk from 0.55 -> 0.275 (half of the previous value) so the
    // collision circle is noticeably smaller than Jerry's drawn body.
    // The old 0.55 radius was still wide enough to graze walls / Tom on
    // the up-down-left-right edges even when Jerry looked clearly clear,
    // which felt like an "invisible barrier" letting Tom catch you early.
    add(CircleHitbox.relative(0.275, parentSize: size));
  }

  @override
  void render(Canvas canvas) {
    final w = size.x;
    final h = size.y;

    // --- animation values -------------------------------------------
    final run = _isMoving ? 1.0 : 0.0;
    // Fast bounce while running, slow breathing while standing still.
    final bounce = _isMoving ? sin(_animTime * 14).abs() * h * 0.10 : sin(_idleTime * 2.2) * h * 0.02;
    final squash = _isMoving ? 1 + 0.07 * sin(_animTime * 14) : 1 + 0.03 * sin(_idleTime * 2.2);
    final stretch = 2 - squash;
    final earWiggle = sin(_animTime * 10) * 0.12 * run + sin(_idleTime * 1.6) * 0.04;
    final tailWag = sin(_animTime * 12 + 1) * (0.5 + 0.5 * run);
    final lean = _isMoving ? sin(_animTime * 14) * 0.05 : 0.0;

    final bodyPaint = Paint()..color = isPlayerTwo ? const Color(0xFF0097A7) : const Color(0xFFA0522D);
    final earInnerPaint = Paint()..color = isPlayerTwo ? const Color(0xFFFFFFFF) : const Color(0xFFFFC0CB);
    final eyePaint = Paint()..color = Colors.white;
    final pupilPaint = Paint()..color = Colors.black;
    final accent = isPlayerTwo ? const Color(0xFF00E5FF) : const Color(0xFFFFD166);

    // Ground shadow that shrinks as the character hops.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(w * 0.5, h * 0.96),
        width: w * 0.62 * (1 - bounce / (h * 0.25)).clamp(0.55, 1.1),
        height: h * 0.13,
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.22),
    );

    canvas.save();
    // Hop + squash/stretch + slight running lean.
    canvas.translate(w / 2, h - bounce);
    canvas.scale(squash, stretch);
    canvas.rotate(lean);
    canvas.translate(-w / 2, -h);

    // Horizontal flip so the character always faces where it's heading.
    canvas.save();
    canvas.translate(w / 2, 0);
    canvas.scale(_facingLerp.abs() < 0.05 ? 0.05 * _facingLerp.sign : _facingLerp, 1);
    canvas.translate(-w / 2, 0);

    // Tail, drawn behind the body.
    final tailPaint = Paint()
      ..color = bodyPaint.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.07
      ..strokeCap = StrokeCap.round;
    final tailPath = Path()
      ..moveTo(w * 0.18, h * 0.68)
      ..quadraticBezierTo(
        w * (-0.05 + 0.04 * tailWag),
        h * (0.62 + 0.10 * tailWag),
        w * (0.02 + 0.06 * tailWag),
        h * (0.36 + 0.08 * tailWag),
      );
    canvas.drawPath(tailPath, tailPaint);

    // Ears (wiggle as it runs).
    for (final side in [0, 1]) {
      final ex = side == 0 ? w * 0.2 : w * 0.8;
      final dir = side == 0 ? -1 : 1;
      canvas.save();
      canvas.translate(ex, h * 0.25);
      canvas.rotate(earWiggle * dir);
      canvas.drawCircle(Offset.zero, w * 0.22, bodyPaint);
      canvas.drawCircle(Offset.zero, w * 0.12, earInnerPaint);
      canvas.restore();
    }

    // Body.
    canvas.drawCircle(Offset(w * 0.5, h * 0.55), w * 0.35, bodyPaint);

    // Little running feet.
    final footSwing = sin(_animTime * 14) * w * 0.09 * run;
    canvas.drawOval(
      Rect.fromCenter(center: Offset(w * 0.38 + footSwing, h * 0.87), width: w * 0.2, height: h * 0.1),
      bodyPaint,
    );
    canvas.drawOval(
      Rect.fromCenter(center: Offset(w * 0.62 - footSwing, h * 0.87), width: w * 0.2, height: h * 0.1),
      bodyPaint,
    );

    // Eyes with a periodic blink and pupils that look where it's going.
    final blinkCycle = (_idleTime + _animTime) % 3.4;
    final blinking = blinkCycle > 3.2;
    final lookX = _velocity.x * w * 0.02;
    final lookY = _velocity.y * h * 0.02;

    if (blinking) {
      final linePaint = Paint()
        ..color = Colors.black
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(w * 0.33, h * 0.5), Offset(w * 0.47, h * 0.5), linePaint);
      canvas.drawLine(Offset(w * 0.53, h * 0.5), Offset(w * 0.67, h * 0.5), linePaint);
    } else {
      canvas.drawCircle(Offset(w * 0.4, h * 0.5), w * 0.08, eyePaint);
      canvas.drawCircle(Offset(w * 0.6, h * 0.5), w * 0.08, eyePaint);
      canvas.drawCircle(Offset(w * 0.4 + lookX, h * 0.5 + lookY), w * 0.04, pupilPaint);
      canvas.drawCircle(Offset(w * 0.6 + lookX, h * 0.5 + lookY), w * 0.04, pupilPaint);
    }

    // Nose.
    canvas.drawCircle(Offset(w * 0.5, h * 0.65), w * 0.06, pupilPaint);

    // Whiskers.
    final whiskerPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.75)
      ..strokeWidth = 1.1;
    final wWiggle = sin(_animTime * 9) * 0.02 * h;
    canvas.drawLine(Offset(w * 0.42, h * 0.66), Offset(w * 0.2, h * 0.62 + wWiggle), whiskerPaint);
    canvas.drawLine(Offset(w * 0.58, h * 0.66), Offset(w * 0.8, h * 0.62 - wWiggle), whiskerPaint);

    // Player 2's bow bounces slightly out of phase with the body.
    if (isPlayerTwo) {
      final bowTilt = sin(_animTime * 11) * 0.2;
      canvas.save();
      canvas.translate(w * 0.5, h * 0.08);
      canvas.rotate(bowTilt);
      final bowPaint = Paint()..color = const Color(0xFFFF4081);
      final bowLeft = Path()
        ..moveTo(0, 0)
        ..lineTo(-w * 0.12, -h * 0.08)
        ..lineTo(-w * 0.12, h * 0.08)
        ..close();
      final bowRight = Path()
        ..moveTo(0, 0)
        ..lineTo(w * 0.12, -h * 0.08)
        ..lineTo(w * 0.12, h * 0.08)
        ..close();
      canvas.drawPath(bowLeft, bowPaint);
      canvas.drawPath(bowRight, bowPaint);
      canvas.drawCircle(Offset.zero, w * 0.05, bowPaint);
      canvas.restore();
    }

    canvas.restore(); // undo flip
    canvas.restore(); // undo hop/squash

    // Floating P1 / P2 label — drawn outside the flip so it never mirrors.
    final labelFloat = sin(_idleTime * 2.6 + (isPlayerTwo ? 1.4 : 0)) * h * 0.03;
    final labelPainter = TextPainter(
      text: TextSpan(
        text: isPlayerTwo ? 'P2' : 'P1',
        style: TextStyle(
          fontSize: h * 0.22,
          fontWeight: FontWeight.w900,
          color: accent,
          shadows: const [Shadow(color: Colors.black, blurRadius: 3, offset: Offset(0.5, 0.5))],
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    labelPainter.layout();
    labelPainter.paint(canvas, Offset(w / 2 - labelPainter.width / 2, -h * 0.34 + labelFloat));
  }

  @override
  void update(double dt) {
    super.update(dt);

    _idleTime += dt;

    _velocity.setZero();
    final keys = HardwareKeyboard.instance;

    if (!isPlayerTwo) {
      if (keys.isLogicalKeyPressed(LogicalKeyboardKey.arrowUp)) _velocity.y -= 1;
      if (keys.isLogicalKeyPressed(LogicalKeyboardKey.arrowDown)) _velocity.y += 1;
      if (keys.isLogicalKeyPressed(LogicalKeyboardKey.arrowLeft)) _velocity.x -= 1;
      if (keys.isLogicalKeyPressed(LogicalKeyboardKey.arrowRight)) _velocity.x += 1;
      _velocity.add(game.p1TouchDirection.value);
    } else {
      if (keys.isLogicalKeyPressed(LogicalKeyboardKey.keyW)) _velocity.y -= 1;
      if (keys.isLogicalKeyPressed(LogicalKeyboardKey.keyS)) _velocity.y += 1;
      if (keys.isLogicalKeyPressed(LogicalKeyboardKey.keyA)) _velocity.x -= 1;
      if (keys.isLogicalKeyPressed(LogicalKeyboardKey.keyD)) _velocity.x += 1;
      _velocity.add(game.p2TouchDirection.value);
    }

    _isMoving = _velocity.length2 > 0;

    // Ease the horizontal flip so turning around looks like a spin
    // rather than an instant mirror.
    _facingLerp += (_facing - _facingLerp) * min(1.0, dt * 12);

    if (!_isMoving) return;

    _animTime += dt;

    if (_velocity.x.abs() > 0.01) {
      _facing = _velocity.x > 0 ? 1 : -1;
    }

    _velocity.normalize();
    const speed = 140.0;
    final delta = _velocity * speed * dt;

    // FIX: the rect used to test against maze walls is now noticeably
    // smaller than Jerry's drawn/full body size (see _wallCheckRect).
    // Previously the full 0.9*cellSize sprite rect was tested directly,
    // so Jerry could "catch" on a wall corner even when his visible body
    // still looked clear of it, making tight turns in the maze feel
    // stuck. Shrinking just the collision rect (not the visuals) lets
    // Jerry actually slip through the corridors and around corners.
    final tryX = _wallCheckRect(position.x + delta.x, position.y);
    if (!rectHitsWall(tryX)) position.x += delta.x;

    final tryY = _wallCheckRect(position.x, position.y + delta.y);
    if (!rectHitsWall(tryY)) position.y += delta.y;

    // Dust trail while running.
    _trailTimer -= dt;
    if (_trailTimer <= 0) {
      _trailTimer = 0.09;
      parent?.add(TrailDotComponent(
        position: position + Vector2(size.x / 2, size.y * 0.92),
        color: isPlayerTwo ? AppColors.iceBlue : AppColors.cheeseYellow,
        radius: 4.5,
      ));
    }
  }

  // FIX: fraction of Jerry's width/height trimmed off each side when
  // building the rect that gets checked against the maze walls. Raise
  // this (closer to 0.5) to make passages feel roomier; lower it
  // (closer to 0) to go back to the old, tighter feel.
  static const double _wallCollisionMargin = 0.22;

  /// Builds the (smaller-than-visual) rect used only for maze-wall
  /// collision checks, anchored at the given top-left position. Jerry's
  /// drawn sprite size never changes — only this invisible test box does.
  Rect _wallCheckRect(double px, double py) {
    final marginX = size.x * _wallCollisionMargin;
    final marginY = size.y * _wallCollisionMargin;
    return Rect.fromLTWH(
      px + marginX,
      py + marginY,
      size.x - marginX * 2,
      size.y - marginY * 2,
    );
  }

  @override
  void onCollisionStart(Set<Vector2> intersectionPoints, PositionComponent other) {
    super.onCollisionStart(intersectionPoints, other);
    if (other is TomChaser && !isCaught) game.onPlayerCaught(this);
  }
}

// =====================================================================
// ANIMATED CHASER (TOM)
// =====================================================================
class TomChaser extends PositionComponent
    with CollisionCallbacks, HasGameReference<TomAndJerryGame> {
  final Vector2 gridPosition;
  final double speed;
  @override
  final TomAndJerryGame game;

  List<Vector2> _path = [];
  double _repathTimer = 0;

  // Animation state
  double _glowTime = 0;
  double _animTime = 0;
  double _spawnT = 0;
  bool _isMoving = false;
  double _facing = 1;
  double _facingLerp = 1;
  double _trailTimer = 0;
  Vector2 _lastDir = Vector2(1, 0);

  TomChaser({required this.gridPosition, required this.speed, required this.game})
      : super(
          position: gridPosition * cellSize + Vector2.all(cellSize * 0.05),
          size: Vector2.all(cellSize * 0.9),
          anchor: Anchor.topLeft,
        );

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    add(CircleHitbox.relative(0.8, parentSize: size));
  }

  @override
  void render(Canvas canvas) {
    final w = size.x;
    final h = size.y;

    final pulse = 0.5 + 0.5 * sin(_glowTime * 4);
    final run = _isMoving ? 1.0 : 0.0;
    final bounce = _isMoving ? sin(_animTime * 11).abs() * h * 0.07 : sin(_glowTime * 1.8) * h * 0.015;
    final squash = 1 + 0.05 * sin(_animTime * 11) * run;
    final stretch = 2 - squash;
    final earTwitch = sin(_animTime * 13) * 0.10 * run + sin(_glowTime * 1.3) * 0.03;
    final tailSway = sin(_animTime * 7 + 0.6);
    final spawnPop = Curves.easeOutBack.transform(_spawnT.clamp(0.0, 1.0));

    // Pulsing danger glow — reads as "threat" even at a glance.
    canvas.drawCircle(
      Offset(w * 0.5, h * 0.5),
      (w * 0.55 + (w * 0.1 * pulse)) * spawnPop,
      Paint()
        ..color = Colors.red.withValues(alpha: 0.18 + 0.14 * pulse)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    // Ground shadow.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(w * 0.5, h * 0.97),
        width: w * 0.66 * (1 - bounce / (h * 0.2)).clamp(0.55, 1.1),
        height: h * 0.13,
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.25),
    );

    canvas.save();
    canvas.translate(w / 2, h - bounce);
    canvas.scale(squash * spawnPop, stretch * spawnPop);
    canvas.translate(-w / 2, -h);

    canvas.save();
    canvas.translate(w / 2, 0);
    canvas.scale(_facingLerp.abs() < 0.05 ? 0.05 * _facingLerp.sign : _facingLerp, 1);
    canvas.translate(-w / 2, 0);

    final bodyPaint = Paint()..color = const Color(0xFF708090);
    final earInnerPaint = Paint()..color = const Color(0xFFFFC0CB);
    final eyePaint = Paint()..color = const Color(0xFFFFEB3B);
    final pupilPaint = Paint()..color = Colors.black;

    // Swishing tail behind the body.
    final tailPaint = Paint()
      ..color = bodyPaint.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.09
      ..strokeCap = StrokeCap.round;
    final tailPath = Path()
      ..moveTo(w * 0.16, h * 0.7)
      ..quadraticBezierTo(
        w * (-0.08 + 0.08 * tailSway),
        h * (0.66 + 0.12 * tailSway),
        w * (-0.02 + 0.1 * tailSway),
        h * (0.3 + 0.1 * tailSway),
      );
    canvas.drawPath(tailPath, tailPaint);

    // Twitching ears.
    canvas.save();
    canvas.translate(w * 0.25, h * 0.25);
    canvas.rotate(-earTwitch);
    final leftEar = Path()
      ..moveTo(-w * 0.15, h * 0.15)
      ..lineTo(0, -h * 0.2)
      ..lineTo(w * 0.15, h * 0.05)
      ..close();
    canvas.drawPath(leftEar, bodyPaint);
    canvas.drawCircle(Offset.zero, w * 0.08, earInnerPaint);
    canvas.restore();

    canvas.save();
    canvas.translate(w * 0.75, h * 0.25);
    canvas.rotate(earTwitch);
    final rightEar = Path()
      ..moveTo(-w * 0.15, h * 0.05)
      ..lineTo(0, -h * 0.2)
      ..lineTo(w * 0.15, h * 0.15)
      ..close();
    canvas.drawPath(rightEar, bodyPaint);
    canvas.drawCircle(Offset.zero, w * 0.08, earInnerPaint);
    canvas.restore();

    // Body.
    canvas.drawCircle(Offset(w * 0.5, h * 0.55), w * 0.38, bodyPaint);

    // Paws.
    final pawSwing = sin(_animTime * 11) * w * 0.1 * run;
    canvas.drawOval(
      Rect.fromCenter(center: Offset(w * 0.36 + pawSwing, h * 0.9), width: w * 0.22, height: h * 0.1),
      bodyPaint,
    );
    canvas.drawOval(
      Rect.fromCenter(center: Offset(w * 0.64 - pawSwing, h * 0.9), width: w * 0.22, height: h * 0.1),
      bodyPaint,
    );

    // Glowing, narrowing predator eyes.
    final squint = 1 - 0.25 * pulse;
    canvas.drawOval(
      Rect.fromCenter(center: Offset(w * 0.38, h * 0.5), width: w * 0.18, height: h * 0.18 * squint),
      eyePaint,
    );
    canvas.drawOval(
      Rect.fromCenter(center: Offset(w * 0.62, h * 0.5), width: w * 0.18, height: h * 0.18 * squint),
      eyePaint,
    );
    canvas.drawCircle(Offset(w * 0.38 + _lastDir.x * w * 0.02, h * 0.5), w * 0.04, pupilPaint);
    canvas.drawCircle(Offset(w * 0.62 + _lastDir.x * w * 0.02, h * 0.5), w * 0.04, pupilPaint);

    // Nose + whiskers.
    canvas.drawCircle(Offset(w * 0.5, h * 0.65), w * 0.05, pupilPaint);
    final whiskerPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..strokeWidth = 1.2;
    final wWiggle = sin(_animTime * 8) * h * 0.02;
    canvas.drawLine(Offset(w * 0.42, h * 0.66), Offset(w * 0.14, h * 0.6 + wWiggle), whiskerPaint);
    canvas.drawLine(Offset(w * 0.42, h * 0.69), Offset(w * 0.15, h * 0.74 + wWiggle), whiskerPaint);
    canvas.drawLine(Offset(w * 0.58, h * 0.66), Offset(w * 0.86, h * 0.6 - wWiggle), whiskerPaint);
    canvas.drawLine(Offset(w * 0.58, h * 0.69), Offset(w * 0.85, h * 0.74 - wWiggle), whiskerPaint);

    canvas.restore(); // flip
    canvas.restore(); // hop/squash
  }

  Point<int> _cellOfCenter(Vector2 center) {
    final col = (center.x / cellSize).floor().clamp(0, mazeLayout[0].length - 1);
    final row = (center.y / cellSize).floor().clamp(0, mazeLayout.length - 1);
    return Point(col, row);
  }

  Vector2 _cellCenterWorld(Point<int> cell) {
    return Vector2(cell.x * cellSize + cellSize / 2, cell.y * cellSize + cellSize / 2);
  }

  void _recomputePath() {
    final myCenter = position + size / 2;

    // Either player may have already been caught and removed from play
    // (co-op mode keeps the chase going for whoever is left), so fall
    // back to whichever one is still around instead of always defaulting
    // to jerry1.
    final j1 = game.jerry1;
    final j2 = game.isTwoPlayerMode ? game.jerry2 : null;

    JerryPlayer? targetPlayer;
    if (j1 != null && j2 != null) {
      final dist1 = (j1.position - position).length2;
      final dist2 = (j2.position - position).length2;
      targetPlayer = dist1 < dist2 ? j1 : j2;
    } else {
      targetPlayer = j1 ?? j2;
    }

    if (targetPlayer == null) return;

    final targetCenter = targetPlayer.position + targetPlayer.size / 2;
    final startCell = _cellOfCenter(myCenter);
    final targetCell = _cellOfCenter(targetCenter);
    _path = findGridPath(startCell, targetCell).map(_cellCenterWorld).toList();
  }

  @override
  void update(double dt) {
    super.update(dt);
    _glowTime += dt;
    if (_spawnT < 1) _spawnT = (_spawnT + dt * 3).clamp(0.0, 1.0);

    _facingLerp += (_facing - _facingLerp) * min(1.0, dt * 10);

    _repathTimer -= dt;
    if (_repathTimer <= 0 || _path.isEmpty) {
      _recomputePath();
      _repathTimer = 0.3;
    }

    _isMoving = false;

    if (_path.isNotEmpty) {
      final myCenter = position + size / 2;
      final waypoint = _path.first;
      final toWaypoint = waypoint - myCenter;
      if (toWaypoint.length <= 4) {
        _path.removeAt(0);
      } else {
        toWaypoint.normalize();
        position.add(toWaypoint * speed * dt);

        _isMoving = true;
        _animTime += dt;
        _lastDir = toWaypoint.clone();
        if (toWaypoint.x.abs() > 0.05) {
          _facing = toWaypoint.x > 0 ? 1 : -1;
        }

        // Menacing red trail so you can see where Tom came from.
        _trailTimer -= dt;
        if (_trailTimer <= 0) {
          _trailTimer = 0.11;
          parent?.add(TrailDotComponent(
            position: position + Vector2(size.x / 2, size.y * 0.92),
            color: Colors.redAccent,
            radius: 5.5,
            duration: 0.5,
          ));
        }
      }
    }
  }
}

// =====================================================================
// SHARED ANIMATED UI HELPERS
// =====================================================================

/// Fades + scales a panel in when an overlay first appears.
class PopIn extends StatelessWidget {
  final Widget child;
  final Duration duration;

  const PopIn({super.key, required this.child, this.duration = const Duration(milliseconds: 380)});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: duration,
      curve: Curves.easeOutBack,
      builder: (context, value, child) {
        return Opacity(
          opacity: value.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: 0.86 + 0.14 * value,
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// Continuously pulses its child (scale + optional glow) — used for
/// trophies, titles and other attention-grabbing bits.
class LoopingPulse extends StatefulWidget {
  final Widget child;
  final double minScale;
  final double maxScale;
  final Duration duration;

  const LoopingPulse({
    super.key,
    required this.child,
    this.minScale = 0.94,
    this.maxScale = 1.08,
    this.duration = const Duration(milliseconds: 1100),
  });

  @override
  State<LoopingPulse> createState() => _LoopingPulseState();
}

class _LoopingPulseState extends State<LoopingPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: widget.duration)..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_controller.value);
        return Transform.scale(
          scale: widget.minScale + (widget.maxScale - widget.minScale) * t,
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// Gently floats its child up and down forever.
class LoopingFloat extends StatefulWidget {
  final Widget child;
  final double distance;
  final Duration duration;

  const LoopingFloat({
    super.key,
    required this.child,
    this.distance = 6,
    this.duration = const Duration(milliseconds: 1800),
  });

  @override
  State<LoopingFloat> createState() => _LoopingFloatState();
}

class _LoopingFloatState extends State<LoopingFloat> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: widget.duration)..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_controller.value);
        return Transform.translate(offset: Offset(0, -widget.distance * t), child: child);
      },
      child: widget.child,
    );
  }
}

class GlassPanel extends StatelessWidget {
  final Widget child;
  final Color borderColor;
  final double width;
  final bool isDarkMode;

  const GlassPanel({
    super.key,
    required this.child,
    this.borderColor = AppColors.brightCyan,
    this.width = 480,
    this.isDarkMode = true,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          width: width,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: isDarkMode
                ? AppColors.darkNavy.withValues(alpha: 0.75)
                : AppColors.lightPanel.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: borderColor, width: 2.5),
            boxShadow: [
              BoxShadow(
                color: borderColor.withValues(alpha: 0.25),
                blurRadius: 18,
                spreadRadius: 2,
              )
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Arcade button with a springy press animation and a click sound.
class ArcadeButton extends StatefulWidget {
  final String label;
  final Color color;
  final Color textColor;
  final VoidCallback onTap;

  const ArcadeButton({
    super.key,
    required this.label,
    required this.color,
    required this.textColor,
    required this.onTap,
  });

  @override
  State<ArcadeButton> createState() => _ArcadeButtonState();
}

class _ArcadeButtonState extends State<ArcadeButton> {
  bool _pressed = false;

  void _handleTap() {
    if (!TomAndJerryGame.globalMuted) {
      FlameAudio.play('click.wav');
    }
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _pressed ? 0.95 : 1.0,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOut,
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: widget.color,
            foregroundColor: widget.textColor,
            padding: const EdgeInsets.symmetric(vertical: 20),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: _pressed ? 1 : 4,
          ),
          onPressed: _handleTap,
          onHover: (hovering) => setState(() => _pressed = hovering && _pressed),
          child: Listener(
            onPointerDown: (_) => setState(() => _pressed = true),
            onPointerUp: (_) => setState(() => _pressed = false),
            onPointerCancel: (_) => setState(() => _pressed = false),
            child: Text(
              widget.label,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
            ),
          ),
        ),
      ),
    );
  }
}

// --- ON-SCREEN TOUCH CONTROLS ---

class _DPadButton extends StatefulWidget {
  final IconData icon;
  final Vector2 direction;
  final ValueNotifier<Vector2> target;
  final Color color;

  const _DPadButton({
    required this.icon,
    required this.direction,
    required this.target,
    required this.color,
  });

  @override
  State<_DPadButton> createState() => _DPadButtonState();
}

class _DPadButtonState extends State<_DPadButton> {
  bool _pressed = false;

  void _setDirection(bool active) {
    setState(() => _pressed = active);
    if (active) {
      widget.target.value = widget.direction;
    } else if (widget.target.value == widget.direction) {
      widget.target.value = Vector2.zero();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _setDirection(true),
      onPointerUp: (_) => _setDirection(false),
      onPointerCancel: (_) => _setDirection(false),
      child: AnimatedScale(
        scale: _pressed ? 0.88 : 1.0,
        duration: const Duration(milliseconds: 90),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: _pressed ? 0.9 : 0.55),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.6), width: 2),
            boxShadow: _pressed
                ? [BoxShadow(color: widget.color.withValues(alpha: 0.6), blurRadius: 14, spreadRadius: 1)]
                : const [],
          ),
          child: Icon(widget.icon, color: Colors.white, size: 34),
        ),
      ),
    );
  }
}

class TouchControlsOverlay extends StatelessWidget {
  final TomAndJerryGame game;
  const TouchControlsOverlay({super.key, required this.game});

  Widget _dpad(ValueNotifier<Vector2> target, Color color) {
    return SizedBox(
      width: 220,
      height: 220,
      child: Stack(
        children: [
          Positioned(
              top: 0,
              left: 74,
              child: _DPadButton(icon: Icons.keyboard_arrow_up, direction: Vector2(0, -1), target: target, color: color)),
          Positioned(
              bottom: 0,
              left: 74,
              child: _DPadButton(icon: Icons.keyboard_arrow_down, direction: Vector2(0, 1), target: target, color: color)),
          Positioned(
              top: 74,
              left: 0,
              child: _DPadButton(icon: Icons.keyboard_arrow_left, direction: Vector2(-1, 0), target: target, color: color)),
          Positioned(
              top: 74,
              right: 0,
              child: _DPadButton(icon: Icons.keyboard_arrow_right, direction: Vector2(1, 0), target: target, color: color)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shortestSide = MediaQuery.of(context).size.shortestSide;
    final isMobileSized = shortestSide < 600;
    if (!isMobileSized) {
      return const SizedBox.shrink();
    }

    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _dpad(game.p1TouchDirection, AppColors.brightCyan),
              ),
              if (game.isTwoPlayerMode)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _dpad(game.p2TouchDirection, AppColors.royalBlue),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- OVERLAYS ---

class AuthOverlay extends StatefulWidget {
  final TomAndJerryGame game;
  const AuthOverlay({super.key, required this.game});

  @override
  State<AuthOverlay> createState() => _AuthOverlayState();
}

class _AuthOverlayState extends State<AuthOverlay> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool isRegisterMode = false;
  String messageKey = '';
  bool isError = false;

  bool _obscurePassword = true;
  bool _isProcessing = false;

  void _handleAuth() async {
    if (_isProcessing) return;

    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();
    final confirmPassword = _confirmPasswordController.text.trim();

    setState(() {
      messageKey = '';
      isError = false;
    });

    if (username.isEmpty || password.isEmpty) {
      setState(() {
        messageKey = 'fill_fields';
        isError = true;
      });
      return;
    }

    if (isRegisterMode && password != confirmPassword) {
      setState(() {
        messageKey = 'password_mismatch';
        isError = true;
      });
      return;
    }

    setState(() => _isProcessing = true);

    if (isRegisterMode) {
      final created = await UserStorage.registerUser(username, password);
      if (!mounted) return;

      if (!created) {
        setState(() {
          messageKey = 'user_exists';
          isError = true;
          _isProcessing = false;
        });
        return;
      }

      _usernameController.clear();
      _passwordController.clear();
      _confirmPasswordController.clear();

      setState(() {
        isRegisterMode = false;
        messageKey = 'account_created';
        isError = false;
        _isProcessing = false;
      });
    } else {
      final loginResult = await UserStorage.validateLogin(username, password);
      if (!mounted) return;

      if (loginResult == UserLoginResult.userNotFound) {
        // FIX: clear the mistyped password so the field never keeps a
        // stale/wrong value sitting in it after a failed attempt.
        _passwordController.clear();
        setState(() {
          messageKey = 'user_not_found';
          isError = true;
          _isProcessing = false;
        });
        return;
      }

      if (loginResult == UserLoginResult.wrongPassword) {
        // FIX: same clearing behavior for a wrong-password attempt.
        _passwordController.clear();
        setState(() {
          messageKey = 'wrong_password';
          isError = true;
          _isProcessing = false;
        });
        return;
      }

      widget.game.playerName = username;
      setState(() => _isProcessing = false);
      _proceedToMenu();
    }
  }

  void _proceedToMenu() {
    widget.game.overlays.remove('AuthMenu');
    widget.game.overlays.add('MainMenu');
  }

  void _goToAdminLogin() {
    widget.game.overlays.remove('AuthMenu');
    widget.game.overlays.add('AdminLogin');
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.game.isDarkModeNotifier.value;
    final textColor = isDark ? AppColors.softWhite : AppColors.lightText;
    final accentColor = isDark ? AppColors.brightCyan : AppColors.lightPrimary;

    return Container(
      color: Colors.black.withValues(alpha: 0.35),
      child: Center(
        child: SingleChildScrollView(
          child: PopIn(
            child: GlassPanel(
              isDarkMode: isDark,
              borderColor: accentColor,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      DropdownButton<AppLanguage>(
                        value: widget.game.languageNotifier.value,
                        dropdownColor: isDark ? AppColors.darkNavy : AppColors.lightPanel,
                        style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 16),
                        underline: const SizedBox(),
                        icon: Icon(Icons.language, color: accentColor, size: 28),
                        onChanged: (AppLanguage? newLang) {
                          if (newLang != null) {
                            setState(() {
                              widget.game.setLanguage(newLang);
                            });
                          }
                        },
                        items: AppLanguage.values.map((AppLanguage lang) {
                          return DropdownMenuItem<AppLanguage>(
                            value: lang,
                            child: Text(lang.displayName),
                          );
                        }).toList(),
                      ),
                      IconButton(
                        iconSize: 30,
                        icon: Icon(
                          isDark ? Icons.light_mode : Icons.dark_mode,
                          color: isDark ? AppColors.cheeseYellow : AppColors.lightPrimary,
                        ),
                        onPressed: () {
                          setState(() {
                            widget.game.toggleTheme();
                          });
                        },
                      ),
                    ],
                  ),
                  const LoopingFloat(
                    distance: 8,
                    child: Icon(Icons.videogame_asset, color: AppColors.cheeseYellow, size: 64),
                  ),
                  const SizedBox(height: 8),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Text(
                      widget.game.tr(isRegisterMode ? 'register_title' : 'login_title'),
                      key: ValueKey(isRegisterMode),
                      style: TextStyle(color: textColor, fontSize: 28, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 22),
                  TextField(
                    controller: _usernameController,
                    enabled: !_isProcessing,
                    style: TextStyle(color: textColor, fontSize: 18),
                    decoration: InputDecoration(
                      labelText: widget.game.tr('username'),
                      labelStyle: TextStyle(color: isDark ? AppColors.iceBlue : AppColors.lightPrimary, fontSize: 16),
                      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: accentColor, width: 2)),
                      focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: AppColors.cheeseYellow, width: 2)),
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    enabled: !_isProcessing,
                    style: TextStyle(color: textColor, fontSize: 18),
                    decoration: InputDecoration(
                      labelText: widget.game.tr('password'),
                      labelStyle: TextStyle(color: isDark ? AppColors.iceBlue : AppColors.lightPrimary, fontSize: 16),
                      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: accentColor, width: 2)),
                      focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: AppColors.cheeseYellow, width: 2)),
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword ? Icons.visibility_off : Icons.visibility,
                          color: isDark ? AppColors.iceBlue : AppColors.lightAccent,
                          size: 26,
                        ),
                        onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                      ),
                    ),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOut,
                    child: isRegisterMode
                        ? Padding(
                            padding: const EdgeInsets.only(top: 14),
                            child: TextField(
                              controller: _confirmPasswordController,
                              obscureText: _obscurePassword,
                              enabled: !_isProcessing,
                              style: TextStyle(color: textColor, fontSize: 18),
                              decoration: InputDecoration(
                                labelText: widget.game.tr('confirm_password'),
                                labelStyle: TextStyle(color: isDark ? AppColors.iceBlue : AppColors.lightPrimary, fontSize: 16),
                                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: accentColor, width: 2)),
                                focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: AppColors.cheeseYellow, width: 2)),
                                contentPadding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                            ),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                  const SizedBox(height: 18),
                  if (messageKey.isNotEmpty) ...[
                    TweenAnimationBuilder<double>(
                      key: ValueKey(messageKey),
                      tween: Tween<double>(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 300),
                      builder: (context, v, child) => Opacity(
                        opacity: v,
                        child: Transform.translate(offset: Offset(0, (1 - v) * -8), child: child),
                      ),
                      child: Text(
                        widget.game.tr(messageKey),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: isError ? AppColors.cheeseYellow : AppColors.brightCyan,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  _isProcessing
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 18),
                          child: SizedBox(
                            height: 28,
                            width: 28,
                            child: CircularProgressIndicator(strokeWidth: 3, color: AppColors.brightCyan),
                          ),
                        )
                      : ArcadeButton(
                          label: widget.game.tr(isRegisterMode ? 'register_btn' : 'login_btn'),
                          color: accentColor,
                          textColor: isDark ? AppColors.darkNavy : Colors.white,
                          onTap: _handleAuth,
                        ),
                  TextButton(
                    onPressed: _isProcessing
                        ? null
                        : () {
                            setState(() {
                              isRegisterMode = !isRegisterMode;
                              messageKey = '';
                              _confirmPasswordController.clear();
                            });
                          },
                    child: Text(
                      widget.game.tr(isRegisterMode ? 'switch_to_login' : 'switch_to_register'),
                      style: TextStyle(color: isDark ? AppColors.iceBlue : AppColors.lightAccent, fontSize: 15),
                    ),
                  ),
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: _isProcessing ? null : _goToAdminLogin,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      widget.game.tr('admin_access'),
                      style: TextStyle(
                        color: (isDark ? AppColors.iceBlue : AppColors.lightAccent).withValues(alpha: 0.55),
                        fontSize: 12,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AdminLoginOverlay extends StatefulWidget {
  final TomAndJerryGame game;
  const AdminLoginOverlay({super.key, required this.game});

  @override
  State<AdminLoginOverlay> createState() => _AdminLoginOverlayState();
}

class _AdminLoginOverlayState extends State<AdminLoginOverlay> {
  final _adminPasswordController = TextEditingController();
  bool _obscure = true;
  String messageKey = '';

  void _submit() {
    if (_adminPasswordController.text == AdminConfig.adminPassword) {
      widget.game.overlays.remove('AdminLogin');
      widget.game.overlays.add('AdminDashboard');
    } else {
      setState(() => messageKey = 'wrong_admin_password');
    }
  }

  void _backToAuth() {
    widget.game.overlays.remove('AdminLogin');
    widget.game.overlays.add('AuthMenu');
  }

  @override
  void dispose() {
    _adminPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.game.isDarkModeNotifier.value;
    final textColor = isDark ? AppColors.softWhite : AppColors.lightText;
    final accentColor = isDark ? AppColors.brightCyan : AppColors.lightPrimary;

    return Container(
      color: Colors.black.withValues(alpha: 0.35),
      child: Center(
        child: SingleChildScrollView(
          child: PopIn(
            child: GlassPanel(
              isDarkMode: isDark,
              borderColor: accentColor,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const LoopingPulse(
                    child: Icon(Icons.admin_panel_settings, color: AppColors.cheeseYellow, size: 56),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.game.tr('admin_login_title'),
                    style: TextStyle(color: textColor, fontSize: 26, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 22),
                  TextField(
                    controller: _adminPasswordController,
                    obscureText: _obscure,
                    style: TextStyle(color: textColor, fontSize: 18),
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: widget.game.tr('admin_password'),
                      labelStyle: TextStyle(color: isDark ? AppColors.iceBlue : AppColors.lightPrimary, fontSize: 16),
                      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: accentColor, width: 2)),
                      focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: AppColors.cheeseYellow, width: 2)),
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure ? Icons.visibility_off : Icons.visibility,
                          color: isDark ? AppColors.iceBlue : AppColors.lightAccent,
                          size: 26,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (messageKey.isNotEmpty) ...[
                    Text(
                      widget.game.tr(messageKey),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.cheeseYellow, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                  ],
                  ArcadeButton(
                    label: widget.game.tr('enter_admin_btn'),
                    color: accentColor,
                    textColor: isDark ? AppColors.darkNavy : Colors.white,
                    onTap: _submit,
                  ),
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: _backToAuth,
                    child: Text(
                      widget.game.tr('back'),
                      style: TextStyle(color: isDark ? AppColors.iceBlue : AppColors.lightAccent, fontSize: 15),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MainMenuOverlay extends StatelessWidget {
  final TomAndJerryGame game;
  const MainMenuOverlay({super.key, required this.game});

  @override
  Widget build(BuildContext context) {
    final isDark = game.isDarkModeNotifier.value;
    final textColor = isDark ? AppColors.softWhite : AppColors.lightText;

    return Container(
      color: Colors.black.withValues(alpha: 0.35),
      child: Center(
        child: SingleChildScrollView(
          child: PopIn(
            child: GlassPanel(
              width: 480,
              isDarkMode: isDark,
              borderColor: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 300,
                    height: 250,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        const SizedBox(
                          width: 235,
                          height: 235,
                          child: LoopingPulse(
                            minScale: 0.97,
                            maxScale: 1.03,
                            duration: Duration(milliseconds: 2200),
                            child: CustomPaint(
                              painter: IntelClubLogoPainter(),
                            ),
                          ),
                        ),
                        Container(
                          width: 300,
                          decoration: BoxDecoration(
                            color: AppColors.logoSlate,
                            border: Border.all(color: Colors.white, width: 2.5),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 3),
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: AppColors.logoSlate, width: 2),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: const Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'LA CONSOLACION COLLEGE TANAUAN',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'INTEL',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 38,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 9,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'INFORMATION TECHNOLOGY ENTHUSIASTS OF LA CONSOLACION',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 6.0,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'TOM & JERRY',
                    style: TextStyle(color: AppColors.cheeseYellow, fontSize: 17, fontWeight: FontWeight.bold, letterSpacing: 2),
                  ),
                  LoopingFloat(
                    distance: 4,
                    child: Text(
                      'INTEL BYTE CHASE',
                      style: TextStyle(
                        color: textColor,
                        fontSize: 27,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Divider(color: isDark ? AppColors.brightCyan : AppColors.lightPrimary, thickness: 1.5),
                  const SizedBox(height: 10),
                  Text(
                    '${game.tr('welcome')}, ${game.playerName.toUpperCase()}',
                    style: TextStyle(color: textColor, fontSize: 19, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  ArcadeButton(
                    label: game.tr('play_game'),
                    color: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
                    textColor: isDark ? AppColors.darkNavy : Colors.white,
                    onTap: () {
                      game.overlays.remove('MainMenu');
                      game.overlays.add('ModeSelect');
                    },
                  ),
                  const SizedBox(height: 8),
                  ArcadeButton(
                    label: game.tr('how_to_play'),
                    color: isDark ? AppColors.primaryBlue : AppColors.lightAccent,
                    textColor: Colors.white,
                    onTap: () {
                      game.overlays.remove('MainMenu');
                      game.overlays.add('HowToPlay');
                    },
                  ),
                  const SizedBox(height: 8),
                  ArcadeButton(
                    label: game.tr('leaderboard'),
                    color: AppColors.royalBlue,
                    textColor: Colors.white,
                    onTap: () {
                      game.overlays.remove('MainMenu');
                      game.overlays.add('Leaderboard');
                    },
                  ),
                  const SizedBox(height: 8),
                  ArcadeButton(
                    label: game.tr('options'),
                    color: isDark ? AppColors.deepBlue : Colors.blueGrey.shade100,
                    textColor: isDark ? AppColors.softWhite : AppColors.lightText,
                    onTap: () {
                      game.overlays.remove('MainMenu');
                      game.overlays.add('OptionsMenu');
                    },
                  ),
                  const SizedBox(height: 8),
                  ArcadeButton(
                    label: game.tr('logout'),
                    color: Colors.redAccent.shade700,
                    textColor: Colors.white,
                    onTap: () {
                      game.logout();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HowToPlayOverlay extends StatelessWidget {
  final TomAndJerryGame game;
  const HowToPlayOverlay({super.key, required this.game});

  @override
  Widget build(BuildContext context) {
    final isDark = game.isDarkModeNotifier.value;
    final textColor = isDark ? AppColors.softWhite : AppColors.lightText;

    return Container(
      color: Colors.black.withValues(alpha: 0.35),
      child: Center(
        child: SingleChildScrollView(
          child: PopIn(
            child: GlassPanel(
              width: 500,
              isDarkMode: isDark,
              borderColor: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const LoopingPulse(
                        child: Icon(Icons.help_outline, color: AppColors.cheeseYellow, size: 36),
                      ),
                      const SizedBox(width: 10),
                      Text(game.tr('how_to_play'),
                          style: const TextStyle(color: AppColors.cheeseYellow, fontSize: 26, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 22),
                  _buildGuideItem(
                    icon: Icons.sports_esports,
                    title: game.tr('controls'),
                    desc: game.tr('controls_desc'),
                    textColor: textColor,
                  ),
                  const SizedBox(height: 14),
                  _buildGuideItem(
                    icon: Icons.restaurant,
                    title: game.tr('collect_cheese'),
                    desc: game.tr('cheese_desc'),
                    textColor: textColor,
                  ),
                  const SizedBox(height: 14),
                  _buildGuideItem(
                    icon: Icons.stars,
                    title: game.tr('power_ups'),
                    desc: game.tr('power_desc'),
                    textColor: textColor,
                  ),
                  const SizedBox(height: 14),
                  _buildGuideItem(
                    icon: Icons.warning_amber_rounded,
                    title: game.tr('avoid_tom'),
                    desc: game.tr('tom_desc'),
                    textColor: textColor,
                  ),
                  const SizedBox(height: 26),
                  ArcadeButton(
                    label: game.tr('back'),
                    color: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
                    textColor: isDark ? AppColors.darkNavy : Colors.white,
                    onTap: () {
                      game.overlays.remove('HowToPlay');
                      game.overlays.add('MainMenu');
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGuideItem({
    required IconData icon,
    required String title,
    required String desc,
    required Color textColor,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: AppColors.brightCyan, size: 30),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 18)),
              const SizedBox(height: 4),
              Text(desc, style: TextStyle(color: textColor.withValues(alpha: 0.85), fontSize: 15)),
            ],
          ),
        )
      ],
    );
  }
}

class ModeSelectOverlay extends StatelessWidget {
  final TomAndJerryGame game;
  const ModeSelectOverlay({super.key, required this.game});

  @override
  Widget build(BuildContext context) {
    final isDark = game.isDarkModeNotifier.value;
    return Container(
      color: Colors.black.withValues(alpha: 0.35),
      child: Center(
        child: PopIn(
          child: GlassPanel(
            isDarkMode: isDark,
            borderColor: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(game.tr('select_mode'),
                    style: TextStyle(
                        color: isDark ? AppColors.softWhite : AppColors.lightText,
                        fontSize: 24,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 20),
                ArcadeButton(
                  label: game.tr('mode_1p'),
                  color: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
                  textColor: isDark ? AppColors.darkNavy : Colors.white,
                  onTap: () {
                    game.isTwoPlayerMode = false;
                    game.overlays.remove('ModeSelect');
                    game.overlays.add('Difficulty');
                  },
                ),
                const SizedBox(height: 8),
                ArcadeButton(
                  label: game.tr('mode_2p'),
                  color: AppColors.royalBlue,
                  textColor: Colors.white,
                  onTap: () {
                    game.isTwoPlayerMode = true;
                    game.overlays.remove('ModeSelect');
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const LobbyScreen(),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    game.overlays.remove('ModeSelect');
                    game.overlays.add('MainMenu');
                  },
                  child: Text(game.tr('back'),
                      style: TextStyle(color: isDark ? AppColors.iceBlue : AppColors.lightAccent, fontSize: 16)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Leaderboard, now split into per-category tabs (Easy / Average / Hard /
/// Endless) backed by DifficultyScoreStore, so clearing HARD's target and
/// running endless shows up as its own ranked list instead of blending
/// into a single "high score" number.
class LeaderboardOverlay extends StatefulWidget {
  final TomAndJerryGame game;
  const LeaderboardOverlay({super.key, required this.game});

  @override
  State<LeaderboardOverlay> createState() => _LeaderboardOverlayState();
}

class _LeaderboardOverlayState extends State<LeaderboardOverlay> {
  Map<String, Map<String, int>> _allScores = {};
  bool _isLoading = true;
  String _category = 'EASY';

  @override
  void initState() {
    super.initState();
    _loadLeaderboard();
  }

  Future<void> _loadLeaderboard() async {
    final data = await DifficultyScoreStore.loadAll();
    if (!mounted) return;
    setState(() {
      _allScores = data;
      _isLoading = false;
    });
  }

  List<MapEntry<String, int>> get _sortedScores {
    final list = _allScores.entries
        .where((e) => e.value.containsKey(_category))
        .map((e) => MapEntry(e.key, e.value[_category]!))
        .toList();
    list.sort((a, b) => b.value.compareTo(a.value));
    return list;
  }

  Future<void> _clearScores() async {
    await DifficultyScoreStore.clearAll();
    if (!mounted) return;
    setState(() => _allScores = {});
  }

  Widget _categoryChip(String label, String value, bool isDark) {
    final selected = _category == value;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        selected: selected,
        selectedColor: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
        backgroundColor: (isDark ? AppColors.deepBlue : Colors.white).withValues(alpha: 0.6),
        labelStyle: TextStyle(
          color: selected ? AppColors.darkNavy : (isDark ? Colors.white : AppColors.lightText),
        ),
        onSelected: (_) => setState(() => _category = value),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.game.isDarkModeNotifier.value;
    final textColor = isDark ? AppColors.softWhite : AppColors.lightText;

    return Container(
      color: Colors.black.withValues(alpha: 0.35),
      child: Center(
        child: PopIn(
          child: GlassPanel(
            width: 520,
            isDarkMode: isDark,
            borderColor: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const LoopingPulse(
                      child: Icon(Icons.emoji_events, color: AppColors.cheeseYellow, size: 36),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      widget.game.tr('leaderboard'),
                      style: TextStyle(color: textColor, fontSize: 26, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    _categoryChip(widget.game.tr('easy'), 'EASY', isDark),
                    _categoryChip(widget.game.tr('average'), 'AVERAGE', isDark),
                    _categoryChip(widget.game.tr('hard'), 'HARD', isDark),
                    _categoryChip(widget.game.tr('endless_badge'), 'ENDLESS', isDark),
                  ],
                ),
                const SizedBox(height: 16),
                _isLoading
                    ? const CircularProgressIndicator(color: AppColors.brightCyan)
                    : _sortedScores.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Text(widget.game.tr('no_scores'),
                                style: TextStyle(
                                    color: isDark ? AppColors.iceBlue : AppColors.lightAccent, fontSize: 16)),
                          )
                        : Container(
                            height: 280,
                            decoration: BoxDecoration(
                              color: isDark
                                  ? AppColors.deepBlue.withValues(alpha: 0.6)
                                  : Colors.white.withValues(alpha: 0.8),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: isDark
                                      ? AppColors.brightCyan.withValues(alpha: 0.5)
                                      : AppColors.lightPrimary,
                                  width: 1.5),
                            ),
                            child: ListView.separated(
                              padding: const EdgeInsets.all(10),
                              itemCount: _sortedScores.length,
                              separatorBuilder: (context, index) => const Divider(color: Colors.black12),
                              itemBuilder: (context, index) {
                                final entry = _sortedScores[index];
                                // Staggered slide-in for the first rows.
                                return TweenAnimationBuilder<double>(
                                  tween: Tween<double>(begin: 0, end: 1),
                                  duration: Duration(milliseconds: 260 + (index.clamp(0, 8) * 45)),
                                  curve: Curves.easeOut,
                                  builder: (context, v, child) => Opacity(
                                    opacity: v,
                                    child: Transform.translate(offset: Offset((1 - v) * 24, 0), child: child),
                                  ),
                                  child: ListTile(
                                    dense: true,
                                    leading: CircleAvatar(
                                      backgroundColor: index == 0
                                          ? AppColors.cheeseYellow
                                          : index == 1
                                              ? Colors.grey.shade300
                                              : index == 2
                                                  ? Colors.amber.shade800
                                                  : AppColors.primaryBlue,
                                      radius: 18,
                                      child: Text(
                                        '${index + 1}',
                                        style: const TextStyle(
                                            color: AppColors.darkNavy, fontSize: 15, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                    title: Text(
                                      entry.key.toUpperCase(),
                                      style: TextStyle(
                                          color: isDark ? Colors.white : AppColors.lightText,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16),
                                    ),
                                    trailing: Text(
                                      '${entry.value} PTS',
                                      style: const TextStyle(
                                          color: AppColors.cheeseYellow, fontWeight: FontWeight.bold, fontSize: 17),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                const SizedBox(height: 16),
                if (_sortedScores.isNotEmpty) ...[
                  TextButton.icon(
                    onPressed: _clearScores,
                    icon: Icon(Icons.delete_forever,
                        color: isDark ? AppColors.iceBlue : AppColors.lightAccent, size: 24),
                    label: Text(widget.game.tr('clear_scores'),
                        style: TextStyle(color: isDark ? AppColors.iceBlue : AppColors.lightAccent, fontSize: 16)),
                  ),
                  const SizedBox(height: 10),
                ],
                ArcadeButton(
                  label: widget.game.tr('back'),
                  color: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
                  textColor: isDark ? AppColors.darkNavy : Colors.white,
                  onTap: () {
                    widget.game.overlays.remove('Leaderboard');
                    widget.game.overlays.add('MainMenu');
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- ADMIN DASHBOARD SUPPORT TYPES ---

enum _AdminSortMode { nameAsc, newest, oldest, scoreDesc }

class _AdminAccountRow {
  final String username;
  final String createdAtIso;
  final int score;

  _AdminAccountRow({
    required this.username,
    required this.createdAtIso,
    required this.score,
  });
}

/// Admin Dashboard — reachable only after the admin password check.
///
/// Search, sort (including "Oldest First / First Registered"), multi-select
/// bulk delete, stats strip, manual refresh, a FIRST badge on the earliest
/// registered account, and the PDF report download. Scores shown here are
/// each player's single best result across every category (Easy, Average,
/// Hard, Endless), sourced from DifficultyScoreStore.
class AdminDashboardOverlay extends StatefulWidget {
  final TomAndJerryGame game;
  const AdminDashboardOverlay({super.key, required this.game});

  @override
  State<AdminDashboardOverlay> createState() => _AdminDashboardOverlayState();
}

class _AdminDashboardOverlayState extends State<AdminDashboardOverlay> {
  List<_AdminAccountRow> _allAccounts = [];
  Map<String, int> _highScores = {};
  Map<String, Map<String, int>> _categorizedScores = {};

  bool _isLoading = true;
  bool _isDownloading = false;

  final _searchController = TextEditingController();
  String _searchQuery = '';
  _AdminSortMode _sortMode = _AdminSortMode.oldest; // default: first registered on top

  ReportTimeframe _exportTimeframe = ReportTimeframe.allTime;

  final Set<String> _selectedUsernames = {};

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text.trim().toLowerCase());
    });
    _loadAccounts();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadAccounts() async {
    setState(() => _isLoading = true);

    // Repair any missing registration dates before displaying, so the
    // dashboard never shows "Unknown" and the ordering stays meaningful.
    await UserStorage.backfillMissingCreatedAt();

    final details = await UserStorage.loadUserDetails();

    // Per-category (Easy/Average/Hard/Endless) scores for every player —
    // kept in full so the exported report can show a per-difficulty
    // breakdown instead of a single blended number.
    final categorized = await DifficultyScoreStore.loadAll();
    final scores = <String, int>{
      for (final entry in categorized.entries)
        entry.key: DifficultyScoreStore.bestOverallFor(entry.value),
    };

    final rows = details.entries
        .map((e) => _AdminAccountRow(
              username: e.key,
              createdAtIso: e.value['createdAt'] ?? '',
              score: scores[e.key] ?? 0,
            ))
        .toList();

    if (!mounted) return;
    setState(() {
      _allAccounts = rows;
      _highScores = scores;
      _categorizedScores = categorized;
      _selectedUsernames.removeWhere((u) => !rows.any((r) => r.username == u));
      _isLoading = false;
    });
  }

  /// The single earliest registered account, used for the FIRST badge.
  String? get _firstRegisteredUsername {
    final dated = _allAccounts.where((r) => r.createdAtIso.isNotEmpty).toList();
    if (dated.isEmpty) return null;
    dated.sort((a, b) => compareByCreatedAtAsc(a.createdAtIso, b.createdAtIso));
    return dated.first.username;
  }

  List<_AdminAccountRow> get _visibleAccounts {
    var rows = _allAccounts.where((r) {
      if (_searchQuery.isEmpty) return true;
      return r.username.contains(_searchQuery);
    }).toList();

    switch (_sortMode) {
      case _AdminSortMode.nameAsc:
        rows.sort((a, b) => a.username.compareTo(b.username));
        break;
      case _AdminSortMode.newest:
        rows.sort((a, b) => compareByCreatedAtAsc(b.createdAtIso, a.createdAtIso));
        break;
      case _AdminSortMode.oldest:
        rows.sort((a, b) => compareByCreatedAtAsc(a.createdAtIso, b.createdAtIso));
        break;
      case _AdminSortMode.scoreDesc:
        rows.sort((a, b) => b.score.compareTo(a.score));
        break;
    }
    return rows;
  }

  int get _topScore =>
      _highScores.values.isEmpty ? 0 : _highScores.values.reduce(max);

  double get _avgScore {
    if (_highScores.isEmpty) return 0;
    final total = _highScores.values.fold<int>(0, (sum, v) => sum + v);
    return total / _highScores.length;
  }

  /// Builds the PDF and downloads it straight away, filtered down to
  /// accounts registered within the currently selected export timeframe
  /// (Daily / Weekly / Monthly / Yearly / All Time). Each account is
  /// handed over with its raw ISO date AND its full per-difficulty score
  /// breakdown, so the report can order by actual registration time,
  /// highlight the earliest player within that window, and show
  /// Easy/Average/Hard/Endless scores side by side instead of one
  /// blended number.
  Future<void> _downloadReport() async {
    if (_isDownloading) return;
    setState(() => _isDownloading = true);
    try {
      final entries = _allAccounts
          .map((r) => AccountLogEntry(
                username: r.username,
                createdAtIso: r.createdAtIso,
                createdAtLabel: formatAccountDate(r.createdAtIso),
                categoryScores: _categorizedScores[r.username] ?? const {},
              ))
          .toList();

      await ReportService.downloadUserLogsReport(
        accounts: entries,
        timeframe: _exportTimeframe,
      );
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  Future<void> _confirmDelete(String username) async {
    final isDark = widget.game.isDarkModeNotifier.value;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: isDark ? AppColors.deepBlue : Colors.white,
        title: Text(
          widget.game.tr('delete_account_title'),
          style: TextStyle(
              color: isDark ? AppColors.softWhite : AppColors.lightText,
              fontWeight: FontWeight.bold,
              fontSize: 20),
        ),
        content: Text(
          widget.game.tr('delete_account_msg'),
          style: TextStyle(color: isDark ? AppColors.iceBlue : AppColors.lightText, fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(widget.game.tr('cancel'),
                style: TextStyle(color: isDark ? AppColors.iceBlue : AppColors.lightAccent, fontSize: 16)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(widget.game.tr('delete'),
                style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 16)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await UserStorage.deleteUser(username);
      _selectedUsernames.remove(username);
      await _loadAccounts();
    }
  }

  Future<void> _confirmDeleteSelected() async {
    if (_selectedUsernames.isEmpty) return;
    final isDark = widget.game.isDarkModeNotifier.value;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: isDark ? AppColors.deepBlue : Colors.white,
        title: Text(
          widget.game.tr('delete_selected_title'),
          style: TextStyle(
              color: isDark ? AppColors.softWhite : AppColors.lightText,
              fontWeight: FontWeight.bold,
              fontSize: 20),
        ),
        content: Text(
          widget.game.tr('delete_selected_msg'),
          style: TextStyle(color: isDark ? AppColors.iceBlue : AppColors.lightText, fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(widget.game.tr('cancel'),
                style: TextStyle(color: isDark ? AppColors.iceBlue : AppColors.lightAccent, fontSize: 16)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(widget.game.tr('delete'),
                style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 16)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      for (final username in _selectedUsernames.toList()) {
        await UserStorage.deleteUser(username);
      }
      _selectedUsernames.clear();
      await _loadAccounts();
    }
  }

  void _toggleSelected(String username, bool? value) {
    setState(() {
      if (value == true) {
        _selectedUsernames.add(username);
      } else {
        _selectedUsernames.remove(username);
      }
    });
  }

  void _exitAdmin() {
    widget.game.overlays.remove('AdminDashboard');
    widget.game.overlays.add('AuthMenu');
  }

  void _openAdminSettings() {
    widget.game.overlays.remove('AdminDashboard');
    widget.game.overlays.add('AdminSettings');
  }

  Widget _statChip({
    required IconData icon,
    required String label,
    required String value,
    required bool isDark,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        margin: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          color: (isDark ? AppColors.brightCyan : AppColors.lightPrimary).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: (isDark ? AppColors.brightCyan : AppColors.lightPrimary).withValues(alpha: 0.4)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: isDark ? AppColors.brightCyan : AppColors.lightPrimary),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                color: isDark ? Colors.white : AppColors.lightText,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark ? AppColors.iceBlue : AppColors.lightAccent,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _timeframeChip(String label, ReportTimeframe value, bool isDark) {
    final selected = _exportTimeframe == value;
    return Padding(
      padding: const EdgeInsets.only(right: 6, bottom: 6),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
        selected: selected,
        selectedColor: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
        backgroundColor: (isDark ? AppColors.deepBlue : Colors.white).withValues(alpha: 0.6),
        labelStyle: TextStyle(
          color: selected ? AppColors.darkNavy : (isDark ? Colors.white : AppColors.lightText),
        ),
        onSelected: (_) => setState(() => _exportTimeframe = value),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.game.isDarkModeNotifier.value;
    final textColor = isDark ? AppColors.softWhite : AppColors.lightText;
    final accentColor = isDark ? AppColors.brightCyan : AppColors.lightPrimary;
    final visible = _visibleAccounts;
    final firstUser = _firstRegisteredUsername;

    return Container(
      color: Colors.black.withValues(alpha: 0.35),
      child: Center(
        child: SingleChildScrollView(
          child: PopIn(
            child: GlassPanel(
              width: 560,
              isDarkMode: isDark,
              borderColor: accentColor,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.admin_panel_settings, color: AppColors.cheeseYellow, size: 36),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          widget.game.tr('admin_dashboard_title'),
                          style: TextStyle(color: textColor, fontSize: 24, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      IconButton(
                        tooltip: widget.game.tr('admin_settings'),
                        icon: Icon(Icons.tune, color: accentColor),
                        onPressed: _openAdminSettings,
                      ),
                      IconButton(
                        tooltip: widget.game.tr('refresh'),
                        icon: Icon(Icons.refresh, color: accentColor),
                        onPressed: _isLoading ? null : _loadAccounts,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),

                  if (!_isLoading)
                    Row(
                      children: [
                        _statChip(
                          icon: Icons.group,
                          label: widget.game.tr('total_accounts'),
                          value: '${_allAccounts.length}',
                          isDark: isDark,
                        ),
                        _statChip(
                          icon: Icons.equalizer,
                          label: widget.game.tr('avg_score_label'),
                          value: _avgScore.toStringAsFixed(0),
                          isDark: isDark,
                        ),
                        _statChip(
                          icon: Icons.emoji_events,
                          label: widget.game.tr('top_score_label'),
                          value: '$_topScore',
                          isDark: isDark,
                        ),
                      ],
                    ),

                  // Highlight of the very first registered player.
                  if (!_isLoading && firstUser != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                      decoration: BoxDecoration(
                        color: AppColors.cheeseYellow.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.cheeseYellow.withValues(alpha: 0.5)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.flag, color: AppColors.cheeseYellow, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${widget.game.tr('first_player_label')}: ${firstUser.toUpperCase()}',
                              style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),

                  TextField(
                    controller: _searchController,
                    style: TextStyle(color: textColor, fontSize: 15),
                    decoration: InputDecoration(
                      hintText: widget.game.tr('search_accounts'),
                      hintStyle: TextStyle(
                          color: isDark
                              ? AppColors.iceBlue.withValues(alpha: 0.7)
                              : AppColors.lightAccent.withValues(alpha: 0.7)),
                      prefixIcon: Icon(Icons.search, color: accentColor, size: 22),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: Icon(Icons.close, color: accentColor, size: 20),
                              onPressed: () => _searchController.clear(),
                            )
                          : null,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                      filled: true,
                      fillColor: (isDark ? AppColors.deepBlue : Colors.white).withValues(alpha: 0.6),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: accentColor.withValues(alpha: 0.5)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.cheeseYellow, width: 1.6),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  Row(
                    children: [
                      Icon(Icons.sort, size: 18, color: isDark ? AppColors.iceBlue : AppColors.lightAccent),
                      const SizedBox(width: 6),
                      Expanded(
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<_AdminSortMode>(
                            isExpanded: true,
                            value: _sortMode,
                            dropdownColor: isDark ? AppColors.darkNavy : AppColors.lightPanel,
                            style: TextStyle(color: textColor, fontSize: 14, fontWeight: FontWeight.bold),
                            onChanged: (mode) {
                              if (mode != null) setState(() => _sortMode = mode);
                            },
                            items: [
                              DropdownMenuItem(
                                  value: _AdminSortMode.oldest, child: Text(widget.game.tr('sort_oldest'))),
                              DropdownMenuItem(
                                  value: _AdminSortMode.newest, child: Text(widget.game.tr('sort_newest'))),
                              DropdownMenuItem(
                                  value: _AdminSortMode.nameAsc, child: Text(widget.game.tr('sort_name'))),
                              DropdownMenuItem(
                                  value: _AdminSortMode.scoreDesc, child: Text(widget.game.tr('sort_score'))),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  if (_selectedUsernames.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${_selectedUsernames.length} ${widget.game.tr('selected_count')}',
                              style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                          ),
                          TextButton(
                            onPressed: () => setState(() => _selectedUsernames.clear()),
                            child: Text(widget.game.tr('clear_selection'),
                                style: TextStyle(
                                    color: isDark ? AppColors.iceBlue : AppColors.lightAccent, fontSize: 13)),
                          ),
                          TextButton.icon(
                            onPressed: _confirmDeleteSelected,
                            icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                            label: Text(widget.game.tr('delete_selected'),
                                style: const TextStyle(
                                    color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ),

                  _isLoading
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 40),
                          child: CircularProgressIndicator(color: AppColors.brightCyan),
                        )
                      : _allAccounts.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.symmetric(vertical: 24),
                              child: Text(
                                widget.game.tr('no_accounts'),
                                style: TextStyle(
                                    color: isDark ? AppColors.iceBlue : AppColors.lightAccent, fontSize: 16),
                              ),
                            )
                          : visible.isEmpty
                              ? Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 24),
                                  child: Text(
                                    widget.game.tr('no_search_results'),
                                    style: TextStyle(
                                        color: isDark ? AppColors.iceBlue : AppColors.lightAccent, fontSize: 15),
                                    textAlign: TextAlign.center,
                                  ),
                                )
                              : Container(
                                  height: 300,
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? AppColors.deepBlue.withValues(alpha: 0.6)
                                        : Colors.white.withValues(alpha: 0.8),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                        color: isDark
                                            ? AppColors.brightCyan.withValues(alpha: 0.5)
                                            : AppColors.lightPrimary,
                                        width: 1.5),
                                  ),
                                  child: ListView.separated(
                                    padding: const EdgeInsets.all(8),
                                    itemCount: visible.length,
                                    separatorBuilder: (context, index) =>
                                        const Divider(color: Colors.black12, height: 1),
                                    itemBuilder: (context, index) {
                                      final account = visible[index];
                                      final username = account.username;
                                      final createdLabel = formatAccountDate(account.createdAtIso);
                                      final isSelected = _selectedUsernames.contains(username);
                                      final isFirst = username == firstUser;

                                      return AnimatedContainer(
                                        duration: const Duration(milliseconds: 180),
                                        color: isSelected
                                            ? (isDark
                                                ? AppColors.brightCyan.withValues(alpha: 0.12)
                                                : AppColors.lightPrimary.withValues(alpha: 0.1))
                                            : Colors.transparent,
                                        child: ListTile(
                                          dense: true,
                                          onTap: () => _toggleSelected(username, !isSelected),
                                          leading: SizedBox(
                                            width: 40,
                                            child: Checkbox(
                                              value: isSelected,
                                              activeColor: accentColor,
                                              onChanged: (v) => _toggleSelected(username, v),
                                            ),
                                          ),
                                          title: Row(
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  username.toUpperCase(),
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                      color: isDark ? Colors.white : AppColors.lightText,
                                                      fontWeight: FontWeight.bold,
                                                      fontSize: 15),
                                                ),
                                              ),
                                              if (isFirst) ...[
                                                const SizedBox(width: 6),
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                  decoration: BoxDecoration(
                                                    color: AppColors.cheeseYellow,
                                                    borderRadius: BorderRadius.circular(6),
                                                  ),
                                                  child: Text(
                                                    widget.game.tr('first_badge'),
                                                    style: const TextStyle(
                                                        color: AppColors.darkNavy,
                                                        fontSize: 9.5,
                                                        fontWeight: FontWeight.w900),
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                          subtitle: Text(
                                            '${widget.game.tr('joined_on')}: $createdLabel',
                                            style: TextStyle(
                                                color: isDark ? AppColors.iceBlue : AppColors.lightAccent,
                                                fontSize: 12),
                                          ),
                                          trailing: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                decoration: BoxDecoration(
                                                  color: AppColors.cheeseYellow.withValues(alpha: 0.18),
                                                  borderRadius: BorderRadius.circular(8),
                                                ),
                                                child: Text(
                                                  '${account.score}',
                                                  style: const TextStyle(
                                                      color: AppColors.cheeseYellow,
                                                      fontWeight: FontWeight.bold,
                                                      fontSize: 13),
                                                ),
                                              ),
                                              IconButton(
                                                icon: const Icon(Icons.delete_outline,
                                                    color: Colors.redAccent, size: 24),
                                                tooltip: widget.game.tr('delete'),
                                                onPressed: () => _confirmDelete(username),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                  const SizedBox(height: 16),

                  if (!_isLoading) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        widget.game.tr('export_timeframe_label'),
                        style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      children: [
                        _timeframeChip(widget.game.tr('timeframe_all'), ReportTimeframe.allTime, isDark),
                        _timeframeChip(widget.game.tr('timeframe_daily'), ReportTimeframe.daily, isDark),
                        _timeframeChip(widget.game.tr('timeframe_weekly'), ReportTimeframe.weekly, isDark),
                        _timeframeChip(widget.game.tr('timeframe_monthly'), ReportTimeframe.monthly, isDark),
                        _timeframeChip(widget.game.tr('timeframe_yearly'), ReportTimeframe.yearly, isDark),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],

                  if (!_isLoading)
                    _isDownloading
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 10),
                            child: SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.brightCyan),
                            ),
                          )
                        : Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: ArcadeButton(
                              label: widget.game.tr('print_report'),
                              color: AppColors.royalBlue,
                              textColor: Colors.white,
                              onTap: _downloadReport,
                            ),
                          ),

                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ArcadeButton(
                      label: widget.game.tr('admin_settings'),
                      color: AppColors.deepBlue,
                      textColor: Colors.white,
                      onTap: _openAdminSettings,
                    ),
                  ),

                  ArcadeButton(
                    label: widget.game.tr('exit_admin'),
                    color: Colors.redAccent.shade700,
                    textColor: Colors.white,
                    onTap: _exitAdmin,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- ADMIN SETTINGS: DYNAMIC DIFFICULTY CONFIGURATION ---

/// Admin Settings — lets the Admin adjust each difficulty's speed, Tom
/// spawn interval, max Toms on screen, target score, and points per
/// cheese, all without touching source code. Values are persisted via
/// [DifficultySettingsStore] and take effect on the very next run.
class AdminSettingsOverlay extends StatefulWidget {
  final TomAndJerryGame game;
  const AdminSettingsOverlay({super.key, required this.game});

  @override
  State<AdminSettingsOverlay> createState() => _AdminSettingsOverlayState();
}

class _AdminSettingsOverlayState extends State<AdminSettingsOverlay> {
  static const List<String> _difficulties = ['EASY', 'AVERAGE', 'HARD'];
  static const List<String> _fields = [
    'speed',
    'spawnInterval',
    'maxToms',
    'targetScore',
    'cheesePoints',
  ];

  bool _isLoading = true;
  bool _isSaving = false;
  String _selectedDifficulty = 'EASY';

  // controllers[difficulty][field]
  final Map<String, Map<String, TextEditingController>> _controllers = {
    for (final d in _difficulties) d: {for (final f in _fields) f: TextEditingController()},
  };

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    for (final fieldMap in _controllers.values) {
      for (final c in fieldMap.values) {
        c.dispose();
      }
    }
    super.dispose();
  }

  Future<void> _loadSettings() async {
    setState(() => _isLoading = true);
    final settings = await DifficultySettingsStore.loadAll();
    for (final diff in _difficulties) {
      final values = settings[diff] ?? DifficultySettingsStore.defaultSettings[diff]!;
      for (final field in _fields) {
        _controllers[diff]![field]!.text = (values[field] ?? 0).toString();
      }
    }
    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  String _labelFor(String field) {
    switch (field) {
      case 'speed':
        return widget.game.tr('speed_label');
      case 'spawnInterval':
        return widget.game.tr('spawn_interval_label');
      case 'maxToms':
        return widget.game.tr('max_toms_label');
      case 'targetScore':
        return widget.game.tr('target_score_label');
      case 'cheesePoints':
        return widget.game.tr('cheese_points_label');
      default:
        return field;
    }
  }

  Future<void> _save() async {
    if (_isSaving) return;

    // Validate every field across every difficulty before writing
    // anything, so a typo never leaves the stored settings half-updated.
    final parsed = <String, Map<String, num>>{};
    for (final diff in _difficulties) {
      final values = <String, num>{};
      for (final field in _fields) {
        final raw = _controllers[diff]![field]!.text.trim();
        final n = num.tryParse(raw);
        if (n == null || n < 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(widget.game.tr('invalid_number'))),
          );
          return;
        }
        values[field] = n;
      }
      parsed[diff] = values;
    }

    setState(() => _isSaving = true);
    await DifficultySettingsStore.saveAll(parsed);
    await widget.game.reloadDifficultySettings();
    if (!mounted) return;
    setState(() => _isSaving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(widget.game.tr('settings_saved'))),
    );
  }

  Future<void> _confirmReset() async {
    final isDark = widget.game.isDarkModeNotifier.value;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: isDark ? AppColors.deepBlue : Colors.white,
        title: Text(
          widget.game.tr('confirm_reset_title'),
          style: TextStyle(
              color: isDark ? AppColors.softWhite : AppColors.lightText,
              fontWeight: FontWeight.bold,
              fontSize: 20),
        ),
        content: Text(
          widget.game.tr('confirm_reset_msg'),
          style: TextStyle(color: isDark ? AppColors.iceBlue : AppColors.lightText, fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(widget.game.tr('cancel'),
                style: TextStyle(color: isDark ? AppColors.iceBlue : AppColors.lightAccent, fontSize: 16)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(widget.game.tr('reset_default'),
                style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 16)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await DifficultySettingsStore.resetToDefault();
      await widget.game.reloadDifficultySettings();
      await _loadSettings();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.game.tr('settings_reset'))),
      );
    }
  }

  void _back() {
    widget.game.overlays.remove('AdminSettings');
    widget.game.overlays.add('AdminDashboard');
  }

  Widget _difficultyChip(String diff, bool isDark) {
    final selected = _selectedDifficulty == diff;
    final label = diff == 'EASY'
        ? widget.game.tr('easy')
        : diff == 'AVERAGE'
            ? widget.game.tr('average')
            : widget.game.tr('hard');
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
        selected: selected,
        selectedColor: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
        backgroundColor: (isDark ? AppColors.deepBlue : Colors.white).withValues(alpha: 0.6),
        labelStyle: TextStyle(
          color: selected ? AppColors.darkNavy : (isDark ? Colors.white : AppColors.lightText),
        ),
        onSelected: (_) => setState(() => _selectedDifficulty = diff),
      ),
    );
  }

  Widget _numberField(String field, bool isDark, Color accentColor, Color textColor) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: _controllers[_selectedDifficulty]![field],
        keyboardType: const TextInputType.numberWithOptions(decimal: false),
        style: TextStyle(color: textColor, fontSize: 16),
        decoration: InputDecoration(
          labelText: _labelFor(field),
          labelStyle: TextStyle(color: isDark ? AppColors.iceBlue : AppColors.lightPrimary, fontSize: 14),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          filled: true,
          fillColor: (isDark ? AppColors.deepBlue : Colors.white).withValues(alpha: 0.5),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: accentColor.withValues(alpha: 0.5)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.cheeseYellow, width: 1.6),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.game.isDarkModeNotifier.value;
    final textColor = isDark ? AppColors.softWhite : AppColors.lightText;
    final accentColor = isDark ? AppColors.brightCyan : AppColors.lightPrimary;

    return Container(
      color: Colors.black.withValues(alpha: 0.35),
      child: Center(
        child: SingleChildScrollView(
          child: PopIn(
            child: GlassPanel(
              width: 480,
              isDarkMode: isDark,
              borderColor: accentColor,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.tune, color: AppColors.cheeseYellow, size: 30),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          widget.game.tr('admin_settings'),
                          style: TextStyle(color: textColor, fontSize: 22, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.game.tr('difficulty_settings_title'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: isDark ? AppColors.iceBlue : AppColors.lightAccent, fontSize: 12.5),
                  ),
                  const SizedBox(height: 16),

                  _isLoading
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 40),
                          child: CircularProgressIndicator(color: AppColors.brightCyan),
                        )
                      : Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                for (final d in _difficulties) _difficultyChip(d, isDark),
                              ],
                            ),
                            const SizedBox(height: 16),
                            for (final field in _fields) _numberField(field, isDark, accentColor, textColor),
                            const SizedBox(height: 6),
                            _isSaving
                                ? const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 12),
                                    child: SizedBox(
                                      height: 22,
                                      width: 22,
                                      child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.brightCyan),
                                    ),
                                  )
                                : ArcadeButton(
                                    label: widget.game.tr('save_settings'),
                                    color: accentColor,
                                    textColor: isDark ? AppColors.darkNavy : Colors.white,
                                    onTap: _save,
                                  ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: _confirmReset,
                              icon: const Icon(Icons.restore, color: Colors.redAccent, size: 20),
                              label: Text(widget.game.tr('reset_default'),
                                  style: const TextStyle(
                                      color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 14)),
                            ),
                          ],
                        ),
                  const SizedBox(height: 8),
                  ArcadeButton(
                    label: widget.game.tr('back'),
                    color: AppColors.deepBlue,
                    textColor: Colors.white,
                    onTap: _back,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class OptionsMenuOverlay extends StatefulWidget {
  final TomAndJerryGame game;
  const OptionsMenuOverlay({super.key, required this.game});

  @override
  State<OptionsMenuOverlay> createState() => _OptionsMenuOverlayState();
}

class _OptionsMenuOverlayState extends State<OptionsMenuOverlay> {
  @override
  Widget build(BuildContext context) {
    final isDark = widget.game.isDarkModeNotifier.value;
    final textColor = isDark ? AppColors.softWhite : AppColors.lightText;

    return Container(
      color: Colors.black.withValues(alpha: 0.35),
      child: Center(
        child: PopIn(
          child: GlassPanel(
            isDarkMode: isDark,
            borderColor: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.game.tr('options'),
                    style: TextStyle(color: textColor, fontSize: 26, fontWeight: FontWeight.bold)),
                const SizedBox(height: 26),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(widget.game.tr('theme_mode'),
                        style: TextStyle(color: textColor, fontSize: 18, fontWeight: FontWeight.bold)),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
                        foregroundColor: isDark ? AppColors.darkNavy : Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      onPressed: () {
                        setState(() {
                          widget.game.toggleTheme();
                        });
                      },
                      icon: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        transitionBuilder: (child, anim) => RotationTransition(turns: anim, child: child),
                        child: Icon(isDark ? Icons.dark_mode : Icons.light_mode,
                            key: ValueKey(isDark), size: 22),
                      ),
                      label: Text(isDark ? 'DARK' : 'LIGHT'),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(widget.game.tr('language'),
                        style: TextStyle(color: textColor, fontSize: 18, fontWeight: FontWeight.bold)),
                    DropdownButton<AppLanguage>(
                      value: widget.game.languageNotifier.value,
                      dropdownColor: isDark ? AppColors.darkNavy : AppColors.lightPanel,
                      style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 16),
                      underline: Container(height: 1.5, color: isDark ? AppColors.brightCyan : AppColors.lightPrimary),
                      onChanged: (AppLanguage? newLang) {
                        if (newLang != null) {
                          setState(() {
                            widget.game.setLanguage(newLang);
                          });
                        }
                      },
                      items: AppLanguage.values.map((AppLanguage lang) {
                        return DropdownMenuItem<AppLanguage>(
                          value: lang,
                          child: Text(lang.displayName),
                        );
                      }).toList(),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(widget.game.tr('sound'),
                        style: TextStyle(color: textColor, fontSize: 18, fontWeight: FontWeight.bold)),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
                        foregroundColor: isDark ? AppColors.darkNavy : Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      onPressed: () {
                        setState(() {
                          widget.game.toggleMute();
                        });
                      },
                      icon: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
                        child: Icon(
                          widget.game.isMutedNotifier.value ? Icons.volume_off : Icons.volume_up,
                          key: ValueKey(widget.game.isMutedNotifier.value),
                          size: 22,
                        ),
                      ),
                      label: Text(widget.game.isMutedNotifier.value ? 'MUTED' : 'ON'),
                    ),
                  ],
                ),
                const SizedBox(height: 30),
                ArcadeButton(
                  label: widget.game.tr('back'),
                  color: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
                  textColor: isDark ? AppColors.darkNavy : Colors.white,
                  onTap: () {
                    widget.game.overlays.remove('OptionsMenu');
                    widget.game.overlays.add('MainMenu');
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DifficultyOverlay extends StatefulWidget {
  final TomAndJerryGame game;
  const DifficultyOverlay({super.key, required this.game});

  @override
  State<DifficultyOverlay> createState() => _DifficultyOverlayState();
}

class _DifficultyOverlayState extends State<DifficultyOverlay> {
  bool _isLoading = true;
  bool _averageUnlocked = false;
  bool _hardUnlocked = false;
  bool _endlessUnlocked = false;

  @override
  void initState() {
    super.initState();
    _loadProgress();
  }

  Future<void> _loadProgress() async {
    final completed = await DifficultyProgress.getCompleted(widget.game.playerName);
    if (!mounted) return;
    setState(() {
      _averageUnlocked = completed.contains('EASY');
      _hardUnlocked = completed.contains('AVERAGE');
      // ENDLESS is unlocked once HARD has been completed — either by
      // finishing a normal HARD run, or by reaching HARD's target mid-run
      // (which also marks 'HARD' as completed, see _unlockEndless()).
      _endlessUnlocked = completed.contains('HARD');
      _isLoading = false;
    });
  }

  void _showLockedMessage() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(widget.game.tr('locked_diff_msg'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.game.isDarkModeNotifier.value;
    final textColor = isDark ? AppColors.softWhite : AppColors.lightText;

    return Container(
      color: Colors.black.withValues(alpha: 0.35),
      child: Center(
        child: PopIn(
          child: GlassPanel(
            isDarkMode: isDark,
            borderColor: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.game.tr('select_diff'),
                    style: TextStyle(color: textColor, fontSize: 24, fontWeight: FontWeight.bold)),
                const SizedBox(height: 20),
                ArcadeButton(
                  label: widget.game.tr('easy'),
                  color: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
                  textColor: isDark ? AppColors.darkNavy : Colors.white,
                  onTap: () => widget.game.startGame(widget.game.playerName, 'EASY'),
                ),
                const SizedBox(height: 8),
                _buildLockableButton(
                  label: widget.game.tr('average'),
                  unlocked: !_isLoading && _averageUnlocked,
                  color: AppColors.royalBlue,
                  onTap: () => widget.game.startGame(widget.game.playerName, 'AVERAGE'),
                ),
                const SizedBox(height: 8),
                _buildLockableButton(
                  label: widget.game.tr('hard'),
                  unlocked: !_isLoading && _hardUnlocked,
                  color: AppColors.deepBlue,
                  onTap: () => widget.game.startGame(widget.game.playerName, 'HARD'),
                ),
                const SizedBox(height: 8),
                // Explicit ENDLESS mode: starts the run already in endless
                // play (HARD's speed/spawns, no target score, no pause) —
                // unlocked once HARD has been cleared at least once.
                _buildLockableButton(
                  label: widget.game.tr('endless_badge'),
                  unlocked: !_isLoading && _endlessUnlocked,
                  color: AppColors.brightCyan,
                  onTap: () => widget.game.startGame(widget.game.playerName, 'ENDLESS'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    widget.game.overlays.remove('Difficulty');
                    widget.game.overlays.add('ModeSelect');
                  },
                  child: Text(widget.game.tr('back'),
                      style: TextStyle(color: isDark ? AppColors.iceBlue : AppColors.lightAccent, fontSize: 16)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLockableButton({
    required String label,
    required bool unlocked,
    required Color color,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: double.infinity,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: unlocked ? color : Colors.grey.shade600,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 20),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 4,
          ),
          onPressed: () {
            if (!TomAndJerryGame.globalMuted) {
              FlameAudio.play('click.wav');
            }
            if (unlocked) {
              onTap();
            } else {
              _showLockedMessage();
            }
          },
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!unlocked) ...[
                const Icon(Icons.lock, size: 18, color: Colors.white70),
                const SizedBox(width: 8),
              ],
              Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
            ],
          ),
        ),
      ),
    );
  }
}

class HudOverlay extends StatelessWidget {
  final TomAndJerryGame game;
  const HudOverlay({super.key, required this.game});

  /// Score text that smoothly counts up to the new value and gives a
  /// little kick whenever it changes.
  Widget _animatedScore(int score, TextStyle style) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: score.toDouble()),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOut,
      builder: (context, value, child) {
        final kick = 1 + 0.12 * (1 - (value - score).abs().clamp(0.0, 10.0) / 10.0) *
            ((score - value).abs() > 0.5 ? 1 : 0);
        return Transform.scale(
          scale: kick,
          child: Text(value.round().toString(), style: style),
        );
      },
    );
  }

  /// Small "OUT!" pill shown next to a player's score once they've been
  /// caught by Tom in co-op mode (the chase itself keeps going for their
  /// partner — see TomAndJerryGame.onPlayerCaught).
  Widget _outBadge(ValueNotifier<bool> caughtNotifier, String label) {
    return ValueListenableBuilder<bool>(
      valueListenable: caughtNotifier,
      builder: (context, caught, _) => caught
          ? Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                label,
                style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 12),
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = game.isDarkModeNotifier.value;
    final p1Style = TextStyle(
        color: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
        fontWeight: FontWeight.bold,
        fontSize: 18);
    final p2Style = TextStyle(
        color: isDark ? AppColors.iceBlue : AppColors.lightAccent,
        fontWeight: FontWeight.bold,
        fontSize: 18);

    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: PopIn(
          duration: const Duration(milliseconds: 300),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
            margin: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(
              color: (isDark ? AppColors.darkNavy : AppColors.lightPanel).withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: isDark ? AppColors.brightCyan : AppColors.lightPrimary, width: 2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('P1 (${game.playerName}): ', style: p1Style),
                ValueListenableBuilder<int>(
                  valueListenable: game.p1ScoreNotifier,
                  builder: (context, score, _) => _animatedScore(score, p1Style),
                ),
                _outBadge(game.p1CaughtNotifier, game.tr('player_out')),
                if (game.isTwoPlayerMode) ...[
                  const SizedBox(width: 18),
                  Text('|', style: TextStyle(color: isDark ? AppColors.iceBlue : AppColors.lightAccent, fontSize: 18)),
                  const SizedBox(width: 18),
                  Text('P2: ', style: p2Style),
                  ValueListenableBuilder<int>(
                    valueListenable: game.p2ScoreNotifier,
                    builder: (context, score, _) => _animatedScore(score, p2Style),
                  ),
                  _outBadge(game.p2CaughtNotifier, game.tr('player_out')),
                ],
                // Small pill that appears once HARD's target has been
                // cleared and the run has entered endless mode.
                ValueListenableBuilder<bool>(
                  valueListenable: game.isEndlessNotifier,
                  builder: (context, isEndless, _) => isEndless
                      ? Padding(
                          padding: const EdgeInsets.only(left: 14),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: AppColors.brightCyan,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              game.tr('endless_badge'),
                              style: const TextStyle(
                                  color: AppColors.darkNavy, fontWeight: FontWeight.w900, fontSize: 11),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                const SizedBox(width: 18),
                IconButton(
                  iconSize: 30,
                  icon: Icon(Icons.pause, color: isDark ? Colors.white : AppColors.lightText),
                  onPressed: () => game.pauseGame(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class GameOverOverlay extends StatelessWidget {
  final TomAndJerryGame game;
  const GameOverOverlay({super.key, required this.game});

  @override
  Widget build(BuildContext context) {
    final isDark = game.isDarkModeNotifier.value;
    final textColor = isDark ? AppColors.softWhite : AppColors.lightText;

    return Container(
      color: Colors.black.withValues(alpha: 0.5),
      child: Center(
        child: PopIn(
          child: GlassPanel(
            isDarkMode: isDark,
            borderColor: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LoopingPulse(
                  minScale: 0.97,
                  maxScale: 1.06,
                  child: Text(game.tr('game_over'),
                      style: TextStyle(color: textColor, fontSize: 34, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: 12),
                Text('P1 (${game.playerName}) Score: ${game.p1ScoreNotifier.value}',
                    style: const TextStyle(color: AppColors.brightCyan, fontSize: 20, fontWeight: FontWeight.bold)),
                if (game.isTwoPlayerMode) ...[
                  const SizedBox(height: 6),
                  Text('P2 Score: ${game.p2ScoreNotifier.value}',
                      style: TextStyle(
                          color: isDark ? AppColors.iceBlue : AppColors.lightAccent,
                          fontSize: 20,
                          fontWeight: FontWeight.bold)),
                ],
                const SizedBox(height: 22),
                ArcadeButton(
                  label: game.tr('try_again'),
                  color: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
                  textColor: isDark ? AppColors.darkNavy : Colors.white,
                  onTap: () => game.restartGame(),
                ),
                const SizedBox(height: 8),
                ArcadeButton(
                  label: game.tr('main_menu'),
                  color: AppColors.deepBlue,
                  textColor: Colors.white,
                  onTap: () => game.quitToMenu(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class LevelCompleteOverlay extends StatelessWidget {
  final TomAndJerryGame game;
  const LevelCompleteOverlay({super.key, required this.game});

  @override
  Widget build(BuildContext context) {
    final isDark = game.isDarkModeNotifier.value;
    final textColor = isDark ? AppColors.softWhite : AppColors.lightText;
    final nextDiff = game.nextDifficulty();

    return Container(
      color: Colors.black.withValues(alpha: 0.5),
      child: Center(
        child: PopIn(
          child: GlassPanel(
            isDarkMode: isDark,
            borderColor: AppColors.cheeseYellow,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const LoopingPulse(
                  minScale: 0.9,
                  maxScale: 1.15,
                  child: Icon(Icons.emoji_events, color: AppColors.cheeseYellow, size: 56),
                ),
                const SizedBox(height: 10),
                LoopingFloat(
                  distance: 5,
                  child: Text(game.tr('level_complete'),
                      style: const TextStyle(
                          color: AppColors.cheeseYellow, fontSize: 28, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: 10),
                Text(
                  game.tr('level_complete_msg'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: textColor, fontSize: 16),
                ),
                const SizedBox(height: 20),
                if (nextDiff != null)
                  ArcadeButton(
                    label: '${game.tr('next_difficulty')}: ${game.tr(nextDiff == 'AVERAGE' ? 'average' : 'hard')}',
                    color: AppColors.brightCyan,
                    textColor: AppColors.darkNavy,
                    onTap: () => game.startGame(game.playerName, nextDiff),
                  ),
                const SizedBox(height: 8),
                ArcadeButton(
                  label: game.tr('main_menu'),
                  color: AppColors.deepBlue,
                  textColor: Colors.white,
                  onTap: () => game.quitToMenu(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PauseMenuOverlay extends StatelessWidget {
  final TomAndJerryGame game;
  const PauseMenuOverlay({super.key, required this.game});

  @override
  Widget build(BuildContext context) {
    final isDark = game.isDarkModeNotifier.value;
    return Container(
      color: Colors.black.withValues(alpha: 0.5),
      child: Center(
        child: PopIn(
          child: GlassPanel(
            isDarkMode: isDark,
            borderColor: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(game.tr('paused'),
                    style: TextStyle(
                        color: isDark ? AppColors.softWhite : AppColors.lightText,
                        fontSize: 30,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 20),
                ArcadeButton(
                  label: game.tr('resume'),
                  color: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
                  textColor: isDark ? AppColors.darkNavy : Colors.white,
                  onTap: () => game.resumeGame(),
                ),
                const SizedBox(height: 8),
                ArcadeButton(
                  label: game.tr('main_menu'),
                  color: AppColors.deepBlue,
                  textColor: Colors.white,
                  onTap: () => game.quitToMenu(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class IntelClubLogoPainter extends CustomPainter {
  const IntelClubLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final darkSlate = AppColors.logoSlate;
    final lightCyan = const Color(0xFF62B6CB);

    final center = Offset(size.width / 2, size.height / 2);
    final outerRadius = size.width / 2;

    Path createHexPath(double r) {
      final path = Path();
      for (int i = 0; i < 6; i++) {
        final angle = (i * 60 - 30) * (pi / 180);
        final x = center.dx + r * cos(angle);
        final y = center.dy + r * sin(angle);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      path.close();
      return path;
    }

    final outerHexPath = createHexPath(outerRadius - 4);
    final outerHexPaint = Paint()
      ..color = darkSlate
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9.0;
    canvas.drawPath(outerHexPath, outerHexPaint);

    final innerHexPath = createHexPath(outerRadius - 14);
    final innerHexPaint = Paint()
      ..color = darkSlate
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawPath(innerHexPath, innerHexPaint);

    final powerArcPaint = Paint()
      ..color = lightCyan
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14.0
      ..strokeCap = StrokeCap.butt;

    final powerRect = Rect.fromCircle(center: center, radius: outerRadius * 0.52);
    canvas.drawArc(powerRect, -0.9, 4.95, false, powerArcPaint);

    final powerLinePaint = Paint()
      ..color = lightCyan
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14.0
      ..strokeCap = StrokeCap.butt;

    canvas.drawLine(
      Offset(center.dx, center.dy - outerRadius * 0.68),
      Offset(center.dx, center.dy - outerRadius * 0.12),
      powerLinePaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Shown to the room host (Tom) right after creating a room, while
/// waiting for the second player (Jerry) to join. Listens to the room
/// document in real time; the moment its status flips to 'playing'
/// (set by MultiplayerService.joinRoom when Jerry joins), Tom is taken
/// straight into a running co-op match via GameApp's multiplayer entry
/// point — never back through AuthMenu.
class WaitingScreen extends StatefulWidget {
  final String roomId;
  const WaitingScreen({super.key, required this.roomId});

  @override
  State<WaitingScreen> createState() => _WaitingScreenState();
}

class _WaitingScreenState extends State<WaitingScreen> {
  bool _navigated = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('game_rooms')
            .doc(widget.roomId)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data!.exists) {
            final data = snapshot.data!.data() as Map<String, dynamic>;

            // Kapag naging 'playing' na ang status galing sa Firestore,
            // lilipat si Tom papunta sa aktwal na laro (hindi na pabalik
            // sa AuthMenu) — sa sandaling ito lang tayo mag-navigate,
            // guarded ng _navigated para hindi paulit-ulit i-push ang
            // route sa bawat snapshot update.
            if (data['status'] == 'playing' && !_navigated) {
              _navigated = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const GameApp(
                      startInGame: true,
                      startTwoPlayer: true,
                      playerName: 'Tom',
                    ),
                  ),
                );
              });
            }
          }

          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 20),
                Text(
                  'Waiting for Jerry to join...',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}