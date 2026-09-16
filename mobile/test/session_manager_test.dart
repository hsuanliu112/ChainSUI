// J1：SessionManager 持久化（access → shared_preferences；refresh → secure storage）
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_dapp/session_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  final expiresAt = DateTime(2030, 1, 1, 12, 0, 0);
  final session = UserSession(
    userId: 39,
    username: 'zk_1dabcd47fa',
    role: 'passenger',
    accessToken: 'access-1',
    refreshToken: 'refresh-1',
    accessTokenExpiresAt: expiresAt,
    walletAddress: '0xabc',
  );

  test('saveSession → loadSession 帶回 refresh token 與到期時間', () async {
    await SessionManager.saveSession(session);
    final loaded = await SessionManager.loadSession();
    expect(loaded, isNotNull);
    expect(loaded!.accessToken, 'access-1');
    expect(loaded.refreshToken, 'refresh-1');
    expect(loaded.accessTokenExpiresAt, expiresAt);
    expect(loaded.role, 'passenger');

    // refresh 不在 prefs（明文）裡，只在 secure storage
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().any((k) => k.contains('refresh')), isFalse);
    expect(await const FlutterSecureStorage().read(key: 'refresh_token'), 'refresh-1');
  });

  test('updateTokens 只換 token 三件組，其餘欄位不動', () async {
    await SessionManager.saveSession(session);
    final newExp = DateTime(2030, 1, 1, 12, 15, 0);
    await SessionManager.updateTokens(access: 'access-2', refresh: 'refresh-2', expiresAt: newExp);
    final loaded = await SessionManager.loadSession();
    expect(loaded!.accessToken, 'access-2');
    expect(loaded.refreshToken, 'refresh-2');
    expect(loaded.accessTokenExpiresAt, newExp);
    expect(loaded.userId, 39);
    expect(loaded.walletAddress, '0xabc');
  });

  test('clearSession 連 secure storage 的 refresh 一起清', () async {
    await SessionManager.saveSession(session);
    await SessionManager.clearSession();
    expect(await SessionManager.loadSession(), isNull);
    expect(await const FlutterSecureStorage().read(key: 'refresh_token'), isNull);
  });

  test('舊版 session（無 refresh / 無到期）仍可載入', () async {
    SharedPreferences.setMockInitialValues({
      'access_token': 'legacy',
      'user_id': 1,
      'username': 'u',
      'user_role': 'driver',
    });
    final loaded = await SessionManager.loadSession();
    expect(loaded!.accessToken, 'legacy');
    expect(loaded.refreshToken, isNull);
    expect(loaded.accessTokenExpiresAt, isNull);
  });
}
