#!/usr/bin/env python3
"""
apply_realtime_sync.py   (RUN MO MUNA ANG apply_role_selection.py)

Ginagawang REALTIME Tom vs Jerry ang 2-player mode:
  - Tao ang gumagalaw kay Tom (pusa) at kay Jerry (daga), hindi na AI si Tom.
  - Ang galaw ng kalaban ay nasi-sync sa Firestore (~8x/segundo) at
    ini-interpolate para smooth.
  - Ang cheese ay pare-pareho sa dalawang device (galing sa Room Code seed);
    si Jerry ang nagbibilang ng score at nagde-detect ng catch.
  - Panalo ni Jerry: 100 pts na cheese.  Panalo ni Tom: mahuli si Jerry.
  - May REMATCH at LEAVE ROOM sa dulo ng laban.

Gamit (sa root ng project):
    python apply_realtime_sync.py
    python apply_realtime_sync.py path/to/main.dart

Gumagawa ng backup: main.dart.bak2. Kapag may anchor na hindi mahanap,
titigil ito at HINDI babaguhin ang file.
"""
import sys
from pathlib import Path

target = Path(sys.argv[1] if len(sys.argv) > 1 else "lib/main.dart")
if not target.exists():
    sys.exit(f"Hindi mahanap ang {target}. I-run ito sa root ng project.")

raw = target.read_bytes().decode("utf-8")
crlf = "\r\n" in raw
text = raw.replace("\r\n", "\n")

if "String? playerRole;" not in text:
    sys.exit("Kulang pa: i-run muna ang apply_role_selection.py bago ito.")
if "bool get isVersusMode" in text:
    sys.exit("Mukhang na-apply na ito dati (nakita ang 'isVersusMode'). Walang binago.")


def rep(src, old, new, label, count=1):
    n = src.count(old)
    if n != count:
        sys.exit(f"[{label}] Inaasahang {count} match pero {n} ang nakita. Walang binago.")
    return src.replace(old, new)


# =====================================================================
# TomAndJerryGame: fields
# =====================================================================
text = rep(
    text,
    "  String? playerRole; // 'tom' | 'jerry'\n",
    r'''  String? playerRole; // 'tom' | 'jerry'

  // ---- Versus (realtime Tom vs Jerry) settings ----
  static const int versusTargetScore = 100; // Jerry wins at this many points
  static const int versusCheesePoints = 10;
  static const int versusCheeseCount = 16;
  static const double versusTomSpeed = 130.0; // Jerry runs at 140

  bool get isVersusMode => roomId != null && playerRole != null;

  DocumentReference<Map<String, dynamic>>? _roomRef;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _roomSub;
  double _syncTimer = 0;
  Vector2? _lastSent;
  int _matchId = 0;
  bool _versusOver = false;
  bool _rematchSent = false;
  String versusWinner = ''; // 'tom' | 'jerry' | 'left'
  final ValueNotifier<bool> rematchWaitingNotifier = ValueNotifier<bool>(false);
''',
    "game fields",
)

# =====================================================================
# TomAndJerryGame: onLoad auto start
# =====================================================================
text = rep(
    text,
    "      startGame(playerName, 'EASY');\n",
    r'''      if (isVersusMode) {
        isTwoPlayerMode = false; // versus = 1 Tom + 1 Jerry, hindi co-op
        startGame(playerName, 'EASY');
        _startVersusSync();
      } else {
        startGame(playerName, 'EASY');
      }
''',
    "onLoad autostart",
)

# =====================================================================
# TomAndJerryGame: update() -> versus tick, walang AI spawn
# =====================================================================
text = rep(
    text,
    "    _checkPickupProximity();\n\n    _tomSpawnTimer += dt;\n",
    r'''    _checkPickupProximity();

    if (isVersusMode) {
      _versusTick(dt);
      return;
    }

    _tomSpawnTimer += dt;
''',
    "update",
)

# remote Jerry (sa screen ni Tom) ay hindi pwedeng mag-collect ng cheese
text = rep(
    text,
    "      if (jerry1 != null) jerry1!,\n",
    "      if (jerry1 != null && !jerry1!.isRemote) jerry1!,\n",
    "pickup proximity",
)

