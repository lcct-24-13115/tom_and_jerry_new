"""
Moves accounts, scores, difficulty progress and admin settings from
SharedPreferences (browser localStorage - wiped easily) to Cloud Firestore
(permanent, shared across devices/ports/Netlify).

Run from the project root:   python apply_firestore_db.py
Then:                        flutter pub add crypto
"""
import sys

PATH = "lib/main.dart"
s = open(PATH, encoding="utf-8", newline="").read()
crlf = "\r\n" in s
s = s.replace("\r\n", "\n")

if "_dbKey(" in s:
    print("Already patched. Nothing to do.")
    sys.exit(0)

def once(text, old, new, label):
    if text.count(old) != 1:
        sys.exit("ABORT (%s): expected 1 match, found %d.\n%s" % (label, text.count(old), old[:100]))
    return text.replace(old, new)

def between(text, a, b, new, label):
    i = text.find(a)
    j = text.find(b, i + 1) if i != -1 else -1
    if i == -1 or j == -1:
        sys.exit("ABORT (%s): markers not found." % label)
    return text[:i] + new + text[j:]

# ---------------------------------------------------------------- imports
s = once(s, "import 'package:cloud_firestore/cloud_firestore.dart';\n",
         "import 'package:cloud_firestore/cloud_firestore.dart';\nimport 'package:crypto/crypto.dart';\n", "import")

# ---------------------------------------------------------------- flag
s = once(s, "// --- USER ACCOUNT STORAGE ---\n",
"""// Set to true only if regular players should be allowed to wipe the shared
// leaderboard. With a shared database, one click would erase EVERYONE's scores.
const bool kAllowPlayersToClearScores = false;

// --- USER ACCOUNT STORAGE ---
""", "flag")

