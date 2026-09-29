"""
Adds to the LOGIN page:
  1) a collapsible "How to get started" instructions panel (changes between
     Login and Register mode, translated into all 5 languages), and
  2) a confetti celebration right after a successful registration.

Only AuthOverlay + the translation table are touched. No new packages.
Run from the project root:   python apply_login_instructions_confetti.py
"""
import sys

PATH = "lib/main.dart"
s = open(PATH, encoding="utf-8", newline="").read()
crlf = "\r\n" in s
s = s.replace("\r\n", "\n")

if "class ConfettiBurst" in s:
    print("Already patched. Nothing to do.")
    sys.exit(0)

def once(text, old, new, label):
    if text.count(old) != 1:
        sys.exit("ABORT (%s): expected 1 match, found %d.\n%s" % (label, text.count(old), old[:100]))
    return text.replace(old, new)

# ------------------------------------------------------------ translations
TR = {
 0: """      'instructions_title': 'HOW TO GET STARTED',
      'instr_login_1': 'Type your username and password, then press LOGIN.',
      'instr_login_2': 'New here? Tap "Click to Register" to create an account first.',
      'instr_login_3': 'After logging in, press PLAY GAME and choose 1 or 2 players.',
      'instr_login_4': 'Move with the Arrow Keys (Player 2: WASD). Collect cheese and avoid Tom!',
      'instr_register_1': 'Choose a unique username (nobody else can use it).',
      'instr_register_2': 'Type a password, then type it again to confirm.',
      'instr_register_3': 'Press CREATE ACCOUNT. You will come back here to log in.',
      'instr_register_4': 'Tip: remember your password - you need it every time you log in.',
""",
 1: """      'instructions_title': 'PAANO MAGSIMULA',
      'instr_login_1': 'I-type ang username at password, tapos pindutin ang LOG IN.',
      'instr_login_2': 'Bago ka pa lang? Mag-register muna para makagawa ng account.',
      'instr_login_3': 'Pagka-login, pindutin ang MAGLARO at pumili ng 1 o 2 players.',
      'instr_login_4': 'Gamitin ang Arrow Keys para gumalaw (Player 2: WASD). Kolektahin ang cheese at iwasan si Tom!',
      'instr_register_1': 'Pumili ng natatanging username (walang ibang makakagamit nito).',
      'instr_register_2': 'I-type ang password, tapos i-type ulit para makumpirma.',
      'instr_register_3': 'Pindutin ang GUMAWA NG ACCOUNT. Babalik ka rito para mag-login.',
      'instr_register_4': 'Tip: tandaan ang password mo, kailangan ito sa bawat login.',
""",
 2: """      'instructions_title': '快速上手',
      'instr_login_1': '输入用户名和密码,然后点击“登录”。',
      'instr_login_2': '新用户?请先注册一个账户。',
      'instr_login_3': '登录后点击“开始游戏”,选择单人或双人模式。',
      'instr_login_4': '用方向键移动(玩家2:WASD)。收集奶酪,躲避汤姆!',
      'instr_register_1': '选择一个唯一的用户名(其他人无法使用)。',
      'instr_register_2': '输入密码,再输入一次进行确认。',
      'instr_register_3': '点击“创建账户”,然后返回此处登录。',
      'instr_register_4': '提示:请记住你的密码,每次登录都需要。',
""",
 3: """      'instructions_title': 'CÓMO EMPEZAR',
      'instr_login_1': 'Escribe tu usuario y contraseña, y pulsa ENTRAR.',
      'instr_login_2': '¿Eres nuevo? Regístrate primero para crear una cuenta.',
      'instr_login_3': 'Al entrar, pulsa JUGAR y elige 1 o 2 jugadores.',
      'instr_login_4': 'Muévete con las flechas (Jugador 2: WASD). ¡Recoge queso y evita a Tom!',
      'instr_register_1': 'Elige un nombre de usuario único (nadie más podrá usarlo).',
      'instr_register_2': 'Escribe una contraseña y vuelve a escribirla para confirmar.',
      'instr_register_3': 'Pulsa CREAR CUENTA. Volverás aquí para iniciar sesión.',
      'instr_register_4': 'Consejo: recuerda tu contraseña, la necesitarás cada vez.',
""",
 4: """      'instructions_title': 'はじめ方',
      'instr_login_1': 'ユーザー名とパスワードを入力して「ログイン」を押します。',
      'instr_login_2': '初めての方は、先にアカウントを登録してください。',
      'instr_login_3': 'ログイン後、「プレイする」を押して1人または2人プレイを選びます。',
      'instr_login_4': '矢印キーで移動(プレイヤー2はWASD)。チーズを集めてトムを避けよう!',
      'instr_register_1': '他の人と重複しないユーザー名を決めます。',
      'instr_register_2': 'パスワードを入力し、確認のためもう一度入力します。',
      'instr_register_3': '「登録する」を押すとログイン画面に戻ります。',
      'instr_register_4': 'ヒント:パスワードは毎回必要なので忘れないでください。',
""",
}
lines = s.split("\n")
idx = [i for i, l in enumerate(lines) if l.startswith("      'account_created':")]
if len(idx) != 5:
    sys.exit("ABORT (translations): expected 5 'account_created' lines, found %d." % len(idx))