# walang pause sa versus (hindi nito napo-pause ang kalaban)
text = rep(
    text,
    "  void pauseGame() {\n    pauseEngine();\n",
    "  void pauseGame() {\n    if (isVersusMode) return;\n    pauseEngine();\n",
    "pauseGame",
)

# =====================================================================
# TomAndJerryGame: _buildMaze
# =====================================================================
text = rep(
    text,
    "    _spawnCheeses(12);\n    _spawnPowerUp();\n",
    r'''    if (isVersusMode) {
      _spawnVersusCheeses();
    } else {
      _spawnCheeses(12);
      _spawnPowerUp();
    }
''',
    "buildMaze cheeses",
)

text = rep(
    text,
    '''    jerry1 = JerryPlayer(
      gridPosition: Vector2(1, 1),
      isPlayerTwo: false,
    );
''',
    '''    jerry1 = JerryPlayer(
      gridPosition: Vector2(1, 1),
      isPlayerTwo: false,
      isRemote: isVersusMode && playerRole == 'tom',
    );
''',
    "buildMaze jerry",
)

text = rep(
    text,
    '''    final tomSpeed = _speedForDifficulty(difficulty);
    final firstTom = TomChaser(
      gridPosition: Vector2(13, 13),
      speed: tomSpeed,
      game: this,
    );
''',
    '''    final tomSpeed = isVersusMode ? versusTomSpeed : _speedForDifficulty(difficulty);
    final firstTom = TomChaser(
      gridPosition: Vector2(13, 13),
      speed: tomSpeed,
      game: this,
      isHuman: isVersusMode,
      isRemote: isVersusMode && playerRole == 'jerry',
    );
''',
    "buildMaze tom",
)

# puntos ng cheese sa versus = fixed (para pareho sa dalawang device)
text = rep(
    text,
    "  int get currentCheesePoints =>\n"
    "      _cheesePointsForDifficulty(isEndlessNotifier.value ? 'ENDLESS' : difficulty);\n",
    "  int get currentCheesePoints => isVersusMode\n"
    "      ? versusCheesePoints\n"
    "      : _cheesePointsForDifficulty(isEndlessNotifier.value ? 'ENDLESS' : difficulty);\n",
    "currentCheesePoints",
)

text = rep(
    text,
    "  void _checkLevelComplete() {\n    if (_levelCompleteTriggered) return;\n",
    "  void _checkLevelComplete() {\n"
    "    if (isVersusMode) {\n"
    "      _checkVersusWin();\n"
    "      return;\n"
    "    }\n"
    "    if (_levelCompleteTriggered) return;\n",
    "checkLevelComplete",
)

text = rep(
    text,
    "  void onPlayerCaught(JerryPlayer player) async {\n",
    "  void onPlayerCaught(JerryPlayer player) async {\n"
    "    if (isVersusMode) {\n"
    "      // Si Jerry (local) ang nagde-decide kung nahuli siya.\n"
    "      if (!player.isRemote && !_versusOver) _endVersusAsAuthority('tom');\n"
    "      return;\n"
    "    }\n",
    "onPlayerCaught",
)