# ---------------------------------------------------------------- UserStorage
USER_STORAGE = r'''/// Firestore document id for a username (lowercase, URL-encoded, prefixed so
/// it can never collide with Firestore's reserved ids such as "." or "__x__").
String _dbKey(String username) => 'u_${Uri.encodeComponent(username.trim().toLowerCase())}';

/// Persistent storage of registered player accounts in Cloud Firestore
/// (collection `users`). Unlike SharedPreferences/localStorage, this data
/// survives cleared browsers, new ports, new devices and the Netlify site.
/// Passwords are stored as salted SHA-256 hashes (old plain-text accounts
/// are still accepted and keep working).
class UserStorage {
  static CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection('users');

  static String _newSalt() {
    final rand = Random.secure();
    return List.generate(16, (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static String _hash(String salt, String password) =>
      sha256.convert(utf8.encode('$salt:$password')).toString();

  static Map<String, dynamic> _credentialFields(String password) {
    final salt = _newSalt();
    return {'salt': salt, 'passwordHash': _hash(salt, password)};
  }

  /// {lowercase_username: {'password': legacyPlainOrEmpty, 'createdAt': iso}}
  static Future<Map<String, Map<String, String>>> _loadUsersRaw() async {
    final snap = await _col.get();
    final result = <String, Map<String, String>>{};
    for (final doc in snap.docs) {
      final data = doc.data();
      final name = (data['username'] ?? '').toString();
      if (name.isEmpty) continue;
      result[name] = {
        'password': data['password']?.toString() ?? '',
        'createdAt': data['createdAt']?.toString() ?? '',
      };
    }
    return result;
  }

  static Future<Map<String, String>> loadUsers() async {
    final raw = await _loadUsersRaw();
    return raw.map((key, value) => MapEntry(key, value['password'] ?? ''));
  }

  static Future<Map<String, Map<String, String>>> loadUserDetails() async {
    return _loadUsersRaw();
  }

  /// Registers a new account. Returns `false` if the username is taken.
  /// Uses a transaction so two people can never grab the same name at once.
  static Future<bool> registerUser(String username, String password, {String? createdAt}) async {
    final lowerUser = username.trim().toLowerCase();
    final ref = _col.doc(_dbKey(lowerUser));
    return FirebaseFirestore.instance.runTransaction<bool>((tx) async {
      final existing = await tx.get(ref);
      if (existing.exists) return false;
      tx.set(ref, {
        'username': lowerUser,
        ..._credentialFields(password),
        'createdAt': createdAt ?? DateTime.now().toIso8601String(),
      });
      return true;
    });
  }

  /// Sets (or creates) one account's createdAt, keeping its password.
  static Future<void> setAccountCreatedAt(
    String username,
    String createdAt, {
    String fallbackPassword = 'demo1234',
  }) async {
    final lowerUser = username.trim().toLowerCase();
    final ref = _col.doc(_dbKey(lowerUser));
    final data = (await ref.get()).data();
    final hasCredential = data != null &&
        ((data['passwordHash'] ?? '').toString().isNotEmpty ||
            (data['password'] ?? '').toString().isNotEmpty);
    await ref.set({
      'username': lowerUser,
      if (!hasCredential) ..._credentialFields(fallbackPassword),
      'createdAt': createdAt,
    }, SetOptions(merge: true));
  }

  /// Bulk-creates demo accounts that do not exist yet (used by the seeder).
  static Future<void> seedAccounts(
    Map<String, String> createdAtByUser, {
    String fallbackPassword = 'demo1234',
  }) async {
    final existing = (await _col.get()).docs.map((d) => d.id).toSet();
    var batch = FirebaseFirestore.instance.batch();
    var n = 0;
    for (final e in createdAtByUser.entries) {
      final lower = e.key.trim().toLowerCase();
      final id = _dbKey(lower);
      if (existing.contains(id)) continue;
      batch.set(_col.doc(id), {
        'username': lower,
        ..._credentialFields(fallbackPassword),
        'createdAt': e.value,
      });
      n++;
      if (n % 400 == 0) {
        await batch.commit();
        batch = FirebaseFirestore.instance.batch();
      }
    }
    if (n % 400 != 0) await batch.commit();
  }

  /// Repairs accounts whose createdAt is missing/empty (deterministic dates).
  static Future<int> backfillMissingCreatedAt() async {
    final users = await _loadUsersRaw();
    if (users.isEmpty) return 0;

    final keys = users.keys.toList()..sort();
    final batch = FirebaseFirestore.instance.batch();
    int repaired = 0;

    for (int i = 0; i < keys.length; i++) {
      final key = keys[i];
      final existing = users[key]!['createdAt'] ?? '';
      if (existing.isNotEmpty) continue;
      batch.set(
        _col.doc(_dbKey(key)),
        {'createdAt': _deterministicCreatedAt(key, i)},
        SetOptions(merge: true),
      );
      repaired++;
    }

    if (repaired > 0) await batch.commit();
    return repaired;
  }

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
    final snap = await _col.doc(_dbKey(lowerUser)).get();
    if (!snap.exists) return UserLoginResult.userNotFound;

    final data = snap.data() ?? <String, dynamic>{};
    final hash = (data['passwordHash'] ?? '').toString();
    final bool ok;
    if (hash.isNotEmpty) {
      ok = _hash((data['salt'] ?? '').toString(), password) == hash;
    } else {
      ok = (data['password'] ?? '').toString() == password; // legacy account
    }
    return ok ? UserLoginResult.success : UserLoginResult.wrongPassword;
  }

  static Future<bool> userExists(String username) async {
    final snap = await _col.doc(_dbKey(username)).get();
    return snap.exists;
  }

  static Future<void> deleteUser(String username) async {
    await _col.doc(_dbKey(username)).delete();
  }

  static Future<void> clearAllUsers() async {
    final snap = await _col.get();
    final batch = FirebaseFirestore.instance.batch();
    for (final d in snap.docs) {
      batch.delete(d.reference);
    }
    await batch.commit();
  }
}

'''
s = between(s, "/// Handles persistent storage of registered player accounts",
            "/// Shared helper for demo/repair timestamps", USER_STORAGE, "UserStorage")

