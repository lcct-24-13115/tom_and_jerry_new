"""
Fix: password field can't be typed into after registering.
Patches ONLY the AuthOverlay in lib/main.dart, in place. Nothing else is touched.
Run from the project root:   python apply_auth_focus_fix.py
"""
import sys

PATH = "lib/main.dart"
s = open(PATH, encoding="utf-8", newline="").read()
crlf = "\r\n" in s
s = s.replace("\r\n", "\n")

if "_passwordFocus" in s:
    print("Already patched. Nothing to do.")
    sys.exit(0)

start = s.index("class _AuthOverlayState")
end = s.index("\nclass AdminLoginOverlay", start)
seg = s[start:end]

def rep(old, new):
    global seg
    if seg.count(old) != 1:
        sys.exit("ABORT: expected exactly 1 match, found %d for:\n%s" % (seg.count(old), old[:90]))
    seg = seg.replace(old, new)

rep("""  final _confirmPasswordController = TextEditingController();

  bool isRegisterMode = false;""",
"""  final _confirmPasswordController = TextEditingController();

  // FIX: explicit focus nodes so focus can be handed back to the text fields.
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _confirmFocus = FocusNode();

  bool isRegisterMode = false;""")

rep("""  void _handleAuth() async {
    if (_isProcessing) return;
""",
"""  void _focusAfterBuild(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) node.requestFocus();
    });
  }

  void _handleAuth() async {
    if (_isProcessing) return;
""")

rep("""      _confirmPasswordController.clear();

      setState(() {
        isRegisterMode = false;
        messageKey = 'account_created';
        isError = false;
        _isProcessing = false;
      });
    } else {""",
"""      _confirmPasswordController.clear();

      // FIX: release focus BEFORE the confirm field leaves the tree.
      FocusManager.instance.primaryFocus?.unfocus();

      setState(() {
        isRegisterMode = false;
        messageKey = 'account_created';
        isError = false;
        _isProcessing = false;
      });
      _focusAfterBuild(_usernameFocus);
    } else {""")

rep("""          messageKey = 'user_not_found';
          isError = true;
          _isProcessing = false;
        });
        return;""",
"""          messageKey = 'user_not_found';
          isError = true;
          _isProcessing = false;
        });
        _focusAfterBuild(_usernameFocus);
        return;""")

rep("""          messageKey = 'wrong_password';
          isError = true;
          _isProcessing = false;
        });
        return;""",
"""          messageKey = 'wrong_password';
          isError = true;
          _isProcessing = false;
        });
        _focusAfterBuild(_passwordFocus);
        return;""")

rep("""    _confirmPasswordController.dispose();
    super.dispose();""",
"""    _confirmPasswordController.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();""")

rep("""                    controller: _usernameController,
                    enabled: !_isProcessing,""",
"""                    controller: _usernameController,
                    focusNode: _usernameFocus,
                    readOnly: _isProcessing,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => _passwordFocus.requestFocus(),""")

rep("""                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    enabled: !_isProcessing,""",
"""                    controller: _passwordController,
                    focusNode: _passwordFocus,
                    obscureText: _obscurePassword,
                    readOnly: _isProcessing,
                    textInputAction: isRegisterMode ? TextInputAction.next : TextInputAction.done,
                    onSubmitted: (_) => isRegisterMode ? _confirmFocus.requestFocus() : _handleAuth(),""")

rep("""                              controller: _confirmPasswordController,
                              obscureText: _obscurePassword,
                              enabled: !_isProcessing,""",
"""                              controller: _confirmPasswordController,
                              focusNode: _confirmFocus,
                              obscureText: _obscurePassword,
                              readOnly: _isProcessing,
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) => _handleAuth(),""")

rep("""                        : () {
                            setState(() {
                              isRegisterMode = !isRegisterMode;
                              messageKey = '';
                              _confirmPasswordController.clear();
                            });
                          },""",
"""                        : () {
                            FocusManager.instance.primaryFocus?.unfocus();
                            setState(() {
                              isRegisterMode = !isRegisterMode;
                              messageKey = '';
                              _confirmPasswordController.clear();
                            });
                            _focusAfterBuild(_usernameFocus);
                          },""")

s = s[:start] + seg + s[end:]
if crlf:
    s = s.replace("\n", "\r\n")
open(PATH, "w", encoding="utf-8", newline="").write(s)
print("Patched lib/main.dart (AuthOverlay only).")