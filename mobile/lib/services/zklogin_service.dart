// mobile/lib/services/zklogin_service.dart
//
// zkLogin 非託管登入（Phase 0c）。
//
// 原理：不保管使用者私鑰/助記詞。App 每個 session 產生一把「臨時 ed25519 金鑰」
// （只存於 flutter_secure_storage，可隨時重生），用它做 Google OAuth 的 nonce 綁定；
// Google 回傳的 JWT + 臨時金鑰 → 透過 Enoki 推導出使用者的 Sui zkLogin 位址。
// 簽交易時：後端用 Enoki 產 ZK proof，App 用臨時金鑰簽 tx digest，兩者組成 zkLogin 簽名。
//
// 流程：
//   1. genEphemeralKey()        產臨時金鑰（存 secure storage）
//   2. requestNonce()           後端 /auth/zklogin/nonce（帶臨時公鑰）→ nonce/maxEpoch/randomness
//   3. googleSignIn(nonce)      AppAuth 對 Google 授權，nonce 注入 → 取 id_token(JWT)
//   4. completeLogin(jwt)       後端 /auth/zklogin/login → app JWT + zkLogin 位址 → UserSession
//   5. signDigest(digest)       （付款/委託/爭議用）臨時金鑰簽 digest
//
// 需求：AppConfig.googleOAuthClientId / googleOAuthRedirectUrl 已填、且該 client id 已在
//       Enoki Portal 註冊為 Google Auth Provider。

import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/digests/blake2b.dart';

import '../config/app_config.dart';
import '../session_manager.dart';
import 'api_service.dart';

class ZkLoginException implements Exception {
  final String message;
  ZkLoginException(this.message);
  @override
  String toString() => 'ZkLoginException: $message';
}

/// 臨時金鑰 + 一次登入回合的暫存狀態。
class _EphemeralSession {
  final ed.PrivateKey privateKey;
  final ed.PublicKey publicKey;
  String? nonce;
  int? maxEpoch;
  String? randomness;

  _EphemeralSession(this.privateKey, this.publicKey);

  /// Sui 序列化公鑰：flag(0x00=ed25519) + 32 bytes，再 base64。
  String get suiPublicKeyB64 =>
      base64.encode(Uint8List.fromList([0x00, ...publicKey.bytes]));
}

class ZkLoginService {
  ZkLoginService._();
  static final ZkLoginService instance = ZkLoginService._();

  static const _storage = FlutterSecureStorage();
  static const _skKey = 'zk_ephemeral_sk'; // base64(ed25519 seed, 32B)

  final _appAuth = const FlutterAppAuth();
  _EphemeralSession? _session;

  bool get isConfigured =>
      AppConfig.googleOAuthClientId.isNotEmpty &&
      AppConfig.googleOAuthRedirectUrl.isNotEmpty;

  /// 一鍵登入：產金鑰 → 取 nonce → Google 授權 → 換 app JWT/位址 → 存 session。
  /// 回傳建立好的 UserSession（並已 SessionManager.saveSession）。
  Future<UserSession> loginWithGoogle({String userType = 'passenger'}) async {
    if (!isConfigured) {
      throw ZkLoginException(
          '尚未設定 Google OAuth（AppConfig.googleOAuthClientId / redirectUrl），'
          '且該 client id 需在 Enoki Portal 註冊為 Auth Provider。');
    }
    await _genEphemeralKey();
    await _requestNonce();
    final jwt = await _googleSignIn();
    return _completeLogin(jwt, userType);
  }

  // 1. 產臨時 ed25519 金鑰並存入 secure storage（session 週期，可重生）。
  Future<void> _genEphemeralKey() async {
    final kp = ed.generateKey();
    _session = _EphemeralSession(kp.privateKey, kp.publicKey);
    // ed25519_edwards 私鑰 bytes 為 64B(seed+pub)；存 seed(前 32B)即可還原。
    final seed = kp.privateKey.bytes.sublist(0, 32);
    await _storage.write(key: _skKey, value: base64.encode(seed));
  }

  // 2. 後端取 nonce（後端代理 Enoki）。
  Future<void> _requestNonce() async {
    final s = _session!;
    final res = await ApiService.zkLoginNonce(ephemeralPublicKey: s.suiPublicKeyB64);
    if (res['success'] != true) {
      throw ZkLoginException('取得 nonce 失敗：${res['error']}');
    }
    final data = res['data'] as Map<String, dynamic>;
    s.nonce = data['nonce'] as String?;
    s.maxEpoch = (data['maxEpoch'] as num?)?.toInt();
    s.randomness = data['randomness']?.toString();
    if (s.nonce == null) throw ZkLoginException('Enoki 未回傳 nonce');
  }