# =====================================================================
# TomAndJerryGame: versus methods (bago ang onCaughtByTom)
# =====================================================================
VERSUS_METHODS = r'''  // =====================================================================
  // VERSUS: REALTIME TOM vs JERRY (Firestore sync)
  // =====================================================================

  /// Pare-parehong seed sa dalawang device, galing sa Room Code.
  /// (Sariling PRNG para pareho ang cheese sa web/phone/desktop.)
  int _versusSeed() {
    int seed = 7;
    for (final c in (roomId ?? '').codeUnits) {
      seed = (seed * 31 + c) % 2147483647;
    }
    return seed == 0 ? 1 : seed;
  }

  void _spawnVersusCheeses() {
    final cells = _getEmptyCells();
    int s = _versusSeed();
    for (int i = cells.length - 1; i > 0; i--) {
      s = (s * 48271) % 2147483647;
      final j = s % (i + 1);
      final tmp = cells[i];
      cells[i] = cells[j];
      cells[j] = tmp;
    }
    int count = versusCheeseCount;
    if (count > cells.length) count = cells.length;
    for (final cell in cells.take(count)) {
      world.add(CheeseComponent(gridPosition: cell, game: this));
      _cheeseCount++;
    }
  }

  void _startVersusSync() {
    final id = roomId;
    if (id == null || playerRole == null) return;
    _roomRef = FirebaseFirestore.instance.collection('game_rooms').doc(id);
    _versusOver = false;
    _rematchSent = false;
    _matchId = 0;
    _syncTimer = 0;
    _lastSent = null;
    _roomSub?.cancel();
    _roomSub = _roomRef!.snapshots().listen(_onRoomSnapshot, onError: (_) {});
  }

  void stopVersusSync() {
    _roomSub?.cancel();
    _roomSub = null;
  }

  /// Tinatawag every frame habang tumatakbo ang laban.
  /// Nagpapadala ng sariling posisyon ~8x/segundo, pero kapag gumalaw lang.
  void _versusTick(double dt) {
    if (_versusOver) return;
    _syncTimer += dt;
    if (_syncTimer < 0.12) return;
    _syncTimer = 0;

    final role = playerRole;
    if (role == null) return;
    Vector2? mine;
    if (role == 'tom') {
      if (toms.isNotEmpty) mine = toms.first.position;
    } else {
      mine = jerry1?.position;
    }
    if (mine == null) return;
    final last = _lastSent;
    if (last != null && (mine - last).length2 < 0.25) return;
    _lastSent = mine.clone();

    _roomRef?.update({
      role: {'x': mine.x, 'y': mine.y, 'live': true},
    }).catchError((_) {});
  }

  void _onRoomSnapshot(DocumentSnapshot<Map<String, dynamic>> snap) {
    final data = snap.data();
    final me = playerRole;
    if (data == null || me == null) return;
    final other = me == 'tom' ? 'jerry' : 'tom';

    // Rematch: bagong matchId -> i-restart ang laban sa dalawang device.
    final matchId = (data['matchId'] as num?)?.toInt() ?? 0;
    if (matchId > _matchId) {
      _matchId = matchId;
      _restartVersusMatch();
      return;
    }

    // Posisyon ng kalaban
    final op = data[other];
    if (op is Map && op['live'] == true) {
      final x = (op['x'] as num?)?.toDouble();
      final y = (op['y'] as num?)?.toDouble();
      if (x != null && y != null) {
        final target = Vector2(x, y);
        if (other == 'jerry') {
          jerry1?.remoteTarget = target;
        } else if (toms.isNotEmpty) {
          toms.first.remoteTarget = target;
        }
      }
    }

    // Sa screen ni Tom: sundan ang score at cheese ni Jerry.
    if (me == 'tom') {
      final score = (data['score'] as num?)?.toInt();
      if (score != null && score != p1ScoreNotifier.value) {
        p1ScoreNotifier.value = score;
      }
      final collected = data['collected'];
      if (collected is List && collected.isNotEmpty) {
        _applyCollected(collected.map((e) => e.toString()).toSet());
      }
    }

    // Tapos na ang laban / umalis ang kalaban
    if (!_versusOver) {
      final left = data['left'];
      if (left is String && left.isNotEmpty && left != me) {
        _showVersusResult('left');
      } else if (data['status'] == 'over') {
        _showVersusResult((data['winner'] as String?) ?? '');
      }
    }

    // Si Jerry ang nag-a-approve ng rematch kapag pareho nang pumindot.
    if (_versusOver && me == 'jerry' && !_rematchSent) {
      final rem = data['rematch'];
      if (rem is Map && rem['tom'] == true && rem['jerry'] == true) {
        _resetRoomForRematch();
      }
    }
  }

  void _applyCollected(Set<String> keys) {
    for (final cheese in world.children.query<CheeseComponent>().toList()) {
      final key = '${cheese.gridPosition.x.toInt()},${cheese.gridPosition.y.toInt()}';
      if (keys.contains(key)) {
        world.add(SparkleBurstComponent(
          position: cheese.position + cheese.size / 2,
          color: const Color(0xFFFFC107),
        ));
        _playSfx('cheese.wav');
        cheese.removeFromParent();
      }
    }
  }

  /// Tinatawag ng CheeseComponent (sa screen ni Jerry lang, dahil hindi
  /// nakaka-collect ang remote Jerry) para ipaalam kay Tom.
  void onVersusCheeseCollected(Vector2 grid) {
    if (!isVersusMode) return;
    final key = '${grid.x.toInt()},${grid.y.toInt()}';
    _roomRef?.update({
      'collected': FieldValue.arrayUnion([key]),
      'score': p1ScoreNotifier.value,
    }).catchError((_) {});
  }

  void _checkVersusWin() {
    if (_versusOver || playerRole != 'jerry') return;
    if (p1ScoreNotifier.value >= versusTargetScore) {
      _endVersusAsAuthority('jerry');
    }
  }

  void _endVersusAsAuthority(String winner) {
    if (_versusOver) return;
    _showVersusResult(winner);
    _roomRef?.update({
      'status': 'over',
      'winner': winner,
      'score': p1ScoreNotifier.value,
    }).catchError((_) {});
  }

  void _showVersusResult(String winner) {
    if (_versusOver) return;
    _versusOver = true;
    versusWinner = winner;
    rematchWaitingNotifier.value = false;
    p1TouchDirection.value = Vector2.zero();
    _playSfx(winner == playerRole ? 'powerup.wav' : 'caught.wav');
    FlameAudio.bgm.stop();
    pauseEngine();
    overlays.remove('HUD');
    overlays.remove('TouchControls');
    overlays.add('VersusResult');
  }

  void requestRematch() {
    final role = playerRole;
    if (role == null || _rematchSent || versusWinner == 'left') return;
    rematchWaitingNotifier.value = true;
    _roomRef?.update({'rematch.$role': true}).catchError((_) {});
  }

  void _resetRoomForRematch() {
    _rematchSent = true;
    _roomRef?.update({
      'status': 'playing',
      'winner': '',
      'left': '',
      'score': 0,
      'collected': <String>[],
      'matchId': _matchId + 1,
      'rematch': {'tom': false, 'jerry': false},
      'tom': {'live': false},
      'jerry': {'live': false},
    }).catchError((_) {});
  }

  void _restartVersusMatch() {
    _versusOver = false;
    _rematchSent = false;
    versusWinner = '';
    rematchWaitingNotifier.value = false;
    _lastSent = null;
    _syncTimer = 0;
    overlays.remove('VersusResult');
    overlays.add('HUD');
    overlays.add('TouchControls');
    p1ScoreNotifier.value = 0;
    p2ScoreNotifier.value = 0;
    _buildMaze();
    resumeEngine();
    if (!isMutedNotifier.value) {
      FlameAudio.bgm.play('bg_music.mp3', volume: 0.4);
    }
  }

  void leaveVersus() {
    final role = playerRole;
    if (role != null) {
      _roomRef?.update({'left': role}).catchError((_) {});
    }
    stopVersusSync();
    FlameAudio.bgm.stop();
  }

'''
text = rep(
    text,
    "  void onCaughtByTom() async {\n",
    VERSUS_METHODS + "  void onCaughtByTom() async {\n",
    "versus methods",
)

