// mobile/lib/services/api_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'http_client_manager.dart';
import 'websocket_service.dart';
import '../app_navigator.dart';
import '../config/app_config.dart';
import '../session_manager.dart';

class ApiService {
  // 後端 API 基礎 URL（從配置讀取）
  // 本地開發時修改 lib/config/app_config.local.dart
  static final String baseUrl = AppConfig.backendUrl;

  // HTTP Client 管理器（單例）
  static final _httpClient = HttpClientManager();

  // ── J1 token 狀態（記憶體；持久化在 SessionManager）──
  static String? _token;
  static String? _refreshToken;
  static DateTime? _accessExpiresAt;
  static Future<bool>? _refreshInFlight; // 單飛：同時多個 401 只 refresh 一次
  static bool _loggingOut = false;

  static String? get token => _token;
  static bool get hasRefreshToken => _refreshToken != null && _refreshToken!.isNotEmpty;

  /// access 已過期（或 30 秒內將過期）。未知到期時間視為未過期，交給 401 兜底。
  static bool get accessLikelyExpired {
    final exp = _accessExpiresAt;
    if (exp == null) return false;
    return DateTime.now().isAfter(exp.subtract(const Duration(seconds: 30)));
  }

  // 獲取基礎 URL（用於 WebSocket）
  static String getBaseUrl() {
    return baseUrl.replaceAll('/api/v1', ''); // 移除 API 路徑
  }

  // 只設 access（舊呼叫端相容）；新流程請用 setSession / adoptSession
  static void setToken(String token) {
    _token = token;
  }

  static void setSession({required String access, String? refresh, DateTime? expiresAt}) {
    _token = access;
    _refreshToken = refresh;
    _accessExpiresAt = expiresAt;
  }

  /// 從 UserSession 帶入三件組（登入成功 / app 啟動時）
  static void adoptSession(UserSession session) {
    setSession(
      access: session.accessToken,
      refresh: session.refreshToken,
      expiresAt: session.accessTokenExpiresAt,
    );
  }

  /// 後端 expires_in（秒）→ 本地到期時間
  static DateTime? expiresAtFrom(dynamic expiresIn) {
    final secs = expiresIn is num ? expiresIn.toInt() : int.tryParse('${expiresIn ?? ''}');
    if (secs == null) return null;
    return DateTime.now().add(Duration(seconds: secs));
  }

  static void clearToken() {
    _token = null;
    _refreshToken = null;
    _accessExpiresAt = null;
  }

  // 獲取 headers
  static Map<String, String> get _headers {
    final headers = {'Content-Type': 'application/json'};

    if (_token != null) {
      headers['Authorization'] = 'Bearer $_token';
    } else {
      print('警告：沒有 Token！');
    }

    return headers;
  }

  // ── J1：refresh / 登出 ─────────────────────────────────────

  /// 用 refresh token 換新的 access + refresh。單飛；回 true = 已換到新 token。
  /// 回 false 時：refresh 被後端拒絕 → 已 forceLogout；網路/5xx → 保留 session。
  static Future<bool> refreshTokens() {
    return _refreshInFlight ??= _doRefresh().whenComplete(() => _refreshInFlight = null);
  }

  static Future<bool> _doRefresh() async {
    final rt = _refreshToken;
    if (rt == null || rt.isEmpty) {
      await forceLogout();
      return false;
    }
    http.Response res;
    try {
      // 不走 _handleRequest（避免遞迴）、不帶 Bearer（access 可能已過期）
      res = await _httpClient.executeRequest((client) => client.post(
            Uri.parse('$baseUrl/auth/refresh'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'refresh_token': rt}),
          ));
    } catch (e) {
      print('⚠️ refresh 網路錯誤（保留 session）: $e');
      return false;
    }