# ---------------------------------------------------------------- Progress + Scores
PROGRESS_SCORES = r'''// --- DIFFICULTY PROGRESS STORAGE (Firestore: progress/{user}) ---
class DifficultyProgress {
  static DocumentReference<Map<String, dynamic>> _ref(String username) =>
      FirebaseFirestore.instance.collection('progress').doc(_dbKey(username));

  static Future<Set<String>> getCompleted(String username) async {
    try {
      final snap = await _ref(username).get();
      final raw = snap.data()?['completed'];
      if (raw is List) return raw.map((e) => e.toString()).toSet();
    } catch (e) {
      debugPrint('DifficultyProgress.getCompleted failed: $e');
    }
    return {};
  }

  static Future<void> markCompleted(String username, String difficulty) async {
    try {
      await _ref(username).set({
        'username': username.trim().toLowerCase(),
        'completed': FieldValue.arrayUnion([difficulty]),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('DifficultyProgress.markCompleted failed: $e');
    }
  }
}

// --- PER-DIFFICULTY / ENDLESS HIGH SCORE STORAGE (Firestore: scores/{user}) ---
//
// Best score per player, PER category: 'EASY', 'AVERAGE', 'HARD', 'ENDLESS'.
// A score is only overwritten when the new run beats the previous best for
// that same category (done inside a transaction, so it can never regress).
class DifficultyScoreStore {
  static CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection('scores');

  /// {lowercase_username: {category: bestScore}}
  static Future<Map<String, Map<String, int>>> loadAll() async {
    try {
      final snap = await _col.get();
      final result = <String, Map<String, int>>{};
      for (final doc in snap.docs) {
        final data = doc.data();
        final user = (data['username'] ?? '').toString();
        if (user.isEmpty) continue;
        final scores = <String, int>{};
        data.forEach((key, value) {
          if (key != 'username' && value is num) scores[key] = value.toInt();
        });
        if (scores.isNotEmpty) result[user] = scores;
      }
      return result;
    } catch (e) {
      debugPrint('DifficultyScoreStore.loadAll failed: $e');
      return {};
    }
  }

  static Future<void> submitScore(String username, String category, int score) async {
    final lowerUser = username.trim().toLowerCase();
    final ref = _col.doc(_dbKey(lowerUser));
    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(ref);
        final current = snap.data()?[category];
        final best = current is num ? current.toInt() : 0;
        if (score > best) {
          tx.set(ref, {'username': lowerUser, category: score}, SetOptions(merge: true));
        }
      });
    } catch (e) {
      debugPrint('DifficultyScoreStore.submitScore failed: $e');
    }
  }

  static int bestOverallFor(Map<String, int> categoryScores) {
    if (categoryScores.isEmpty) return 0;
    return categoryScores.values.reduce(max);
  }

  static Future<void> clearAll() async {
    final snap = await _col.get();
    final batch = FirebaseFirestore.instance.batch();
    for (final d in snap.docs) {
      batch.delete(d.reference);
    }
    await batch.commit();
  }
}

'''
s = between(s, "// --- DIFFICULTY PROGRESS STORAGE ---",
            "// --- ADMIN-CONFIGURABLE DIFFICULTY SETTINGS ---", PROGRESS_SCORES, "Progress/Scores")

# ---------------------------------------------------------------- Settings store
s = once(s, "  static const String _key = 'admin_difficulty_settings';\n",
"""  static const String _key = 'admin_difficulty_settings'; // (legacy, unused)

  static DocumentReference<Map<String, dynamic>> get _docRef =>
      FirebaseFirestore.instance.collection('config').doc('difficulty_settings');

  static Future<String?> _readRaw() async {
    try {
      final snap = await _docRef.get();
      return snap.data()?['json']?.toString();
    } catch (e) {
      debugPrint('DifficultySettingsStore read failed: $e');
      return null;
    }
  }
""", "settings-key")
s = once(s, """    final merged = defaultSettings;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
""", """    final merged = defaultSettings;
    final raw = await _readRaw();
""", "settings-load")
s = once(s, """    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(settings));""",
    """    await _docRef.set({'json': jsonEncode(settings)});""", "settings-save")
