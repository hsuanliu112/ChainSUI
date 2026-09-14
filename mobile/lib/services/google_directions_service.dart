// mobile/lib/services/google_directions_service.dart

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'http_client_manager.dart';
import '../config/google_maps_config.dart';

class GoogleDirectionsService {
  // HTTP Client 管理器（單例）
  static final _httpClient = HttpClientManager();

  // 統一由 GoogleMapsConfig 單一來源取得（原本硬編碼的金鑰已移除，避免洩漏且好輪替）。
  static String get _apiKey => GoogleMapsConfig.apiKey;
  static const String _baseUrl = 'https://maps.googleapis.com/maps/api/directions/json';

  /// 獲取路線
  static Future<DirectionsResult?> getDirections({
    required LatLng origin,
    required LatLng destination,
  }) async {
    try {
      final uri = Uri.parse(_baseUrl).replace(queryParameters: {
        'origin': '${origin.latitude},${origin.longitude}',
        'destination': '${destination.latitude},${destination.longitude}',
        'key': _apiKey,
        'language': 'zh-TW',
        'mode': 'driving',
      });

      final response = await _httpClient.executeRequest(
        (client) => client.get(uri, headers: GoogleMapsConfig.restrictionHeaders),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['status'] == 'OK' && data['routes'] is List && (data['routes'] as List).isNotEmpty) {
          final route = data['routes'][0];
          return DirectionsResult.fromJson(route);
        } else {
          print('Directions API 錯誤: ${data['status']}');
        }
      }
    } catch (e) {
      print('獲取路線失敗: $e');
    }

    return null;
  }

  /// 解碼 Google 的 polyline 編碼
  static List<LatLng> decodePolyline(String encoded) {
    List<LatLng> points = [];
    int index = 0;
    int len = encoded.length;
    int lat = 0;
    int lng = 0;

    while (index < len) {
      int b;
      int shift = 0;
      int result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      points.add(LatLng(lat / 1E5, lng / 1E5));
    }

    return points;
  }
}

/// 路線結果
class DirectionsResult {
  final List<LatLng> polylinePoints;
  final double distanceMeters;
  final int durationSeconds;
  final String distanceText;
  final String durationText;

  DirectionsResult({
    required this.polylinePoints,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.distanceText,
    required this.durationText,
  });

  factory DirectionsResult.fromJson(Map<String, dynamic> json) {
    final legs = json['legs'] as List;
    final leg = legs[0];

    // 獲取 polyline
    final polyline = json['overview_polyline']['points'] as String;
    final points = GoogleDirectionsService.decodePolyline(polyline);

    return DirectionsResult(
      polylinePoints: points,
      distanceMeters: (leg['distance']['value'] as num).toDouble(),
      durationSeconds: leg['duration']['value'] as int,
      distanceText: leg['distance']['text'] as String,
      durationText: leg['duration']['text'] as String,
    );
  }
}