    if (res.statusCode == 200) {
      final d = jsonDecode(res.body) as Map<String, dynamic>;
      final access = d['access_token'] as String;
      final refresh = d['refresh_token'] as String;
      final exp = expiresAtFrom(d['expires_in']) ?? DateTime.now().add(const Duration(minutes: 15));
      setSession(access: access, refresh: refresh, expiresAt: exp);
      await SessionManager.updateTokens(access: access, refresh: refresh, expiresAt: exp);
      print('🔄 access token 已更新（expires ${exp.toIso8601String()}）');
      await WebSocketService().reconnect();
      return true;
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      print('❌ refresh 被拒（${res.statusCode}）：${res.body}');
      await forceLogout();
      return false;
    }
    print('⚠️ refresh 暫時失敗（${res.statusCode}），保留 session');
    return false;
  }

  /// 登入狀態失效：清本地 session、斷 WS、導回角色選擇頁。不碰 zkLogin 臨時私鑰。
  static Future<void> forceLogout() async {
    if (_loggingOut) return;
    _loggingOut = true;
    try {
      clearToken();
      WebSocketService().disconnect();
      await SessionManager.clearSession();
      appNavigatorKey.currentState?.pushNamedAndRemoveUntil('/role_select', (_) => false);
    } finally {
      _loggingOut = false;
    }
  }

  /// 使用者主動登出：後端撤銷 refresh（盡力而為）+ 本地清除 + 導頁。
  static Future<void> logout() async {
    final rt = _refreshToken;
    if (rt != null && rt.isNotEmpty) {
      try {
        await _httpClient.executeRequest((client) => client.post(
              Uri.parse('$baseUrl/auth/logout'),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({'refresh_token': rt}),
            ));
      } catch (e) {
        print('⚠️ 後端登出未送達（本地仍清除）: $e');
      }
    }
    await forceLogout();
  }

  static Map<String, dynamic> _wrapResponse(http.Response response) {
    dynamic data;
    try {
      data = response.body.isNotEmpty ? jsonDecode(response.body) : null;
    } catch (e) {
      // 如果無法解析 JSON，保存原始響應
      data = {
        'raw': response.body,
        'parseError': e.toString(),
        'statusCode': response.statusCode,
      };
    }

    // 檢查 HTTP 狀態碼
    final httpSuccess = response.statusCode >= 200 && response.statusCode < 300;

    // 如果響應體中有 success 字段，優先使用它
    bool finalSuccess = httpSuccess;
    if (data is Map && data.containsKey('success')) {
      finalSuccess = data['success'] == true;
    }

    // 如果是 500 錯誤且無法解析 JSON，添加更多信息
    if (response.statusCode == 500 &&
        data is Map &&
        data.containsKey('parseError')) {
      data['message'] = '後端服務器錯誤，請檢查後端日誌';
    }

    // 如果響應體中有 error 字段，提取它
    String? error;
    if (data is Map) {
      error = data['error']?.toString() ?? data['message']?.toString();
    }

    return {
      'success': finalSuccess,
      'data': data,
      'error': error,
      'statusCode': response.statusCode,
    };
  }

  static Future<Map<String, dynamic>> _handleRequest(
    Future<http.Response> Function(http.Client) request, {
    bool allowRefresh = true,
  }) async {
    try {
      // 已知 access 過期 → 先換，省一趟必敗的 401
      if (allowRefresh && accessLikelyExpired && hasRefreshToken) {
        await refreshTokens();
      }

      // 使用 HTTP Client Manager 執行請求，自動處理 client 錯誤
      var response = await _httpClient.executeRequest(request);

      // 401 → 單飛 refresh → 成功則重呼 closure 一次（closure 內重讀 _headers，自動帶新 token）
      if (response.statusCode == 401 && allowRefresh && hasRefreshToken) {
        final refreshed = await refreshTokens();
        if (refreshed) {
          response = await _httpClient.executeRequest(request);
        }
      } else if (response.statusCode == 401 && allowRefresh && !hasRefreshToken) {
        // 沒有 refresh 可用（例如升級前留下的舊 session）→ 直接視為登入失效
        await forceLogout();
      }

      final result = _wrapResponse(response);

      // 添加詳細日誌
      if (result['success'] != true) {
        print('API 請求失敗:');
        print('  狀態碼: ${result['statusCode']}');
        print('  響應: ${result['data']}');
      }

      return result;
    } on http.ClientException catch (e) {
      print('❌ HTTP Client 異常: $e');
      return {
        'success': false,
        'error': 'HTTP 連線錯誤: ${e.message}',
        'error_type': 'client_exception'
      };
    } catch (e) {
      print('API 請求異常: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  // ========== 通用 HTTP 方法 ==========

  /// 通用 GET 請求
  static Future<Map<String, dynamic>> get(String path) async {
    return _handleRequest((client) {
      final url = path.startsWith('http') ? path : '$baseUrl$path';
      return client.get(Uri.parse(url), headers: _headers);
    });
  }

  /// 通用 POST 請求
  static Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    return _handleRequest((client) {
      final url = path.startsWith('http') ? path : '$baseUrl$path';
      return client.post(
        Uri.parse(url),
        headers: _headers,
        body: jsonEncode(body),
      );
    });
  }

  /// 通用 PUT 請求
  static Future<Map<String, dynamic>> put(
    String path,
    Map<String, dynamic> body,
  ) async {
    return _handleRequest((client) {
      final url = path.startsWith('http') ? path : '$baseUrl$path';
      return client.put(
        Uri.parse(url),
        headers: _headers,
        body: jsonEncode(body),
      );
    });
  }

  /// 通用 DELETE 請求
  static Future<Map<String, dynamic>> delete(String path) async {
    return _handleRequest((client) {
      final url = path.startsWith('http') ? path : '$baseUrl$path';
      return client.delete(Uri.parse(url), headers: _headers);
    });
  }

  // ========== zkLogin（非託管登入，Enoki）==========

  /// 建立 zkLogin nonce（Flutter 拿去做 Google OAuth）
  static Future<Map<String, dynamic>> zkLoginNonce({
    required String ephemeralPublicKey,
    int additionalEpochs = 2,
  }) => post('/auth/zklogin/nonce', {
        'ephemeral_public_key': ephemeralPublicKey,
        'additional_epochs': additionalEpochs,
      });

  /// 用 OAuth JWT 完成 zkLogin 登入 → 取回 app token + zkLogin 位址
  static Future<Map<String, dynamic>> zkLoginLogin({
    required String jwt,
    String userType = 'passenger',
  }) => post('/auth/zklogin/login', {'jwt': jwt, 'user_type': userType});

  /// 產生 ZK proof（簽交易前置）
  static Future<Map<String, dynamic>> zkLoginZkp({
    required String jwt,
    required String ephemeralPublicKey,
    required int maxEpoch,
    required String randomness,
  }) => post('/auth/zklogin/zkp', {
        'jwt': jwt,
        'ephemeral_public_key': ephemeralPublicKey,
        'max_epoch': maxEpoch,
        'randomness': randomness,
      });

  // ========== 非託管付款（zkLogin + Enoki 贊助）==========

  /// 組交易 + 請 Enoki 贊助 → 回 {bytes, digest}（bytes 給前端用臨時金鑰簽）
  static Future<Map<String, dynamic>> preparePayment({
    required int tripId,
    required int amountMist,
    required String driver,
    String? platform,
  }) => post('/payments/zklogin/prepare', {
        'trip_id': tripId,
        'amount_mist': amountMist,
        'driver': driver,
        if (platform != null) 'platform': platform,
      });

  /// 送出乘客簽好的贊助交易 → 回 {digest, escrow_object_id}
  static Future<Map<String, dynamic>> executePayment({
    required String digest,
    required String signature,
  }) => post('/payments/zklogin/execute', {
        'digest': digest,
        'signature': signature,
      });

  // ========== 非託管委託（Phase 5）/ 爭議（Phase 6）zkLogin 贊助 ==========

  static Future<Map<String, dynamic>> delegatePrepare({
    required int maxSpendMist,
    required int dailyLimitMist,
    required int validForMs,
    int? allowedActions,
  }) => post('/agent/zklogin/delegate/prepare', {
        'max_spend_mist': maxSpendMist,
        'daily_limit_mist': dailyLimitMist,
        'valid_for_ms': validForMs,
        if (allowedActions != null) 'allowed_actions': allowedActions,
      });

  static Future<Map<String, dynamic>> delegateExecute({
    required String digest,
    required String signature,
  }) => post('/agent/zklogin/delegate/execute', {'digest': digest, 'signature': signature});

  static Future<Map<String, dynamic>> disputePrepare({
    required String escrowObjectId,
    required String reason,
  }) => post('/disputes/zklogin/prepare', {
        'escrow_object_id': escrowObjectId,
        'reason': reason,
      });

  static Future<Map<String, dynamic>> disputeExecute({
    required String digest,
    required String signature,
  }) => post('/disputes/zklogin/execute', {'digest': digest, 'signature': signature});

  // ========== 行程狀態機補充 ==========

  /// 司機開始行程（picked_up → in_progress）
  static Future<Map<String, dynamic>> startTrip(int tripId) =>
      put('/trips/$tripId/start', {});

  // ========== 爭議 ==========

  /// 乘客/司機發起爭議（回傳需簽的 raise_dispute 參數）
  static Future<Map<String, dynamic>> raiseDispute({
    required int tripId,
    required String reason,
    String? disputeObjectId,
  }) => post('/trips/$tripId/dispute', {
        'reason': reason,
        if (disputeObjectId != null) 'dispute_object_id': disputeObjectId,
      });

  /// 簽完 raise_dispute 後回報鏈上 Dispute 物件 ID
  static Future<Map<String, dynamic>> reportDisputeObject({
    required int tripId,
    required String disputeObjectId,
  }) => post('/trips/$tripId/dispute/report', {'dispute_object_id': disputeObjectId});

  // ========== Agent 委託（OperatorCap）==========

  /// 回報使用者簽發的 OperatorCap
  static Future<Map<String, dynamic>> recordDelegation(String capObjectId) =>
      post('/agent/delegation', {'cap_object_id': capObjectId});

  /// 查詢目前有效委託
  static Future<Map<String, dynamic>> getDelegation() => get('/agent/delegation');

  /// 撤銷委託
  static Future<Map<String, dynamic>> revokeDelegation() => delete('/agent/delegation');

  /// 設定自動執行門檻（MIST）：金額 ≤ 此值由 Agent 自動代發，> 此值需乘客確認
  static Future<Map<String, dynamic>> updateDelegationSettings(int autoThresholdMist) =>
      put('/agent/delegation/settings', {'auto_threshold_mist': autoThresholdMist});

  // ========== Agent 決策活動（LLM 決策層）==========

  /// Agent 代理活動 feed（可選 status 過濾，如 'pending' 只看待確認）
  static Future<Map<String, dynamic>> getAgentActivities({
    int limit = 20,
    int offset = 0,
    String? status,
  }) {
    final q = <String>['limit=$limit', 'offset=$offset'];
    if (status != null) q.add('status=$status');
    return get('/agent/activities?${q.join('&')}');
  }

  /// 乘客確認一筆大額 pending 決策 → 實際代發上鏈
  static Future<Map<String, dynamic>> confirmAgentDecision(int decisionId) =>
      post('/agent/decisions/$decisionId/confirm', {});

  /// 乘客拒絕一筆 pending 決策
  static Future<Map<String, dynamic>> declineAgentDecision(int decisionId) =>
      post('/agent/decisions/$decisionId/decline', {});

  // ========== 用戶相關 API ==========

  // 用戶註冊
  static Future<Map<String, dynamic>> registerUser({
    required String username,
    required String password,
    required String walletAddress,
    required String email,
    required String userType,
    String? phoneNumber,
    String? displayName,
  }) async {
    return _handleRequest((client) {
      return client.post(
        Uri.parse('$baseUrl/users/register'),
        headers: _headers,
        body: jsonEncode({
          'username': username,
          'password': password,
          'wallet_address': walletAddress,
          'email': email,
          'user_type': userType,
          if (phoneNumber != null) 'phone_number': phoneNumber,
          if (displayName != null) 'display_name': displayName,
        }),
      );
    });
  }

  // 用戶登入
  static Future<Map<String, dynamic>> loginUser({
    required String identifier,
    required String password,
  }) async {
    final result = await _handleRequest((client) {
      return client.post(
        Uri.parse('$baseUrl/users/login'),
        headers: _headers,
        body: jsonEncode({'identifier': identifier, 'password': password}),
      );
    });

    if (result['success'] == true) {
      final data = result['data'];
      if (data is Map && data['access_token'] is String) {
        setSession(
          access: data['access_token'] as String,
          refresh: data['refresh_token'] as String?,
          expiresAt: expiresAtFrom(data['expires_in']),
        );
        print('登入成功，token 已設置');
      } else {
        print('警告：登入成功但沒有 access_token');
        print('響應數據: $data');
      }
    } else {
      print('登入失敗: ${result['data']}');
    }

    return result;
  }

  static Future<Map<String, dynamic>> getUserProfile(int userId) async {
    return _handleRequest((client) {
      return client.get(Uri.parse('$baseUrl/users/$userId'), headers: _headers);
    });
  }

  // 更新用戶資訊
  static Future<Map<String, dynamic>> updateUserProfile({
    required int userId,
    String? displayName,
    String? email,
    String? phone,
  }) async {
    final body = <String, dynamic>{};
    if (displayName != null) body['display_name'] = displayName;
    if (email != null) body['email'] = email;
    if (phone != null) body['phone'] = phone;

    return _handleRequest((client) {
      return client.patch(
        Uri.parse('$baseUrl/users/$userId'),
        headers: _headers,
        body: jsonEncode(body),
      );
    });
  }

  // 檢查用戶名是否可用
  static Future<Map<String, dynamic>> checkUsername(String username) async {
    return _handleRequest((client) {
      return client.get(
        Uri.parse('$baseUrl/users/check-username/$username'),
        headers: _headers,
      );
    });
  }

  // 獲取附近可用車輛
  static Future<Map<String, dynamic>> getAvailableVehicles({
    required double lat,
    required double lng,
    double radiusKm = 5.0,
    int limit = 20,
  }) async {
    final uri = Uri.parse('$baseUrl/vehicles/available').replace(
      queryParameters: {
        'lat': lat.toString(),
        'lng': lng.toString(),
        'radius_km': radiusKm.toString(),
        'limit': limit.toString(),
      },
    );

    return _handleRequest((client) => client.get(uri, headers: _headers));
  }

  // 創建行程請求
  static Future<Map<String, dynamic>> createTripRequest({
    required double pickupLat,
    required double pickupLng,
    required String pickupAddress,
    required double dropoffLat,
    required double dropoffLng,
    required String dropoffAddress,
    required int passengerCount,
    bool useDynamicPricing = false, // 新增：是否使用動態定價（快速叫車）
    String? preferredVehicleType,
    String? notes,
    List<Map<String, dynamic>>? waypoints, // 新增：中繼點列表
  }) async {
    final body = {
      'pickup_lat': pickupLat,
      'pickup_lng': pickupLng,
      'pickup_address': pickupAddress,
      'dropoff_lat': dropoffLat,
      'dropoff_lng': dropoffLng,
      'dropoff_address': dropoffAddress,
      'passenger_count': passengerCount,
      'use_dynamic_pricing': useDynamicPricing,
      'preferred_vehicle_type': preferredVehicleType,
      'notes': notes,
    };

    // 添加 waypoints（如果有）
    if (waypoints != null && waypoints.isNotEmpty) {
      body['waypoints'] = waypoints;
    }

    return _handleRequest((client) {
      return client.post(
        Uri.parse('$baseUrl/trips/'),
        headers: _headers,
        body: jsonEncode(body),
      );
    });
  }

  // 獲取行程預估
  static Future<Map<String, dynamic>> getTripEstimate({
    required double pickupLat,
    required double pickupLng,
    required double dropoffLat,
    required double dropoffLng,
  }) async {
    final uri = Uri.parse('$baseUrl/trips/estimate').replace(
      queryParameters: {
        'pickup_lat': pickupLat.toString(),
        'pickup_lng': pickupLng.toString(),
        'dropoff_lat': dropoffLat.toString(),
        'dropoff_lng': dropoffLng.toString(),
      },
    );

    return _handleRequest((client) => client.post(uri, headers: _headers));
  }

  // 獲取用戶行程列表
  static Future<Map<String, dynamic>> getUserTrips({
    String? status,
    int limit = 20,
    int offset = 0,
  }) async {
    final queryParams = <String, String>{
      'limit': limit.toString(),
      'offset': offset.toString(),
    };

    if (status != null) {
      queryParams['status'] = status;
    }

    final uri = Uri.parse(
      '$baseUrl/trips/',
    ).replace(queryParameters: queryParams);

    return _handleRequest((client) => client.get(uri, headers: _headers));
  }

  // ============================================================================
  // 錢包 API
  // ============================================================================

  // 創建錢包
  static Future<Map<String, dynamic>> createWallet({
    required String password,
  }) async {
    return _handleRequest((client) {
      return client.post(
        Uri.parse('$baseUrl/wallet/create'),
        headers: _headers,
        body: jsonEncode({'password': password}),
      );
    });
  }

  // 導入錢包
  static Future<Map<String, dynamic>> importWallet({
    required String mnemonic,
    required String password,
  }) async {
    return _handleRequest((client) {
      return client.post(
        Uri.parse('$baseUrl/wallet/import'),
        headers: _headers,
        body: jsonEncode({'mnemonic': mnemonic, 'password': password}),
      );
    });
  }

  // 獲取錢包餘額
  static Future<Map<String, dynamic>> getWalletBalance() async {
    return _handleRequest((client) {
      return client.get(Uri.parse('$baseUrl/wallet/balance'), headers: _headers);
    });
  }

  // 獲取錢包信息
  static Future<Map<String, dynamic>> getWalletInfo() async {
    return _handleRequest((client) {
      return client.get(Uri.parse('$baseUrl/wallet/info'), headers: _headers);
    });
  }

  // 向 testnet faucet 領測試幣到當前用戶（zkLogin）位址
  static Future<Map<String, dynamic>> requestFaucet() async {
    return _handleRequest((client) {
      return client.post(Uri.parse('$baseUrl/wallet/faucet'), headers: _headers);
    });
  }

  // 簽署交易
  static Future<Map<String, dynamic>> signTransaction({
    required String password,
    required Map<String, dynamic> transaction,
  }) async {
    return _handleRequest((client) {
      return client.post(
        Uri.parse('$baseUrl/wallet/sign-transaction'),
        headers: _headers,
        body: jsonEncode({'password': password, 'transaction': transaction}),
      );
    });
  }

  static Future<Map<String, dynamic>> registerVehicle({
    required String vehicleId,
    required String plateNumber,
    required String model,
    required String vehicleType,
    required double currentChargePercent,
    required int hourlyRate,
    double? batteryCapacity,
    double? currentLat,
    double? currentLng,
  }) async {
    return _handleRequest((client) {
      return client.post(
        Uri.parse('$baseUrl/vehicles/'),
        headers: _headers,
        body: jsonEncode({
          'vehicle_id': vehicleId,
          'plate_number': plateNumber,
          'model': model,
          'vehicle_type': vehicleType,
          'current_charge_percent': currentChargePercent,
          'hourly_rate': hourlyRate,
          if (batteryCapacity != null) 'battery_capacity_kwh': batteryCapacity,
          if (currentLat != null) 'current_lat': currentLat,
          if (currentLng != null) 'current_lng': currentLng,
        }),
      );
    });
  }

  static Future<Map<String, dynamic>> getMyVehicles() async {
    return _handleRequest((client) {
      return client.get(Uri.parse('$baseUrl/vehicles/my'), headers: _headers);
    });
  }

  static Future<Map<String, dynamic>> updateVehicleStatus({
    required String vehicleId,
    required String status,
  }) async {
    return _handleRequest((client) {
      return client.put(
        Uri.parse(
          '$baseUrl/vehicles/$vehicleId/status',
        ).replace(queryParameters: {'status': status}),
        headers: _headers,
      );
    });
  }

  static Future<Map<String, dynamic>> updateVehicleLocation({
    required String vehicleId,
    required double lat,
    required double lng,
    String? status,
  }) async {
    return _handleRequest((client) {
      return client.put(
        Uri.parse('$baseUrl/vehicles/$vehicleId/location'),
        headers: _headers,
        body: jsonEncode({
          'lat': lat,
          'lng': lng,
          if (status != null) 'status': status,
        }),
      );
    });
  }

  static Future<Map<String, dynamic>> acceptTrip({
    required int tripId,
    required int etaMinutes,
  }) async {
    return _handleRequest((client) {
      return client.post(
        Uri.parse('$baseUrl/trips/$tripId/accept'),
        headers: _headers,
        body: jsonEncode({'estimated_arrival_minutes': etaMinutes}),
      );
    });
  }

  static Future<Map<String, dynamic>> completeTrip(int tripId) async {
    return _handleRequest((client) {
      return client.put(
        Uri.parse('$baseUrl/trips/$tripId/complete'),
        headers: _headers,
      );
    });
  }

  static Future<Map<String, dynamic>> cancelTrip({
    required int tripId,
    required String reason,
    required String cancelledBy,
  }) async {
    return _handleRequest((client) {
      return client.put(
        Uri.parse('$baseUrl/trips/$tripId/cancel'),
        headers: _headers,
        body: jsonEncode({'reason': reason, 'cancelled_by': cancelledBy}),
      );
    });
  }

  // 支付相關 API
  static Future<Map<String, dynamic>> confirmPayment({
    required int tripId,
    required String escrowObjectId,
  }) async {
    return _handleRequest((client) {
      return client.post(
        Uri.parse(
          '$baseUrl/trips/$tripId/confirm-payment?escrow_object_id=$escrowObjectId',
        ),
        headers: _headers,
      );
    });
  }

  static Future<Map<String, dynamic>> verifyTripPayment({
    required int tripId,
    required String txHash,
  }) async {
    return _handleRequest((client) {
      return client.post(
        Uri.parse('$baseUrl/trips/$tripId/verify-payment?tx_hash=$txHash'),
        headers: _headers,
      );
    });
  }

  static Future<Map<String, dynamic>> getTransactionStatus(
    String txHash,
  ) async {
    return _handleRequest((client) {
      return client.get(
        Uri.parse('$baseUrl/trips/payment/transaction/$txHash'),
        headers: _headers,
      );
    });
  }

  // 司機相關 API
  static Future<Map<String, dynamic>> getAvailableTrips({
    int limit = 10,
    int offset = 0,
  }) async {
    return _handleRequest((client) {
      return client.get(
        Uri.parse('$baseUrl/trips/available?limit=$limit&offset=$offset'),
        headers: _headers,
      );
    });
  }

  // 獲取司機的進行中行程
  static Future<Map<String, dynamic>> getDriverActiveTrip() async {
    return _handleRequest((client) {
      return client.get(Uri.parse('$baseUrl/trips/my-active'), headers: _headers);
    });
  }

  // 獲取行程詳情
  static Future<Map<String, dynamic>> getTripDetails(int tripId) async {
    return _handleRequest((client) {
      return client.get(Uri.parse('$baseUrl/trips/$tripId'), headers: _headers);
    });
  }

  // 獲取行程路線（用於地圖繪製）
  static Future<Map<String, dynamic>> getTripRoute(int tripId) async {
    return _handleRequest((client) {
      return client.get(
        Uri.parse('$baseUrl/trips/$tripId/route'),
        headers: _headers,
      );
    });
  }

  // 司機接到乘客
  static Future<Map<String, dynamic>> pickupPassenger(int tripId) async {
    return _handleRequest((client) {
      return client.put(
        Uri.parse('$baseUrl/trips/$tripId/pickup'),
        headers: _headers,
      );
    });
  }

  // 獲取臨時託管地址
  static Future<Map<String, dynamic>> getTempEscrowAddress() async {
    return _handleRequest((client) {
      return client.get(
        Uri.parse('$baseUrl/payment/temp-escrow-address'),
        headers: _headers,
      );
    });
  }

  // 處理支付（後端代理調用智能合約）
  static Future<Map<String, dynamic>> processPayment({
    required int tripId,
    required String txHash,
  }) async {
    return _handleRequest((client) {
      return client.post(
        Uri.parse('$baseUrl/payment/process-payment'),
        headers: _headers,
        body: jsonEncode({'trip_id': tripId, 'tx_hash': txHash}),
      );
    });
  }

  /// 創建託管支付（調用智能合約 lock_payment）
  ///
  /// 此方法會調用後端 API，後端會使用 operator 錢包調用智能合約的
  /// `autodrive::payment_escrow::lock_payment` 函數來創建託管支付。
  ///
  /// 參數：
  /// - [tripId]: 行程 ID
  /// - [amountSui]: 支付金額（SUI 格式）
  /// - [driverWallet]: 司機錢包地址（可選）
  ///
  /// 返回：
  /// - success: 是否成功
  /// - tx_hash: 交易哈希
  /// - escrow_id: 託管對象 ID
  /// - error: 錯誤信息（如果失敗）
  static Future<Map<String, dynamic>> createEscrowPayment({
    required int tripId,
    required double amountSui,
    String? driverWallet,
  }) async {
    print('📤 調用 createEscrowPayment API:');
    print('  行程 ID: $tripId');
    print('  金額: $amountSui SUI');
    print('  司機地址: ${driverWallet ?? "未提供"}');

    return _handleRequest((client) {
      return client.post(
        Uri.parse('$baseUrl/trips/$tripId/escrow-payment'),
        headers: _headers,
        body: jsonEncode({
          'amount_sui': amountSui,
          if (driverWallet != null) 'driver_wallet': driverWallet,
        }),
      );
    });
  }

  // 退款請求統一改走 services/refund_service.dart 的 RefundService（multipart，支援佐證檔）。
  // 原本重複的 createRefundRequest 已移除，避免雙路徑不一致。
}