# =====================================================================
# GameApp: overlay map + dispose
# =====================================================================
text = rep(
    text,
    "      'LevelComplete': (context, game) => LevelCompleteOverlay(game: game),\n",
    "      'LevelComplete': (context, game) => LevelCompleteOverlay(game: game),\n"
    "      'VersusResult': (context, game) => VersusResultOverlay(game: game),\n",
    "overlay map",
)

text = rep(
    text,
    "    _gameFocusNode.dispose();\n",
    "    game.stopVersusSync();\n    _gameFocusNode.dispose();\n",
    "GameApp dispose",
)

# =====================================================================
# Cheese / Power-up: remote Jerry ay hindi nagko-collect
# =====================================================================
text = rep(
    text,
    "    if (other is JerryPlayer) collectBy(other);\n",
    "    if (other is JerryPlayer && !other.isRemote) collectBy(other);\n",
    "pickup collisions",
    count=2,
)

text = rep(
    text,
    "    game.collectCheese(other.isPlayerTwo);\n",
    "    game.collectCheese(other.isPlayerTwo);\n    game.onVersusCheeseCollected(gridPosition);\n",
    "cheese collectBy",
)

# =====================================================================
# JerryPlayer
# =====================================================================
text = rep(
    text,
    '''  JerryPlayer({
    required this.gridPosition,
    required this.isPlayerTwo,
  }) : super(
''',
    '''  // Versus mode: kapag true, ang posisyon ay galing sa network (hindi sa keyboard).
  final bool isRemote;
  Vector2? remoteTarget;

  JerryPlayer({
    required this.gridPosition,
    required this.isPlayerTwo,
    this.isRemote = false,
  }) : super(
''',
    "JerryPlayer ctor",
)