for order, i in reversed(list(enumerate(idx))):      # insert bottom-up so indexes stay valid
    lines[i + 1:i + 1] = TR[order].rstrip("\n").split("\n")
s = "\n".join(lines)

# ------------------------------------------------------------ confetti widget
CONFETTI = r'''// =====================================================================
// CONFETTI (used on the login page after a successful registration)
// =====================================================================
class _ConfettiPiece {
  final double ox, oy; // launch point as a fraction of the screen
  final double vx, vy; // launch velocity (px / second)
  final double fall; // terminal falling speed (px / second)
  final double delay, size, angle, spin, flip, sway, swayFreq, phase;
  final bool round;
  final Color color;

  const _ConfettiPiece({
    required this.ox,
    required this.oy,
    required this.vx,
    required this.vy,
    required this.fall,
    required this.delay,
    required this.size,
    required this.angle,
    required this.spin,
    required this.flip,
    required this.sway,
    required this.swayFreq,
    required this.phase,
    required this.round,
    required this.color,
  });
}

class ConfettiBurst extends StatefulWidget {
  final VoidCallback? onDone;
  final int count;
  const ConfettiBurst({super.key, this.onDone, this.count = 170});

  @override
  State<ConfettiBurst> createState() => _ConfettiBurstState();
}

class _ConfettiBurstState extends State<ConfettiBurst> with SingleTickerProviderStateMixin {
  static const double _totalSeconds = 4.6;
  late final AnimationController _controller;
  late final List<_ConfettiPiece> _pieces;

  @override
  void initState() {
    super.initState();
    _pieces = _generate(widget.count);
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (_totalSeconds * 1000).round()),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) widget.onDone?.call();
      });
    _controller.forward();
  }

  static List<_ConfettiPiece> _generate(int count) {
    final rand = Random();
    double r(double a, double b) => a + rand.nextDouble() * (b - a);
    const colors = <Color>[
      AppColors.cheeseYellow,
      AppColors.brightCyan,
      Colors.pinkAccent,
      Colors.lightGreenAccent,
      Colors.orangeAccent,
      Colors.purpleAccent,
      Colors.white,
    ];

    final pieces = <_ConfettiPiece>[];
    for (int i = 0; i < count; i++) {
      final group = i % 10; // 3 = left cannon, 3 = right cannon, 4 = falling rain
      double ox, oy, vx, vy, delay;

      if (group < 3) {
        // Left-bottom cannon, aimed up and to the right.
        final a = -r(35, 80) * pi / 180;
        final speed = r(700, 1500);
        ox = r(0.0, 0.1);
        oy = 1.02;
        vx = cos(a) * speed;
        vy = sin(a) * speed;
        delay = r(0, 0.25);
      } else if (group < 6) {
        // Right-bottom cannon, aimed up and to the left.
        final a = -(pi - r(35, 80) * pi / 180);
        final speed = r(700, 1500);
        ox = r(0.9, 1.0);
        oy = 1.02;
        vx = cos(a) * speed;
        vy = sin(a) * speed;
        delay = r(0, 0.25);
      } else {
        // Rain from above the screen.
        ox = r(0, 1);
        oy = -0.05;
        vx = r(-40, 40);
        vy = r(0, 120);
        delay = r(0.2, 2.0);
      }

      pieces.add(_ConfettiPiece(
        ox: ox,
        oy: oy,
        vx: vx,
        vy: vy,
        fall: r(110, 210),
        delay: delay,
        size: r(7, 13),
        angle: r(0, pi * 2),
        spin: r(-6, 6),
        flip: r(3, 8),
        sway: r(8, 26),
        swayFreq: r(2, 5),
        phase: r(0, pi * 2),
        round: rand.nextDouble() < 0.25,
        color: colors[rand.nextInt(colors.length)],
      ));
    }
    return pieces;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => SizedBox.expand(
        child: CustomPaint(
          painter: _ConfettiPainter(_pieces, _controller.value * _totalSeconds, _totalSeconds),
        ),
      ),
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  final List<_ConfettiPiece> pieces;
  final double t; // seconds since the burst started
  final double total;
  static const double _drag = 2.2;

  _ConfettiPainter(this.pieces, this.t, this.total);

  @override
  void paint(Canvas canvas, Size size) {
    final progress = (t / total).clamp(0.0, 1.0);
    final fade = progress > 0.78 ? 1 - (progress - 0.78) / 0.22 : 1.0;
    final paint = Paint();

    for (final p in pieces) {
      final lt = t - p.delay;
      if (lt < 0) continue;

      // Launch velocity decays with air drag towards a slow, steady fall.
      final e = 1 - exp(-_drag * lt);
      final x = p.ox * size.width +
          p.vx * e / _drag +
          p.sway * sin(p.swayFreq * lt + p.phase) * min(1.0, lt * 2);
      final y = p.oy * size.height + p.fall * lt + (p.vy - p.fall) * e / _drag;
      if (y > size.height + 30) continue;

      paint.color = p.color.withValues(alpha: fade.clamp(0.0, 1.0));
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(p.angle + p.spin * lt);
      final f = cos(p.flip * lt).abs();
      canvas.scale(1.0, f < 0.15 ? 0.15 : f); // paper "flutter"
      if (p.round) {
        canvas.drawCircle(Offset.zero, p.size * 0.45, paint);
      } else {
        canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * 0.55), paint);
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter old) => old.t != t;
}

'''
s = once(s, "class AuthOverlay extends StatefulWidget {", CONFETTI + "class AuthOverlay extends StatefulWidget {", "confetti-classes")

