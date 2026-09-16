// mobile/lib/pages/auth_page.dart
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../session_manager.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isLoading = false;

  Future<void> _handleLogin() async {
    if (_usernameController.text.trim().isEmpty ||
        _passwordController.text.trim().isEmpty) {
      _showSnackBar('請填寫所有必填欄位');
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 登入
      final result = await ApiService.loginUser(
        identifier: _usernameController.text.trim(),
        password: _passwordController.text.trim(),
      );

      if (!mounted) return;

      if (result['success']) {
        // 登入成功，保存 session
        final userData = result['data']['user'];
        final userType = userData['user_type'] ?? 'passenger';

        // 'both' 類型用戶預設使用 passenger，driver/passenger 用戶使用對應身份
        final finalRole = userType == 'both' ? 'passenger' : userType;

        final session = UserSession(
          userId: userData['id'],
          username: userData['username'],
          role: finalRole,
          accessToken: result['data']['access_token'],
          refreshToken: result['data']['refresh_token']?.toString(),
          accessTokenExpiresAt: ApiService.expiresAtFrom(result['data']['expires_in']),
          walletAddress: userData['wallet_address'],
          phoneNumber: userData['phone_number'],
          email: userData['email'],
        );

        await SessionManager.saveSession(session);
        ApiService.adoptSession(session);

        // ✅ 統一初始化 WebSocket 連接（登入成功後唯一入口）
        print('🔌 登入成功，初始化 WebSocket 連接...');
        await WebSocketService().connect();
        print('✅ WebSocket 初始化完成');

        if (!mounted) return;

        // 根據最終角色跳轉
        if (finalRole == 'driver') {
          Navigator.pushReplacementNamed(
            context,
            '/driver',
            arguments: {'session': session},
          );
        } else {
          Navigator.pushReplacementNamed(
            context,
            '/passenger',
            arguments: {'session': session},
          );
        }
      } else {
        // 處理錯誤
        String errorMessage = '操作失敗';
        if (result['data'] != null && result['data']['detail'] != null) {
          errorMessage = result['data']['detail'].toString();
        } else if (result['error'] != null) {
          errorMessage = result['error'].toString();
        }
        _showSnackBar(errorMessage);
      }
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('網絡錯誤：$e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _goToRegister() {
    Navigator.pushNamed(context, '/register_with_wallet_connect');
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red.shade700),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            width: 350,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.6),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 20),
                const Text(
                  "登入",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 20),

                // 用戶名
                _buildTextField(
                  controller: _usernameController,
                  hintText: "用戶名 / 郵箱 / 手機",
                  icon: Icons.person,
                ),
                const SizedBox(height: 16),

                // 密碼
                _buildTextField(
                  controller: _passwordController,
                  hintText: "密碼",
                  icon: Icons.lock,
                  obscureText: true,
                ),

                const SizedBox(height: 20),

                // 登入按鈕
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _handleLogin,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1DB954),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child:
                        _isLoading
                            ? const CircularProgressIndicator(
                              color: Colors.white,
                            )
                            : const Text(
                              "登入",
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.white,
                              ),
                            ),
                  ),
                ),

                const SizedBox(height: 16),

                // 註冊按鈕
                TextButton(
                  onPressed: _goToRegister,
                  child: const Text(
                    "沒有帳號？立即註冊",
                    style: TextStyle(color: Color(0xFF1DB954)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hintText,
    required IconData icon,
    bool obscureText = false,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: const TextStyle(color: Colors.white70),
        prefixIcon: Icon(icon, color: Colors.white70),
        filled: true,
        fillColor: Colors.white10,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
      ),
    );
  }
}