text = rep(
    text,
    "    _idleTime += dt;\n\n    _velocity.setZero();\n",
    "    _idleTime += dt;\n\n"
    "    if (isRemote) {\n"
    "      _updateRemote(dt);\n"
    "      return;\n"
    "    }\n\n"
    "    _velocity.setZero();\n",
    "JerryPlayer update",
)

text = rep(
    text,
    "      _velocity.add(game.p1TouchDirection.value);\n",
    "      if (game.isVersusMode) {\n"
    "        // Sa versus, arrows O WASD ang pwede.\n"
    "        if (keys.isLogicalKeyPressed(LogicalKeyboardKey.keyW)) _velocity.y -= 1;\n"
    "        if (keys.isLogicalKeyPressed(LogicalKeyboardKey.keyS)) _velocity.y += 1;\n"
    "        if (keys.isLogicalKeyPressed(LogicalKeyboardKey.keyA)) _velocity.x -= 1;\n"
    "        if (keys.isLogicalKeyPressed(LogicalKeyboardKey.keyD)) _velocity.x += 1;\n"
    "      }\n"
    "      _velocity.add(game.p1TouchDirection.value);\n",
    "JerryPlayer keys",
)

JERRY_REMOTE = r'''  /// Versus mode: sinusundan ng remote Jerry ang posisyong galing sa network
  /// (smooth interpolation sa pagitan ng ~8 updates/segundo).
  void _updateRemote(double dt) {
    _facingLerp += (_facing - _facingLerp) * min(1.0, dt * 12);
    final target = remoteTarget;
    if (target == null) {
      _isMoving = false;
      return;
    }
    final diff = target - position;
    final dist = diff.length;
    if (dist < 0.6 || dist > cellSize * 4) {
      position.setFrom(target);
      _isMoving = false;
      return;
    }
    position.add(diff * min(1.0, dt * 14));
    _isMoving = true;
    _animTime += dt;
    _velocity.setFrom(diff);
    _velocity.normalize();
    if (diff.x.abs() > 0.5) {
      _facing = diff.x > 0 ? 1 : -1;
    }
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

'''
text = rep(
    text,
    "  // FIX: fraction of Jerry's width/height trimmed off each side when\n",
    JERRY_REMOTE + "  // FIX: fraction of Jerry's width/height trimmed off each side when\n",
    "JerryPlayer remote method",
)

text = rep(
    text,
    "text: isPlayerTwo ? 'P2' : 'P1',",
    "text: game.isVersusMode ? 'JERRY' : (isPlayerTwo ? 'P2' : 'P1'),",
    "Jerry label",
)

# =====================================================================
# TomChaser (AI o tao)
# =====================================================================
text = rep(
    text,
    "  TomChaser({required this.gridPosition, required this.speed, required this.game})\n",
    '''  // Versus mode: isHuman = tao ang kumokontrol kay Tom (hindi AI).
  // isRemote = ang tao ay nasa kabilang device; galing sa network ang posisyon.
  final bool isHuman;
  final bool isRemote;
  Vector2? remoteTarget;

  TomChaser({
    required this.gridPosition,
    required this.speed,
    required this.game,
    this.isHuman = false,
    this.isRemote = false,
  })
''',
    "TomChaser ctor",
)

text = rep(
    text,
    "    _facingLerp += (_facing - _facingLerp) * min(1.0, dt * 10);\n",
    "    _facingLerp += (_facing - _facingLerp) * min(1.0, dt * 10);\n\n"
    "    if (isHuman) {\n"
    "      _updateHuman(dt);\n"
    "      return;\n"
    "    }\n",
    "TomChaser update",
)