# ------------------------------------------------------------ AuthOverlay edits
start = s.index("class _AuthOverlayState")
end = s.index("\nclass AdminLoginOverlay", start)
seg = s[start:end]

seg = once(seg, "  bool _obscurePassword = true;\n  bool _isProcessing = false;\n",
"""  bool _obscurePassword = true;
  bool _isProcessing = false;

  bool _showInstructions = true;
  bool _showConfetti = false;
  int _confettiRun = 0;
""", "fields")

seg = once(seg, "        messageKey = 'account_created';\n",
"""        messageKey = 'account_created';
        _showConfetti = true; // celebrate the new account!
        _confettiRun++;
""", "confetti-trigger")

seg = once(seg, "  @override\n  Widget build(BuildContext context) {\n",
r"""  Widget _buildInstructions(bool isDark, Color textColor, Color accentColor) {
    final keys = isRegisterMode
        ? const ['instr_register_1', 'instr_register_2', 'instr_register_3', 'instr_register_4']
        : const ['instr_login_1', 'instr_login_2', 'instr_login_3', 'instr_login_4'];

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accentColor.withValues(alpha: 0.45), width: 1.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _showInstructions = !_showInstructions),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: AppColors.cheeseYellow, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.game.tr('instructions_title'),
                      style: TextStyle(
                        color: textColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                  Icon(_showInstructions ? Icons.expand_less : Icons.expand_more, color: accentColor),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: _showInstructions
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Column(
                      children: [
                        for (int i = 0; i < keys.length; i++)
                          Padding(
                            padding: EdgeInsets.only(bottom: i == keys.length - 1 ? 0 : 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 22,
                                  height: 22,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(color: accentColor, shape: BoxShape.circle),
                                  child: Text(
                                    '${i + 1}',
                                    style: TextStyle(
                                      color: isDark ? AppColors.darkNavy : Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    widget.game.tr(keys[i]),
                                    style: TextStyle(
                                      color: textColor.withValues(alpha: 0.92),
                                      fontSize: 13.5,
                                      height: 1.3,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildForm(context),
        if (_showConfetti)
          IgnorePointer(
            child: ConfettiBurst(
              key: ValueKey(_confettiRun),
              onDone: () {
                if (mounted) setState(() => _showConfetti = false);
              },
            ),
          ),
      ],
    );
  }

  Widget _buildForm(BuildContext context) {
""", "build-wrap")

seg = once(seg, """                  const SizedBox(height: 22),
                  TextField(
                    controller: _usernameController,""",
"""                  const SizedBox(height: 14),
                  _buildInstructions(isDark, textColor, accentColor),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _usernameController,""", "instructions-slot")

s = s[:start] + seg + s[end:]

if crlf:
    s = s.replace("\n", "\r\n")
open(PATH, "w", encoding="utf-8", newline="").write(s)
print("Patched lib/main.dart: login instructions + registration confetti.")