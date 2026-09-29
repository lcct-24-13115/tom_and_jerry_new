#!/usr/bin/env python3
"""
apply_role_selection.py

Ina-apply ang Tom/Jerry Role Selection sa lib/main.dart.

Gamit (sa root ng Flutter project, kung nasaan ang lib/ folder):
    python apply_role_selection.py
    python apply_role_selection.py path/to/main.dart

- Gumagawa muna ng backup: lib/main.dart.bak
- Kung may anchor na hindi mahanap (ibig sabihin iba na ang file), titigil
  ito at HINDI babaguhin ang file.
"""
import sys
from pathlib import Path

target = Path(sys.argv[1] if len(sys.argv) > 1 else "lib/main.dart")
if not target.exists():
    sys.exit(f"Hindi mahanap ang {target}. I-run ito sa root ng project.")

raw = target.read_bytes().decode("utf-8")
crlf = "\r\n" in raw
text = raw.replace("\r\n", "\n")

if "String? playerRole;" in text:
    sys.exit("Mukhang na-apply na ito dati (nakita ang 'playerRole'). Walang binago.")


def replace_once(src, old, new, label):
    n = src.count(old)
    if n != 1:
        sys.exit(f"[{label}] Inaasahang 1 match pero {n} ang nakita. Walang binago.")
    return src.replace(old, new)


# ---------------------------------------------------------------------
# 1. MultiplayerService + LobbyScreen (buong seksyon)
# ---------------------------------------------------------------------
LOBBY_BLOCK = r'''// --- MULTIPLAYER SERVICE & LOBBY ---
class MultiplayerService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<void> createRoom(String roomId, String hostRole) async {
    await _firestore.collection('game_rooms').doc(roomId).set({
      'status': 'waiting',
      'createdHost': hostRole,
      hostRole: {'x': 100.0, 'y': 100.0},
    });
  }

  /// Returns the room's data, or null if the room doesn't exist yet.
  Future<Map<String, dynamic>?> getRoom(String roomId) async {
    final doc = await _firestore.collection('game_rooms').doc(roomId).get();
    return doc.exists ? doc.data() : null;
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

  String? _selectedRole; // 'tom' | 'jerry'
  bool _isBusy = false;

  @override
  void dispose() {
    _roomController.dispose();
    super.dispose();
  }

  String _nameForRole(String role) => role == 'tom' ? 'Tom' : 'Jerry';

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Entry point ng dalawang Character buttons.
  /// - Walang existing room -> gagawa ng bago (Create) gamit ang napiling role.
  /// - May existing room -> sasali (Join) gamit ang napiling role.
  Future<void> _handleRoleSelected(String role) async {
    if (_isBusy) return;

    final roomId = _roomController.text.trim();
    if (roomId.isEmpty) {
      _showMessage('I-type muna ang Room Code!');
      return;
    }

    setState(() {
      _selectedRole = role;
      _isBusy = true;
    });

    try {
      final room = await _service.getRoom(roomId);
      if (!mounted) return;

      if (room == null) {
        await _handleCreateRoom(roomId, role);
      } else {
        await _handleJoinRoom(roomId, role, room);
      }
    } catch (e) {
      if (mounted) _showMessage('May error: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _handleCreateRoom(String roomId, String role) async {
    await _service.createRoom(roomId, role);
    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => WaitingScreen(roomId: roomId, role: role),
      ),
    );
  }

  Future<void> _handleJoinRoom(
    String roomId,
    String role,
    Map<String, dynamic> room,
  ) async {
    if (room['status'] != 'waiting') {
      _showMessage('Nagsimula na ang laro sa room na ito. Gumamit ng ibang Room Code.');
      return;
    }

    final hostRole = (room['createdHost'] as String?) ?? 'tom';
    if (hostRole == role) {
      _showMessage(
        'Kinuha na ni ${_nameForRole(hostRole)} ang role na iyan. '
        'Piliin ang ${_nameForRole(hostRole == 'tom' ? 'jerry' : 'tom')}.',
      );
      return;
    }

    final joined = await _service.joinRoom(roomId, role);
    if (!mounted) return;

    if (joined) {
      _navigateToGame(roomId, role);
    } else {
      _showMessage('Hindi nahanap ang Room Code!');
    }
  }

  void _navigateToGame(String roomId, String role) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GameApp(
          startInGame: true,
          startTwoPlayer: true,
          playerName: _nameForRole(role),
          roomId: roomId,
          role: role,
        ),
      ),
    );
  }

  Widget _roleButton({
    required String role,
    required String emoji,
    required String label,
    required String sublabel,
    required Color color,
  }) {
    final selected = _selectedRole == role;
    return Expanded(
      child: ElevatedButton(
        onPressed: _isBusy ? null : () => _handleRoleSelected(role),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          disabledBackgroundColor: color.withValues(alpha: 0.5),
          disabledForegroundColor: Colors.white70,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: selected ? AppColors.cheeseYellow : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 34)),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            Text(sublabel, style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
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
                enabled: !_isBusy,
                decoration: const InputDecoration(
                  labelText: 'I-type ang Room Code (e.g. 1234)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Bagong code = gagawa ng room. Existing code = sasali sa room.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 20),
              const Text(
                'Pumili ng karakter',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _roleButton(
                    role: 'tom',
                    emoji: '🐱',
                    label: 'Play as Tom',
                    sublabel: 'Player 1',
                    color: Colors.blueGrey.shade600,
                  ),
                  const SizedBox(width: 10),
                  _roleButton(
                    role: 'jerry',
                    emoji: '🐭',
                    label: 'Play as Jerry',
                    sublabel: 'Player 2',
                    color: Colors.brown.shade400,
                  ),
                ],
              ),
              if (_isBusy) ...[
                const SizedBox(height: 16),
                const CircularProgressIndicator(),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

'''

