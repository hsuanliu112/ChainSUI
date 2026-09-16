import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 使用者 session 持久化（J1）
///
/// - access token（15 分鐘）與到期時間、使用者基本資料 → shared_preferences。
/// - refresh token（30 天）→ flutter_secure_storage（Keychain / Keystore），不落明文。
/// - 本檔不驗 access 是否過期；過期由 ApiService 在請求時偵測並用 refresh 換新。
/// - zkLogin 的臨時私鑰（zk_ephemeral_sk）由 ZkLoginService 自行管理，本檔不碰。
const _tokenKey = 'access_token';
const _expiresAtKey = 'access_token_expires_at';
const _userIdKey = 'user_id';
const _usernameKey = 'username';
const _roleKey = 'user_role';
const _walletKey = 'wallet_address';
const _phoneKey = 'phone_number';
const _emailKey = 'email';
const _refreshKey = 'refresh_token';

class UserSession {
  const UserSession({
    required this.userId,
    required this.username,
    required this.role,
    required this.accessToken,
    this.refreshToken,
    this.accessTokenExpiresAt,
    this.walletAddress,
    this.phoneNumber,
    this.email,
  });

  final int userId;
  final String username;
  final String role;
  final String accessToken;
  final String? refreshToken;
  final DateTime? accessTokenExpiresAt;
  final String? walletAddress;
  final String? phoneNumber;
  final String? email;

  UserSession copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? accessTokenExpiresAt,
    String? walletAddress,
    String? phoneNumber,
    String? email,
  }) {
    return UserSession(
      userId: userId,
      username: username,
      role: role,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      accessTokenExpiresAt: accessTokenExpiresAt ?? this.accessTokenExpiresAt,
      walletAddress: walletAddress ?? this.walletAddress,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      email: email ?? this.email,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'username': username,
      'role': role,
      'accessToken': accessToken,
      'accessTokenExpiresAt': accessTokenExpiresAt?.toIso8601String(),
      'walletAddress': walletAddress,
      'phoneNumber': phoneNumber,
      'email': email,
      // refreshToken 刻意不放進 map，避免被印到 log
    };
  }

  factory UserSession.fromPrefs(SharedPreferences prefs, {String? refreshToken}) {
    final userId = prefs.getInt(_userIdKey);
    final username = prefs.getString(_usernameKey);
    final role = prefs.getString(_roleKey);
    final token = prefs.getString(_tokenKey);

    if (userId == null || username == null || role == null || token == null) {
      throw StateError('missing session data');
    }

    final expiresRaw = prefs.getString(_expiresAtKey);
    return UserSession(
      userId: userId,
      username: username,
      role: role,
      accessToken: token,
      refreshToken: refreshToken,
      accessTokenExpiresAt: expiresRaw == null ? null : DateTime.tryParse(expiresRaw),
      walletAddress: prefs.getString(_walletKey),
      phoneNumber: prefs.getString(_phoneKey),
      email: prefs.getString(_emailKey),
    );
  }
}

class SessionManager {
  static const _secure = FlutterSecureStorage();

  static Future<void> _writeRefresh(String? refresh) async {
    try {
      if (refresh == null || refresh.isEmpty) {
        await _secure.delete(key: _refreshKey);
      } else {
        await _secure.write(key: _refreshKey, value: refresh);
      }
    } catch (e) {
      // 少數機型 keystore 例外：退化為「只有 access、過期即登出」，不可讓流程崩潰
      print('⚠️ refresh token 無法寫入 secure storage: $e');
    }
  }

  static Future<String?> _readRefresh() async {
    try {
      return await _secure.read(key: _refreshKey);
    } catch (e) {
      print('⚠️ refresh token 無法讀取 secure storage: $e');
      return null;
    }
  }

  static Future<void> saveSession(UserSession session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, session.accessToken);
    await prefs.setInt(_userIdKey, session.userId);
    await prefs.setString(_usernameKey, session.username);
    await prefs.setString(_roleKey, session.role);

    final exp = session.accessTokenExpiresAt;
    if (exp != null) {
      await prefs.setString(_expiresAtKey, exp.toIso8601String());
    } else {
      await prefs.remove(_expiresAtKey);
    }

    if (session.walletAddress != null) {
      await prefs.setString(_walletKey, session.walletAddress!);
    } else {
      await prefs.remove(_walletKey);
    }

    if (session.phoneNumber != null) {
      await prefs.setString(_phoneKey, session.phoneNumber!);
    } else {
      await prefs.remove(_phoneKey);
    }

    if (session.email != null) {
      await prefs.setString(_emailKey, session.email!);
    } else {
      await prefs.remove(_emailKey);
    }

    await _writeRefresh(session.refreshToken);
  }

  /// refresh 成功後只更新 token 三件組，不重建整個 session。
  static Future<void> updateTokens({
    required String access,
    required String refresh,
    required DateTime expiresAt,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, access);
    await prefs.setString(_expiresAtKey, expiresAt.toIso8601String());
    await _writeRefresh(refresh);
  }

  static Future<UserSession?> loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(_tokenKey)) {
      return null;
    }

    try {
      final refresh = await _readRefresh();
      return UserSession.fromPrefs(prefs, refreshToken: refresh);
    } catch (_) {
      await clearSession();
      return null;
    }
  }

  static Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_expiresAtKey);
    await prefs.remove(_userIdKey);
    await prefs.remove(_usernameKey);
    await prefs.remove(_roleKey);
    await prefs.remove(_walletKey);
    await prefs.remove(_phoneKey);
    await prefs.remove(_emailKey);
    // iOS Keychain 可能在解除安裝後殘留，務必顯式刪除
    await _writeRefresh(null);
  }
}