TOM_HUMAN = r'''  // ---- Versus mode: Tom na kinokontrol ng tao ----
  static const double _humanWallMargin = 0.22;

  Rect _humanWallRect(double px, double py) {
    final mx = size.x * _humanWallMargin;
    final my = size.y * _humanWallMargin;
    return Rect.fromLTWH(px + mx, py + my, size.x - mx * 2, size.y - my * 2);
  }

  void _updateHuman(double dt) {
    if (isRemote) {
      _updateRemoteHuman(dt);
      return;
    }

    final v = Vector2.zero();
    final keys = HardwareKeyboard.instance;
    if (keys.isLogicalKeyPressed(LogicalKeyboardKey.arrowUp) ||
        keys.isLogicalKeyPressed(LogicalKeyboardKey.keyW)) v.y -= 1;
    if (keys.isLogicalKeyPressed(LogicalKeyboardKey.arrowDown) ||
        keys.isLogicalKeyPressed(LogicalKeyboardKey.keyS)) v.y += 1;
    if (keys.isLogicalKeyPressed(LogicalKeyboardKey.arrowLeft) ||
        keys.isLogicalKeyPressed(LogicalKeyboardKey.keyA)) v.x -= 1;
    if (keys.isLogicalKeyPressed(LogicalKeyboardKey.arrowRight) ||
        keys.isLogicalKeyPressed(LogicalKeyboardKey.keyD)) v.x += 1;
    v.add(game.p1TouchDirection.value);

    _isMoving = v.length2 > 0;
    if (!_isMoving) return;

    _animTime += dt;
    if (v.x.abs() > 0.01) {
      _facing = v.x > 0 ? 1 : -1;
    }
    v.normalize();
    _lastDir = v.clone();

    final delta = v * speed * dt;
    final tryX = _humanWallRect(position.x + delta.x, position.y);
    if (!rectHitsWall(tryX)) position.x += delta.x;
    final tryY = _humanWallRect(position.x, position.y + delta.y);
    if (!rectHitsWall(tryY)) position.y += delta.y;

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

  void _updateRemoteHuman(double dt) {
    final target = remoteTarget;
    if (target == null) {
      _isMoving = false;
      return;
    }
    final diff = target - position;
    final dist = diff.length;
    if (dist < 0.6 || dist > cellSize * 4) {
      position.setFrom(target);
      _isMoving = false;
      return;
    }
    position.add(diff * min(1.0, dt * 14));
    _isMoving = true;
    _animTime += dt;
    _lastDir = diff.normalized();
    if (diff.x.abs() > 0.5) {
      _facing = diff.x > 0 ? 1 : -1;
    }
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

'''
text = rep(
    text,
    "  Point<int> _cellOfCenter(Vector2 center) {\n",
    TOM_HUMAN + "  Point<int> _cellOfCenter(Vector2 center) {\n",
    "TomChaser human methods",
)

text = rep(
    text,
    "    canvas.restore(); // flip\n    canvas.restore(); // hop/squash\n  }\n",
    r'''    canvas.restore(); // flip
    canvas.restore(); // hop/squash

    // "TOM" label para sa Tom na kinokontrol ng tao (versus mode).
    if (isHuman) {
      final labelPainter = TextPainter(
        text: TextSpan(
          text: 'TOM',
          style: TextStyle(
            fontSize: h * 0.22,
            fontWeight: FontWeight.w900,
            color: Colors.redAccent,
            shadows: const [Shadow(color: Colors.black, blurRadius: 3, offset: Offset(0.5, 0.5))],
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      labelPainter.layout();
      labelPainter.paint(canvas, Offset(w / 2 - labelPainter.width / 2, -h * 0.34));
    }
  }
''',
    "Tom label",
)

# =====================================================================
# UI: ModeSelect (huwag tanggalin ang overlay para may babalikan), HUD
# =====================================================================
text = rep(
    text,
    "                    game.isTwoPlayerMode = true;\n"
    "                    game.overlays.remove('ModeSelect');\n"
    "                    Navigator.push(\n",
    "                    game.isTwoPlayerMode = true;\n"
    "                    Navigator.push(\n",
    "ModeSelect keep overlay",
)