start_marker = "// --- MULTIPLAYER SERVICE & LOBBY ---\n"
end_marker = "void main() async {"
s = text.find(start_marker)
e = text.find(end_marker)
if s == -1 or e == -1 or e < s or text.count(start_marker) != 1 or text.count(end_marker) != 1:
    sys.exit("[lobby] Hindi mahanap ang start/end marker ng Lobby section. Walang binago.")
text = text[:s] + LOBBY_BLOCK + text[e:]

# ---------------------------------------------------------------------
# 2. GameApp: dagdag na roomId + role
# ---------------------------------------------------------------------
text = replace_once(
    text,
    '''class GameApp extends StatefulWidget {
  final bool startInGame;
  final bool startTwoPlayer;
  final String? playerName;

  const GameApp({
    super.key,
    this.startInGame = false,
    this.startTwoPlayer = false,
    this.playerName,
  });
''',
    '''class GameApp extends StatefulWidget {
  final bool startInGame;
  final bool startTwoPlayer;
  final String? playerName;
  final String? roomId;
  final String? role; // 'tom' | 'jerry'

  const GameApp({
    super.key,
    this.startInGame = false,
    this.startTwoPlayer = false,
    this.playerName,
    this.roomId,
    this.role,
  });
''',
    "GameApp",
)

text = replace_once(
    text,
    "    game.focusNode = _gameFocusNode;\n",
    "    game.focusNode = _gameFocusNode;\n"
    "    game.roomId = widget.roomId;\n"
    "    game.playerRole = widget.role;\n",
    "GameApp.initState",
)

# ---------------------------------------------------------------------
# 3. TomAndJerryGame: fields para sa roomId + role
# ---------------------------------------------------------------------
text = replace_once(
    text,
    "  bool pendingAutoStart = false;\n",
    "  bool pendingAutoStart = false;\n"
    "\n"
    "  // Galing sa Lobby/Waiting flow. Null kapag 1-player o hindi galing sa multiplayer.\n"
    "  String? roomId;\n"
    "  String? playerRole; // 'tom' | 'jerry'\n",
    "TomAndJerryGame fields",
)

# ---------------------------------------------------------------------
# 4. WaitingScreen (buong class hanggang dulo ng file)
# ---------------------------------------------------------------------
WAITING_BLOCK = r'''class WaitingScreen extends StatefulWidget {
  final String roomId;
  final String role; // 'tom' | 'jerry' (role ng host)
  const WaitingScreen({super.key, required this.roomId, this.role = 'tom'});

  @override
  State<WaitingScreen> createState() => _WaitingScreenState();
}

class _WaitingScreenState extends State<WaitingScreen> {
  bool _navigated = false;

  String get _myName => widget.role == 'tom' ? 'Tom' : 'Jerry';
  String get _opponentName => widget.role == 'tom' ? 'Jerry' : 'Tom';

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

            // Kapag naging 'playing' na ang status, lilipat sa laro.
            // Guarded ng _navigated para hindi paulit-ulit ang push.
            if (data['status'] == 'playing' && !_navigated) {
              _navigated = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (context) => GameApp(
                      startInGame: true,
                      startTwoPlayer: true,
                      playerName: _myName,
                      roomId: widget.roomId,
                      role: widget.role,
                    ),
                  ),
                );
              });
            }
          }

          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 20),
                Text(
                  'Room ${widget.roomId} \u2022 Ikaw si $_myName',
                  style: const TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 8),
                Text(
                  'Waiting for $_opponentName to join...',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
'''

w_marker = "class WaitingScreen extends StatefulWidget {"
if text.count(w_marker) != 1:
    sys.exit("[waiting] Hindi mahanap ang WaitingScreen class. Walang binago.")
text = text[: text.find(w_marker)] + WAITING_BLOCK

# ---------------------------------------------------------------------
# Isulat ang resulta (backup muna)
# ---------------------------------------------------------------------
backup = target.with_suffix(target.suffix + ".bak")
backup.write_bytes(raw.encode("utf-8"))
out = text.replace("\n", "\r\n") if crlf else text
target.write_bytes(out.encode("utf-8"))
print(f"OK! Na-update ang {target}  (backup: {backup})")
print("Susunod: flutter analyze  ->  git add / commit / push")