// mobile/lib/services/refund_service.dart

import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'api_service.dart';
import 'http_client_manager.dart';
import '../config/app_config.dart';

/// 退款 API（multipart 上傳，不走 ApiService._handleRequest）。
/// J1：token 改由 ApiService 提供（不再由頁面傳入 stale 的 session.accessToken），
/// 送出前先確認 access 未過期，收到 401 則 refresh 後重送一次。
class RefundService {
  static final _httpClient = HttpClientManager();
  // 統一改用 AppConfig（原本硬編碼 IP 172.20.10.14 已移除）
  static String get baseUrl => AppConfig.backendUrl;

  /// 取得可用的 access token；已知過期則先 refresh。回 null = 未登入。
  static Future<String?> _freshToken() async {
    if (ApiService.accessLikelyExpired && ApiService.hasRefreshToken) {
      await ApiService.refreshTokens();
    }
    return ApiService.token;
  }

  /// 執行一次可能因 401 需要重送的請求。
  static Future<http.Response?> _withRetry(
    Future<http.Response> Function(String token) send,
  ) async {
    final token = await _freshToken();
    if (token == null) return null;
    var response = await send(token);
    if (response.statusCode == 401 && ApiService.hasRefreshToken) {
      final ok = await ApiService.refreshTokens();
      if (ok && ApiService.token != null) {
        response = await send(ApiService.token!);
      }
    }
    return response;
  }

  /// 創建退款請求
  ///
  /// 參數：
  /// - tripId: 行程 ID
  /// - reason: 退款原因（至少 10 個字）
  /// - refundAmountSui: 退款金額（SUI）
  /// - evidenceFile: 退款證據文件（選填）
  ///
  /// 返回：成功狀態與退款請求數據
  static Future<Map<String, dynamic>> createRefundRequest({
    required int tripId,
    required String reason,
    required double refundAmountSui,
    File? evidenceFile,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/refunds/create');
      final fileBytes = evidenceFile == null ? null : await evidenceFile.readAsBytes();
      final fileName = evidenceFile?.path.split('/').last;

      // MultipartRequest 不能重複 send，重送時需重建；故包成 closure。
      final response = await _withRetry((token) async {
        final request = http.MultipartRequest('POST', uri);
        request.headers['Authorization'] = 'Bearer $token';
        request.fields['trip_id'] = tripId.toString();
        request.fields['reason'] = reason;
        request.fields['refund_amount_sui'] = refundAmountSui.toString();
        if (fileBytes != null) {
          request.files.add(http.MultipartFile.fromBytes('evidence_file', fileBytes, filename: fileName));
        }
        // MultipartRequest.send() 回傳 StreamedResponse，與 _httpClient.executeRequest 型別不相容
        final streamed = await request.send();
        return http.Response.fromStream(streamed);
      });

      if (response == null) {
        return {'success': false, 'error': '請先登入後再申請退款'};
      }
      if (response.statusCode == 200) {
        return {'success': true, 'data': json.decode(response.body)};
      }
      final error = json.decode(response.body);
      return {'success': false, 'error': error['detail'] ?? '創建退款請求失敗'};
    } catch (e) {
      print('❌ 創建退款請求失敗: $e');
      return {'success': false, 'error': '創建退款請求失敗: $e'};
    }
  }

  /// 獲取用戶的退款請求列表
  ///
  /// 參數：
  /// - limit: 最大返回數量（選填）
  ///
  /// 返回：退款請求列表
  static Future<Map<String, dynamic>> getUserRefunds({int? limit}) async {
    try {
      final queryParams = <String, String>{};
      if (limit != null) queryParams['limit'] = limit.toString();

      final uri = Uri.parse('$baseUrl/refunds/my').replace(
        queryParameters: queryParams.isNotEmpty ? queryParams : null,
      );

      final response = await _withRetry((token) => _httpClient.executeRequest(
            (client) => client.get(uri, headers: {'Authorization': 'Bearer $token'}),
          ));

      if (response == null) {
        return {'success': false, 'error': '請先登入'};
      }
      if (response.statusCode == 200) {
        return {'success': true, 'data': json.decode(response.body)};
      }
      return {'success': false, 'error': '獲取退款列表失敗'};
    } catch (e) {
      print('❌ 獲取退款列表失敗: $e');
      return {'success': false, 'error': '獲取退款列表失敗: $e'};
    }
  }
}