  // 3. Google OAuth：nonce 注入 additionalParameters → id_token 內含此 nonce。
  Future<String> _googleSignIn() async {
    final s = _session!;
    final result = await _appAuth.authorizeAndExchangeCode(
      AuthorizationTokenRequest(
        AppConfig.googleOAuthClientId,
        AppConfig.googleOAuthRedirectUrl,
        issuer: 'https://accounts.google.com',
        scopes: const ['openid', 'email', 'profile'],
        // 用 AppAuth 專用的 nonce 參數（非 additionalParameters），確保寫進 id_token 的
        // nonce claim 就是 Enoki 給的那個、且不被 AppAuth 自動產生的 nonce 覆蓋——
        // 否則 zkLogin 位址推導會因 JWT nonce 不符而失敗。
        nonce: s.nonce!,
        promptValues: const ['select_account'],
      ),
    );
    final jwt = result.idToken;
    if (jwt == null || jwt.isEmpty) {
      throw ZkLoginException('Google 未回傳 id_token');
    }
    return jwt;
  }

  // 4. 後端 login：JWT → zkLogin 位址 → upsert user → app JWT。
  Future<UserSession> _completeLogin(String jwt, String userType) async {
    final res = await ApiService.zkLoginLogin(jwt: jwt, userType: userType);
    if (res['success'] != true) {
      throw ZkLoginException('zkLogin 登入失敗：${res['error']}');
    }
    final data = res['data'] as Map<String, dynamic>;
    final session = UserSession(
      userId: (data['user_id'] as num).toInt(),
      username: data['username'] as String,
      role: (data['role'] as String?) ?? userType,
      accessToken: data['access_token'] as String,
      refreshToken: data['refresh_token'] as String?,
      accessTokenExpiresAt: ApiService.expiresAtFrom(data['expires_in']),
      walletAddress: data['wallet_address'] as String?,
    );
    ApiService.adoptSession(session);
    await SessionManager.saveSession(session);
    return session;
  }

  /// 供 Phase 4/5/6 簽交易用：用臨時金鑰簽 tx digest（回傳 base64 簽名）。
  /// 需在同一 session（未重生金鑰）內呼叫；跨 session 需重新登入取 proof。
  Future<String> signDigest(Uint8List digest) async {
    final sk = await _loadEphemeralKey();
    final sig = ed.sign(sk, digest);
    return base64.encode(sig);
  }

  /// 對 Enoki 贊助回傳的 transaction bytes 產生 Sui 序列化 ed25519 簽名。
  ///
  /// Sui 簽名對象 = blake2b256( intent(=[0,0,0] for TransactionData) ++ txBytes )；
  /// 序列化格式 = flag(0x00=ed25519) ++ signature(64) ++ ephemeralPublicKey(32) 再 base64。
  /// Enoki 贊助執行時會用此臨時簽名 + 它保管的 ZKP 組出完整 zkLogin 簽名並送鏈。
  ///
  /// ⚠️ 待實機驗證：若 Enoki execute 要求「已組裝的 zkLogin 簽名」而非臨時簽名，
  /// 需改在此組裝（ephemeral sig + proofPoints + maxEpoch + addressSeed 的 BCS 序列化）。
  Future<String> signSuiTransactionBytes(Uint8List txBytes) async {
    final sk = await _loadEphemeralKey();
    final pk = ed.public(sk);
    final intentMessage = Uint8List.fromList([0, 0, 0, ...txBytes]);
    final digest = _blake2b256(intentMessage);
    final sig = ed.sign(sk, digest); // 64 bytes
    final serialized = Uint8List.fromList([0x00, ...sig, ...pk.bytes]);
    return base64.encode(serialized);
  }

  Uint8List _blake2b256(Uint8List data) {
    final d = Blake2bDigest(digestSize: 32);
    d.update(data, 0, data.length);
    final out = Uint8List(32);
    d.doFinal(out, 0);
    return out;
  }

  /// 目前登入回合的臨時公鑰（Sui b64）與 nonce 資料，供產 ZKP 用。
  Map<String, dynamic>? get currentProofInputs {
    final s = _session;
    if (s == null || s.nonce == null) return null;
    return {
      'ephemeral_public_key': s.suiPublicKeyB64,
      'max_epoch': s.maxEpoch,
      'randomness': s.randomness,
    };
  }

  Future<ed.PrivateKey> _loadEphemeralKey() async {
    if (_session != null) return _session!.privateKey;
    final stored = await _storage.read(key: _skKey);
    if (stored == null) {
      throw ZkLoginException('臨時金鑰不存在，請重新登入');
    }
    final seed = base64.decode(stored);
    final sk = ed.newKeyFromSeed(Uint8List.fromList(seed));
    return sk;
  }

  /// 完整登出：清 zkLogin 臨時私鑰（只有這裡會清）+ 撤銷 refresh + 清 session + 導頁。
  Future<void> logout() async {
    _session = null;
    await _storage.delete(key: _skKey);
    await ApiService.logout();
  }
}