s = once(s, """  static Future<void> resetToDefault() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }""", """  static Future<void> resetToDefault() async {
    await _docRef.delete();
  }""", "settings-reset")

# ---------------------------------------------------------------- Seeder
SEED = r'''Future<void> seedDemoDataIfNeeded() async {
  final db = FirebaseFirestore.instance;
  final flagRef = db.collection('meta').doc('demo_data_seeded_v6');

  try {
    // Seeded once, for everyone, ever. A new browser no longer re-seeds.
    if ((await flagRef.get()).exists) return;

    final allDemoAccounts = <String, int>{
      ..._demoScores,
      ..._generateAdditionalDemoAccounts(),
    };

    final dateRand = Random(5678); // fixed seed so dates stay stable
    final createdAtByUser = <String, String>{
      for (final username in allDemoAccounts.keys) username: _randomActivityTimestamp(dateRand),
    };
    await UserStorage.seedAccounts(createdAtByUser);

    // Scale each account's arbitrary base number into every category's
    // REAL maximum (100 / 150 / 300); ENDLESS starts above HARD's target.
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
        final bonus = (rank * 300).round();
        scores['ENDLESS'] = _roundToTens(300 + bonus);
      }
      categorized[entry.key] = scores;
    }

    var batch = db.batch();
    var n = 0;
    for (final entry in categorized.entries) {
      final lower = entry.key.trim().toLowerCase();
      batch.set(
        db.collection('scores').doc(_dbKey(lower)),
        {'username': lower, ...entry.value},
        SetOptions(merge: true),
      );
      n++;
      if (n % 400 == 0) {
        await batch.commit();
        batch = db.batch();
      }
    }
    if (n % 400 != 0) await batch.commit();

    await flagRef.set({'seededAt': DateTime.now().toIso8601String()});
  } catch (e) {
    // Never block app start-up because of a database problem.
    debugPrint('Demo data seeding skipped: $e');
  }
}
'''
s = between(s, "Future<void> seedDemoDataIfNeeded() async {",
            "// --- MULTIPLAYER SERVICE & LOBBY ---", SEED + "\n", "seed")

# ---------------------------------------------------------------- Auth error handling
s = once(s, """      final created = await UserStorage.registerUser(username, password);
      if (!mounted) return;
""", """      bool created;
      try {
        created = await UserStorage.registerUser(username, password);
      } catch (_) {
        if (!mounted) return;
        setState(() {
          messageKey = 'db_error';
          isError = true;
          _isProcessing = false;
        });
        return;
      }
      if (!mounted) return;
""", "auth-register")
s = once(s, """      final loginResult = await UserStorage.validateLogin(username, password);
      if (!mounted) return;
""", """      UserLoginResult loginResult;
      try {
        loginResult = await UserStorage.validateLogin(username, password);
      } catch (_) {
        if (!mounted) return;
        setState(() {
          messageKey = 'db_error';
          isError = true;
          _isProcessing = false;
        });
        return;
      }
      if (!mounted) return;
""", "auth-login")
s = once(s, "      'wrong_password': 'Wrong Password!',\n",
"""      'wrong_password': 'Wrong Password!',
      'db_error': 'Cannot reach the database. Check your internet and try again.',
""", "translation")

# ---------------------------------------------------------------- Leaderboard clear button
s = once(s, "                if (_sortedScores.isNotEmpty) ...[",
            "                if (kAllowPlayersToClearScores && _sortedScores.isNotEmpty) ...[", "leaderboard")

if crlf:
    s = s.replace("\n", "\r\n")
open(PATH, "w", encoding="utf-8", newline="").write(s)
print("Patched lib/main.dart -> Firestore database.")