text = rep(
    text,
    "Text('P1 (${game.playerName}): ', style: p1Style),",
    "Text(\n"
    "                  game.isVersusMode\n"
    "                      ? (game.playerRole == 'tom' ? 'YOU: TOM  |  CHEESE: ' : 'YOU: JERRY  |  CHEESE: ')\n"
    "                      : 'P1 (${game.playerName}): ',\n"
    "                  style: p1Style,\n"
    "                ),",
    "HUD label",
)

text = rep(
    text,
    "onPressed: () => game.pauseGame(),",
    "onPressed: game.isVersusMode ? null : () => game.pauseGame(),",
    "HUD pause button",
)

# =====================================================================
# Bagong overlay: VersusResultOverlay (idagdag sa dulo ng file)
# =====================================================================
RESULT_OVERLAY = r'''

/// Resulta ng Tom vs Jerry na laban: panalo/talo, REMATCH at LEAVE ROOM.
class VersusResultOverlay extends StatelessWidget {
  final TomAndJerryGame game;
  const VersusResultOverlay({super.key, required this.game});

  @override
  Widget build(BuildContext context) {
    final isDark = game.isDarkModeNotifier.value;
    final textColor = isDark ? AppColors.softWhite : AppColors.lightText;
    final winner = game.versusWinner;
    final left = winner == 'left';
    final iWon = winner == game.playerRole;

    String title;
    String subtitle;
    Color titleColor;
    if (left) {
      title = 'OPPONENT LEFT';
      subtitle = 'Umalis ang kalaban sa room.';
      titleColor = AppColors.cheeseYellow;
    } else if (iWon) {
      title = 'YOU WIN!';
      subtitle = winner == 'tom' ? 'Nahuli mo si Jerry!' : 'Nakakuha ka ng sapat na cheese!';
      titleColor = AppColors.cheeseYellow;
    } else {
      title = 'YOU LOSE';
      subtitle = winner == 'tom' ? 'Nahuli ka ni Tom!' : 'Naunahan ka ni Jerry sa cheese!';
      titleColor = Colors.redAccent;
    }

    return Container(
      color: Colors.black.withValues(alpha: 0.5),
      child: Center(
        child: PopIn(
          child: GlassPanel(
            isDarkMode: isDark,
            borderColor: titleColor,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LoopingPulse(
                  minScale: 0.97,
                  maxScale: 1.06,
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: titleColor, fontSize: 32, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 10),
                Text(subtitle, textAlign: TextAlign.center, style: TextStyle(color: textColor, fontSize: 16)),
                const SizedBox(height: 6),
                Text(
                  'Cheese score: ${game.p1ScoreNotifier.value}',
                  style: TextStyle(color: textColor.withValues(alpha: 0.8), fontSize: 14),
                ),
                const SizedBox(height: 22),
                if (!left)
                  ValueListenableBuilder<bool>(
                    valueListenable: game.rematchWaitingNotifier,
                    builder: (context, waiting, _) => waiting
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            child: Text(
                              'Waiting for opponent...',
                              style: TextStyle(color: textColor, fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          )
                        : ArcadeButton(
                            label: 'REMATCH',
                            color: isDark ? AppColors.brightCyan : AppColors.lightPrimary,
                            textColor: isDark ? AppColors.darkNavy : Colors.white,
                            onTap: () => game.requestRematch(),
                          ),
                  ),
                const SizedBox(height: 8),
                ArcadeButton(
                  label: 'LEAVE ROOM',
                  color: AppColors.deepBlue,
                  textColor: Colors.white,
                  onTap: () {
                    game.leaveVersus();
                    Navigator.of(context).popUntil((route) => route.isFirst);
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
'''
text = text.rstrip("\n") + "\n" + RESULT_OVERLAY

# ---------------------------------------------------------------------
backup = target.with_suffix(target.suffix + ".bak2")
backup.write_bytes(raw.encode("utf-8"))
out = text.replace("\n", "\r\n") if crlf else text
target.write_bytes(out.encode("utf-8"))
print(f"OK! Na-update ang {target}  (backup: {backup})")
print("Susunod: flutter analyze -> subukan sa 2 device -> git add / commit / push")