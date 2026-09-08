import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';

import 'payment_page.dart';
import 'role_select_page.dart';
import 'services/api_service.dart';
import 'services/google_places_service.dart';
import 'services/websocket_service.dart';
import 'services/price_service.dart';
import 'config/map_config.dart';
import 'session_manager.dart';
import 'trip_history_page.dart';
import 'widgets/google_place_search_field.dart';

class PassengerHomePage extends StatefulWidget {
  const PassengerHomePage({super.key, required this.session});

  final UserSession? session;

  @override
  State<PassengerHomePage> createState() => _PassengerHomePageState();
}

class _PassengerHomePageState extends State<PassengerHomePage> {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  LatLng _userLocation = const LatLng(25.0330, 121.5654); // 預設位置（台北101）
  bool _isLoadingLocation = true;

  // ✅ 移除不再使用的車輛相關變量
  Map<String, dynamic>? _tripEstimate;
  LatLng? _destination;
  String? _destinationAddress;
  Map<String, dynamic>? _activeTrip;
  bool _useDynamicPricing = false; // 用戶選擇的定價方式

  bool _isRequestingRide = false;
  Timer? _pollingTimer;
  String? _statusMessage;
  final WebSocketService _ws = WebSocketService();

  // 🚗 司機位置追蹤與模擬
  LatLng? _driverLocation;
  LatLng? _passengerLocation;
  int? _joinedTripId; // 當前已加入的 WebSocket 行程房間 ID
  bool _tripJustCompleted = false; // 控制流程圖顯示已完成階段
  bool _hasRealDriverUpdates = false; // 是否收到真正的司機位置更新
  Timer? _driverAnimationTimer; // 乘客端模擬車輛移動
  int _driverAnimationIndex = 0;
  int _routeDurationSeconds = 0;
  bool _driverAnimationCompleted = false;
  bool _isCheckingTrip = false; // 避免重複查詢
  bool _awaitingTripDismiss = false; // 乘客是否正在查看完成畫面

  // 🗺️ 路線數據
  List<LatLng> _routePoints = [];
  List<Map<String, dynamic>> _waypoints = [];

  @override
  void initState() {
    super.initState();
    // 🌍 定位延到第一幀畫完後才啟動：iOS 的 locationServicesEnabled 在主執行緒
    // 執行、可能長時間無回應（Apple 文件明載）。在 initState 直接呼叫會讓
    // 第一幀畫不出來 → 整個 app 卡在白色啟動畫面。
    WidgetsBinding.instance.addPostFrameCallback((_) => _getCurrentLocation());
    _checkActiveTrip();
    // ✅ 移除車輛加載 - 不再需要選擇車輛
    _setupWebSocket();
    _passengerLocation = _userLocation;
    _startPolling();
  }

  /// 🌍 獲取當前GPS位置
  Future<void> _getCurrentLocation() async {
    try {
      // 1. 檢查定位服務是否啟用（平台層可能卡住，加 timeout 防整條流程無聲懸掛）
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled()
          .timeout(const Duration(seconds: 8));
      if (!serviceEnabled) {
        print('⚠️ 定位服務未啟用');
        setState(() => _isLoadingLocation = false);
        return;
      }

      // 2. 檢查定位權限
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          print('⚠️ 定位權限被拒絕');
          setState(() => _isLoadingLocation = false);
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        print('⚠️ 定位權限永久被拒絕');
        setState(() => _isLoadingLocation = false);
        return;
      }

      // 3. 獲取當前位置
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      if (!mounted) return;

      setState(() {
        _userLocation = LatLng(position.latitude, position.longitude);
        _passengerLocation = _userLocation;
        _isLoadingLocation = false;
      });

      // 4. 移動地圖到當前位置
      try {
        _mapController.move(_userLocation, 15);
      } catch (e) {
        print('⚠️ 地圖移動失敗: $e');
      }

      print('✅ GPS 定位成功: ${position.latitude}, ${position.longitude}');

      // 5. 開始監聽位置變化（可選）
      _startLocationUpdates();
    } catch (e) {
      print('❌ 獲取GPS位置失敗: $e');
      setState(() => _isLoadingLocation = false);
    }
  }

  StreamSubscription<Position>? _positionStreamSubscription;

  /// 🌍 開始監聽位置變化
  void _startLocationUpdates() {
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10, // 移動10米才更新
    );

    _positionStreamSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen((Position position) {
      if (!mounted) return;

      setState(() {
        _userLocation = LatLng(position.latitude, position.longitude);
        // 只有在沒有進行中的行程時才更新乘客位置
        if (_activeTrip == null) {
          _passengerLocation = _userLocation;
        }
      });

      print('📍 位置更新: ${position.latitude}, ${position.longitude}');
    });
  }

  /// 設置 WebSocket 事件監聽
  void _setupWebSocket() async {
    // 先連接 WebSocket
    await _ws.connect();
    print('🔌 乘客端 WebSocket 連接已初始化');

    // 監聽行程被司機接受
    _ws.on('trip_accepted', (data) {
      print('📨 乘客端收到行程已被接受: $data');
      if (mounted) {
        setState(() {
          _statusMessage = '司機已接單！';
          _tripJustCompleted = false;
        });
        _checkActiveTrip();
      }
    });

    // 監聽行程開始
    _ws.on('trip_started', (data) {
      print('📨 乘客端收到行程已開始: $data');
      if (mounted) {
        setState(() {
          _statusMessage = '行程進行中';
          _tripJustCompleted = false;
          if (_driverLocation != null) {
            _passengerLocation = _driverLocation;
          }
        });
        _maybeStartDriverRouteAnimation();
        _checkActiveTrip();
      }
    });

    // 監聽行程完成
    _ws.on('trip_completed', (data) {
      print('📨 乘客端收到行程已完成: $data');
      if (mounted) {
        setState(() {
          if (_activeTrip != null) {
            _activeTrip!['status'] = 'completed';
          } else {
            _activeTrip = {
              'trip_id': data['trip_id'],
              'status': 'completed',
            };
          }
          _statusMessage = '行程已完成';
          _driverLocation = null;
          final dropoffLatLng = _parseLatLng(
                _activeTrip?['dropoff_lat'],
                _activeTrip?['dropoff_lng'],
              ) ??
              (_routePoints.isNotEmpty ? _routePoints.last : null);
          if (dropoffLatLng != null) {
            _passengerLocation = dropoffLatLng;
          }
          _tripJustCompleted = true;
          _awaitingTripDismiss = true;
        });
        _stopDriverRouteAnimation();
        _checkActiveTrip();
      }
    });

    // 監聽行程取消
    _ws.on('trip_cancelled', (data) {
      print('📨 乘客端收到行程已取消: $data');
      if (mounted) {
        _clearActiveTripState(statusMessage: '行程已取消');

        // 顯示取消通知
        final cancelledBy = data['cancelled_by'] ?? 'unknown';
        final reason = data['reason'] ?? '未提供原因';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              cancelledBy == 'driver'
                  ? '❌ 司機取消了行程\n原因：$reason'
                  : '✓ 行程已取消',
            ),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    });

    // 🚗 監聽司機位置更新
    _ws.on('driver_location_update', (data) {
      print('📍 乘客端收到司機位置更新: $data');
      if (mounted && _activeTrip != null) {
        final lat = data['lat'];
        final lng = data['lng'];

        if (lat != null && lng != null) {
          _hasRealDriverUpdates = true;
          _stopDriverRouteAnimation();
          setState(() {
            _driverLocation = LatLng(
              lat is double ? lat : double.parse(lat.toString()),
              lng is double ? lng : double.parse(lng.toString()),
            );
            if (_isPassengerOnboard) {
              _passengerLocation = _driverLocation;
            }
          });

          // 自動移動地圖跟隨司機位置
          try {
            _mapController.move(_driverLocation!, _mapController.camera.zoom);
          } catch (e) {
            print('⚠️ 地圖移動錯誤: $e');
          }
        }
      }
    });
  }

  void _joinTripRoom(int tripId) async {
    if (_joinedTripId == tripId) {
      return;
    }

    if (_joinedTripId != null) {
      print('🔄 離開上一個行程房間: $_joinedTripId');
      _ws.leaveTrip(_joinedTripId!);
    }

    // 確保 WebSocket 已連接
    if (!_ws.isConnected) {
      print('🔌 WebSocket 未連接，嘗試重新連接...');
      await _ws.connect();

      // 等待連接成功（最多等 5 秒）
      int retries = 0;
      while (!_ws.isConnected && retries < 10) {
        await Future.delayed(const Duration(milliseconds: 500));
        retries++;
        print('🔄 等待 WebSocket 連接... ($retries/10)');
      }

      if (!_ws.isConnected) {
        print('❌ WebSocket 連接失敗，無法加入房間');
        return;
      }
    }

    print('📡 加入乘客行程房間: $tripId');
    _ws.joinTrip(tripId);
    _joinedTripId = tripId;
  }

  void _leaveTripRoom() {
    if (_joinedTripId == null) {
      return;
    }

    print('📡 離開乘客行程房間: $_joinedTripId');
    _ws.leaveTrip(_joinedTripId!);
    _joinedTripId = null;
  }

  String _normalizeStatus(dynamic value) {
    final raw = value?.toString().toLowerCase() ?? '';
    final dotIndex = raw.lastIndexOf('.');
    if (dotIndex >= 0 && dotIndex < raw.length - 1) {
      return raw.substring(dotIndex + 1);
    }
    return raw;
  }

  bool get _isPassengerOnboard {
    final status = _normalizeStatus(_activeTrip?['status']);
    return status == 'picked_up' || status == 'in_progress';
  }

  LatLng? _parseLatLng(dynamic lat, dynamic lng) {
    double? toDouble(dynamic value) {
      if (value is double) return value;
      if (value is int) return value.toDouble();
      if (value is String) return double.tryParse(value);
      return null;
    }

    final parsedLat = toDouble(lat);
    final parsedLng = toDouble(lng);
    if (parsedLat == null || parsedLng == null) {
      return null;
    }
    return LatLng(parsedLat, parsedLng);
  }

  void _clearActiveTripState({String? statusMessage}) {
    setState(() {
      _activeTrip = null;
      _statusMessage = statusMessage;
      _routePoints = [];
      _waypoints = [];
      _driverLocation = null;
      _passengerLocation = _userLocation;
      _tripJustCompleted = false;
      _hasRealDriverUpdates = false;
      _routeDurationSeconds = 0;
      _awaitingTripDismiss = false;
      _driverAnimationCompleted = false;
    });
    _stopDriverRouteAnimation();
    _leaveTripRoom();
  }

  void _dismissCompletedTripView() {
    _clearActiveTripState(statusMessage: null);
  }

  void _stopDriverRouteAnimation() {
    _driverAnimationTimer?.cancel();
    _driverAnimationTimer = null;
    _driverAnimationIndex = 0;
    _driverAnimationCompleted = false;
  }

  void _maybeStartDriverRouteAnimation() {
    if (_routePoints.isEmpty || _hasRealDriverUpdates || _driverAnimationTimer != null || _driverAnimationCompleted) {
      return;
    }

    final status = _normalizeStatus(_activeTrip?['status']);
    // 只有在乘客已上車（picked_up）時才開始模擬動畫
    // 其他狀態（requested, matched, accepted, arrived）都不啟動
    if (status != 'picked_up' && status != 'in_progress') {
      print('🚗 乘客端：等待上車確認，目前狀態: $status');
      return;
    }

    _startDriverRouteAnimation();
  }

  void _startDriverRouteAnimation() {
    if (_routePoints.length < 2) {
      return;
    }

    // 如果已經收到真實的 WebSocket 更新，不要啟動本地動畫
    if (_hasRealDriverUpdates) {
      print('🔄 已收到 WebSocket 位置更新，跳過本地動畫');
      return;
    }

    _stopDriverRouteAnimation();
    _driverAnimationIndex = 0;
    _driverAnimationCompleted = false;

    final totalPoints = _routePoints.length;
    const double speedMultiplier = 1.5; // 1.5倍速（與車主端一致）
    int intervalMs;
    if (_routeDurationSeconds > 0) {
      intervalMs = (_routeDurationSeconds * 1000 / totalPoints / speedMultiplier).round();
    } else {
      intervalMs = (1000 / speedMultiplier).round();
    }
    intervalMs = intervalMs.clamp(200, 1000); // 200-1000ms，更自然的速度

    setState(() {
      _driverLocation = _routePoints.first;
      if (_isPassengerOnboard) {
        _passengerLocation = _driverLocation;
      }
    });

    // 地圖移動到起點
    try {
      _mapController.move(_routePoints.first, _mapController.camera.zoom);
    } catch (e) {
      print('⚠️ 地圖移動錯誤: $e');
    }

    print('🚗 乘客端：啟動本地模擬動畫 (${totalPoints} 個點, 間隔 ${intervalMs}ms)');

    _driverAnimationTimer = Timer.periodic(Duration(milliseconds: intervalMs), (timer) {
      if (_hasRealDriverUpdates || _tripJustCompleted || _activeTrip == null) {
        timer.cancel();
        _driverAnimationTimer = null;
        _driverAnimationCompleted = _tripJustCompleted;
        return;
      }

      if (_driverAnimationIndex >= totalPoints - 1) {
        timer.cancel();
        _driverAnimationTimer = null;
        _driverAnimationCompleted = true;
        setState(() {
          _driverLocation = _routePoints.last;
          if (_isPassengerOnboard) {
            _passengerLocation = _driverLocation;
          }
        });
        // 地圖跟隨車輛到終點
        try {
          _mapController.move(_routePoints.last, _mapController.camera.zoom);
        } catch (e) {
          print('⚠️ 地圖移動錯誤: $e');
        }
        return;
      }

      _driverAnimationIndex++;
      setState(() {
        _driverLocation = _routePoints[_driverAnimationIndex];
        if (_isPassengerOnboard) {
          _passengerLocation = _driverLocation;
        }
      });

      // 地圖跟隨車輛移動
      try {
        _mapController.move(_routePoints[_driverAnimationIndex], _mapController.camera.zoom);
      } catch (e) {
        print('⚠️ 地圖移動錯誤: $e');
      }
    });
  }

  void _startPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted) return;
      // 如果沒有活躍行程且沒有等待關閉的完成畫面，跳過檢查
      if (_activeTrip == null && !_tripJustCompleted && !_awaitingTripDismiss) {
        return;
      }
      // 如果正在等待用戶關閉完成畫面，不要輪詢檢查（避免被強制退出房間）
      if (_awaitingTripDismiss) {
        return;
      }
      _checkActiveTrip();
    });
  }

  void _syncPassengerWithDriver() {
    LatLng? target = _driverLocation;
    if (target == null && _routePoints.isNotEmpty) {
      target = _routePoints[_driverAnimationIndex.clamp(0, _routePoints.length - 1)];
    }
    if (target != null) {
      setState(() {
        _passengerLocation = target;
      });
    }
  }

  /// 載入行程路線數據
  Future<void> _loadTripRoute(int tripId) async {
    print('🗺️ 載入行程 $tripId 的路線...');

    try {
      final result = await ApiService.getTripRoute(tripId);

      if (!mounted) return;

      // 提取實際數據（被 _wrapResponse 包裝過）
      final data = result['data'] as Map<String, dynamic>?;

      if (result['success'] == true && data != null && data['route_points'] != null) {
        final routePointsData = data['route_points'] as List;
        final routePoints = routePointsData
            .map((p) => LatLng(p['lat'] as double, p['lng'] as double))
            .toList();

        final waypointsData = data['waypoints'] as List? ?? [];

        final durationSeconds = (data['duration_seconds'] ?? 0).toInt();

        setState(() {
          _routePoints = routePoints;
          _waypoints = waypointsData.cast<Map<String, dynamic>>();
          _routeDurationSeconds = durationSeconds;
          if (!_isPassengerOnboard) {
            final pickupLatLng = _parseLatLng(_activeTrip?['pickup_lat'], _activeTrip?['pickup_lng']);
            _passengerLocation = pickupLatLng ?? _routePoints.first;
          }
        });

        print('✅ 路線載入成功: ${routePoints.length} 個點, ${waypointsData.length} 個停靠點');

        // 調整地圖視角以顯示完整路線
        if (routePoints.isNotEmpty) {
          try {
            _mapController.move(routePoints.first, 13);
          } catch (e) {
            print('⚠️ 地圖移動失敗: $e');
          }
        }

        _maybeStartDriverRouteAnimation();
      } else {
        // 更詳細的錯誤信息
        final statusCode = result['statusCode'];
        final error = result['error'] ?? result['data']?['detail'] ?? '未知錯誤';
        print('❌ 路線載入失敗 (狀態碼 $statusCode): $error');

        // 如果是權限問題，使用備用直線路線
        if (statusCode == 401 || statusCode == 403) {
          print('⚠️ 權限不足，無法獲取詳細路線');
        }
      }
    } catch (e) {
      print('❌ 路線載入錯誤: $e');
    }
  }

  Future<void> _checkActiveTrip() async {
    if (_isCheckingTrip) return;
    _isCheckingTrip = true;
    if (_session == null) {
      _isCheckingTrip = false;
      return;
    }

    try {
      print('🔍 檢查進行中的行程...');

      final result = await ApiService.getUserTrips(limit: 10);

      if (!mounted) return;
      final previousTripId = _activeTrip?['trip_id'];

      if (result['success'] == true && result['data'] is List) {
        final trips = result['data'] as List;
        print('📋 找到 ${trips.length} 個行程');

        Map<String, dynamic>? detectedTrip;
        for (var trip in trips) {
          final status = _normalizeStatus(trip['status']);
          print('  - 行程 ${trip['trip_id']}: 狀態 = $status');

          // 只檢查真正「進行中」的狀態，不包含 completed
          if (status == 'requested' ||
              status == 'matched' ||
              status == 'accepted' ||
              status == 'picked_up' ||
              status == 'in_progress') {
            detectedTrip = Map<String, dynamic>.from(trip as Map<String, dynamic>);
            final tripId = detectedTrip['trip_id'];
            print('✅ 找到進行中的行程: $tripId');
            break;
          }
        }

        if (!mounted) return;

        if (detectedTrip != null) {
          final hasActiveTrip = _activeTrip != null;
          final tripData = Map<String, dynamic>.from(detectedTrip);
          final status = _normalizeStatus(tripData['status']);
          final tripId = tripData['trip_id'] as int;
          final bool isNewTrip = previousTripId == null || previousTripId != tripId;
          final pickupLatLng = _parseLatLng(tripData['pickup_lat'], tripData['pickup_lng']);

          setState(() {
            _activeTrip = tripData;
            _statusMessage = '您有進行中的行程（狀態：$status）';
            _tripJustCompleted = status == 'completed' || _tripJustCompleted;
            if (status == 'completed') {
              _awaitingTripDismiss = true;
            }
            if (isNewTrip) {
              _hasRealDriverUpdates = false;
              _driverLocation = null;
              if (status == 'completed') {
                final dropoffLatLng = _parseLatLng(
                      tripData['dropoff_lat'],
                      tripData['dropoff_lng'],
                    ) ??
                    (_routePoints.isNotEmpty ? _routePoints.last : null);
                _passengerLocation = dropoffLatLng ?? _userLocation;
              } else {
                _passengerLocation = pickupLatLng ?? _userLocation;
              }
            } else if (status == 'completed') {
              final dropoffLatLng = _parseLatLng(
                tripData['dropoff_lat'],
                tripData['dropoff_lng'],
              );
              if (dropoffLatLng != null) {
                _passengerLocation = dropoffLatLng;
              }
            }
          });

          if (isNewTrip) {
            _stopDriverRouteAnimation();
          }

          _joinTripRoom(tripId);
          await _loadTripRoute(tripId);
        } else if (!_awaitingTripDismiss) {
          print('❌ 沒有進行中的行程');
          _clearActiveTripState(statusMessage: null);
        }
      } else {
        print('❌ 獲取行程失敗: ${result['error']}');
      }
    } finally {
      _isCheckingTrip = false;
    }
  }

  Future<void> _cancelActiveTrip() async {
    if (_activeTrip == null) return;

    final tripId = _activeTrip!['trip_id'];
    final status = _normalizeStatus(_activeTrip!['status']);

    // 乘客上車後（picked_up 或 in_progress）不允許取消行程
    if (status == 'picked_up' || status == 'in_progress') {
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF2E2E2E),
          title: const Row(
            children: [
              Icon(Icons.block, color: Colors.red),
              SizedBox(width: 8),
              Text('無法取消', style: TextStyle(color: Colors.white)),
            ],
          ),
          content: const Text(
            '行程已開始，無法取消。\n\n'
            '請完成行程並付款後，如有服務問題可申請退款。',
            style: TextStyle(color: Colors.white70, fontSize: 15),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('我知道了'),
            ),
          ],
        ),
      );
      return;
    }

    // 根據行程狀態決定提示訊息
    String warningMessage;
    if (status == 'accepted' || status == 'arrived') {
      warningMessage = '車輛已派遣，取消後將全額退款。';
    } else {
      warningMessage = '確定要取消當前行程嗎？';
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF2E2E2E),
            title: const Text('取消行程', style: TextStyle(color: Colors.white)),
            content: Text(
              warningMessage,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('返回'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('確認取消'),
              ),
            ],
          ),
    );

    if (confirmed != true) return;

    setState(() => _statusMessage = '正在取消行程...');

    final result = await ApiService.cancelTrip(
      tripId: tripId,
      reason: '乘客取消',
      cancelledBy: 'passenger',
    );

    if (!mounted) return;

    if (result['success'] == true) {
      _clearActiveTripState(statusMessage: '行程已取消');
    } else {
      setState(() {
        _statusMessage = '取消失敗：${result['error']}';
      });
    }
  }

  /// 乘客確認上車（自駕車到達後）
  Future<void> _confirmPickup() async {
    if (_activeTrip == null) return;

    final tripId = _activeTrip!['trip_id'];

    setState(() => _statusMessage = '正在確認上車...');

    final result = await ApiService.pickupPassenger(tripId);

    if (!mounted) return;

    if (result['success'] == true) {
      setState(() {
        if (_activeTrip != null) {
          _activeTrip!['status'] = 'picked_up';
        }
        _statusMessage = '已確認上車，行程開始';
      });
      _syncPassengerWithDriver();
      _maybeStartDriverRouteAnimation();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ 已確認上車，行程開始'),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      setState(() {
        _statusMessage = '確認失敗：${result['error']}';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ 確認上車失敗: ${result['error']}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _searchController.dispose();
    _positionStreamSubscription?.cancel(); // 🌍 取消位置監聽
    // 移除 WebSocket 監聽器
    _ws.off('trip_accepted');
    _ws.off('trip_started');
    _ws.off('trip_completed');
    _ws.off('trip_cancelled');
    _ws.off('driver_location_update');
    _stopDriverRouteAnimation();
    _leaveTripRoom();
    super.dispose();
  }

  UserSession? get _session => widget.session;

  // ✅ 移除車輛加載方法 - 不再需要選擇車輛

  Future<void> _loadTripEstimate() async {
    if (_destination == null) return;
    setState(() {
      _statusMessage = '計算預估車資...';
    });

    final result = await ApiService.getTripEstimate(
      pickupLat: _userLocation.latitude,
      pickupLng: _userLocation.longitude,
      dropoffLat: _destination!.latitude,
      dropoffLng: _destination!.longitude,
    );

    if (!mounted) return;

    // 調試信息
    print('=== 費用預估 API 響應 ===');
    print('Success: ${result['success']}');
    print('Data: ${result['data']}');
    print('Error: ${result['error']}');

    setState(() {
      if (result['success'] == true && result['data'] is Map) {
        _tripEstimate = result['data'] as Map<String, dynamic>;
        print('費用預估數據: $_tripEstimate');
        _statusMessage = '預估車資已更新';
      } else {
        _tripEstimate = null;
        _statusMessage = result['error']?.toString() ?? '無法取得預估資訊';
      }
    });
  }

  Future<void> _requestRide() async {
    // 檢查是否有進行中的行程
    if (_activeTrip != null) {
      setState(() => _statusMessage = '您已有進行中的行程，請先完成或取消');
      return;
    }

    // ✅ 移除車輛選擇要求，配對系統會自動找司機
    if (_session == null || _destination == null) {
      setState(() => _statusMessage = '請先選擇目的地');
      return;
    }

    setState(() {
      _isRequestingRide = true;
      _statusMessage = '發送叫車請求...';
    });

    final result = await ApiService.createTripRequest(
      pickupLat: _userLocation.latitude,
      pickupLng: _userLocation.longitude,
      pickupAddress: '當前位置',
      dropoffLat: _destination!.latitude,
      dropoffLng: _destination!.longitude,
      dropoffAddress: _destinationAddress ?? _searchController.text,
      passengerCount: 1,
      useDynamicPricing: _useDynamicPricing,
      preferredVehicleType: null, // ✅ 不再需要選擇車輛
      notes: 'AutoDrive 乘客端叫車',
    );

    if (!mounted) return;

    setState(() {
      _isRequestingRide = false;
    });

    if (result['success'] == true && result['data'] is Map) {
      final trip = result['data'] as Map<String, dynamic>;
      final pickupLatLng = _parseLatLng(trip['pickup_lat'], trip['pickup_lng']);
      setState(() {
        _activeTrip = trip;
        _statusMessage = '叫車成功！行程 ID: ${trip['trip_id']}';
        _tripJustCompleted = false;
        _hasRealDriverUpdates = false;
        _routePoints = [];
        _waypoints = [];
        _driverLocation = null;
        _passengerLocation = pickupLatLng ?? _userLocation;
      });
      _stopDriverRouteAnimation();

      final tripId = (trip['trip_id'] is int)
          ? trip['trip_id'] as int
          : int.tryParse(trip['trip_id']?.toString() ?? '');
      if (tripId != null) {
        _joinTripRoom(tripId);
      }

      // 獲取費用（根據用戶選擇的定價方式）
      int? fareAmount;
      if (_tripEstimate != null) {
        if (_useDynamicPricing && _tripEstimate!['dynamic_fare'] is Map) {
          // 使用動態定價
          fareAmount = _tripEstimate!['dynamic_fare']['total_amount'] as int?;
        } else if (_tripEstimate!['standard_fare'] is Map) {
          // 使用標準定價
          fareAmount = _tripEstimate!['standard_fare']['total_amount'] as int?;
        }
      }
      fareAmount ??= trip['fare'] as int?;
      
      print('💰 傳遞給支付頁面的費用: $fareAmount micro SUI');

      Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) => PaymentPage(
                session: _session,
                tripId: trip['trip_id'],
                fare: fareAmount,
                startAddress: trip['pickup_address'] ?? '當前位置',
                endAddress:
                    trip['dropoff_address'] ??
                    _destinationAddress ??
                    _searchController.text,
                vehicleId: null, // ✅ 不再需要車輛 ID
              ),
        ),
      ).then((_) {
        // 從支付頁面返回後重新檢查行程狀態
        _checkActiveTrip();
      });
    } else {
      setState(() {
        _statusMessage =
            result['data']?['detail']?.toString() ??
            result['error']?.toString() ??
            '叫車失敗';
      });
    }
  }

  void _goToPayment() {
    if (_activeTrip == null) return;

    final trip = _activeTrip!;

    // 三層金額檢測邏輯：將金額轉換為 MIST 格式傳給支付頁面
    int? fareAmountMist;
    final rawFare = trip['fare'] ?? trip['total_amount'];

    if (rawFare is num) {
      if (rawFare > 100000000) {
        // 已經是 MIST 格式
        fareAmountMist = rawFare.toInt();
        print('💰 金額格式：MIST (> 100M) - $rawFare');
      } else if (rawFare > 1000) {
        // 錯誤的中間格式，需要轉換為 MIST
        fareAmountMist = (rawFare * 1000).toInt();
        print('💰 金額格式：中間格式 (> 1000) - $rawFare -> $fareAmountMist MIST');
      } else {
        // SUI 格式，轉換為 MIST
        fareAmountMist = (rawFare * 1000000000).toInt();
        print('💰 金額格式：SUI (< 1000) - $rawFare -> $fareAmountMist MIST');
      }
    }

    // 獲取司機錢包地址（如果有）
    String? driverWallet = trip['driver_wallet'];

    // 如果沒有司機錢包地址，嘗試從 driver_info 中獲取
    if (driverWallet == null && trip['driver_info'] != null) {
      driverWallet = trip['driver_info']['wallet_address'];
    }

    print('💼 司機錢包地址: ${driverWallet ?? "未提供"}');

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PaymentPage(
          session: _session,
          tripId: trip['trip_id'],
          fare: fareAmountMist,
          startAddress: trip['pickup_address'] ?? '當前位置',
          endAddress: trip['dropoff_address'] ?? '目的地',
          vehicleId: trip['vehicle_id'],
          driverWallet: driverWallet,
        ),
      ),
    ).then((_) {
      // 從支付頁面返回後重新檢查行程狀態
      _checkActiveTrip();
    });
  }

  void _openTripHistory() {
    if (_session == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TripHistoryPage(session: _session)),
    );
  }

  void _openProfile() {
    Navigator.pushNamed(context, '/profile', arguments: {'session': _session});
  }

  /// 錢包餘額 + 一鍵領測試幣（付款用的是乘客自己的 SUI，先確保有餘額）
  Future<void> _showWalletSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => _WalletSheet(),
    );
  }

  /// 登出並返回角色選擇頁面
  Future<void> _handleLogout() async {
    // 顯示確認對話框
    final confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: const Text('確認登出', style: TextStyle(color: Colors.white)),
          content: const Text(
            '確定要登出嗎？您可以重新選擇身份登入。',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('登出', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    // 清除 Session
    await SessionManager.clearSession();
    ApiService.clearToken();

    // 斷開 WebSocket 連接
    _ws.disconnect();

    if (!mounted) return;

    // 使用 pushAndRemoveUntil 清空導航堆疊並返回角色選擇頁面
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const RoleSelectPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_session == null) {
      return Scaffold(
        backgroundColor: const Color(0xFF121212),
        body: Center(
          child: ElevatedButton(
            onPressed:
                () => Navigator.pushReplacementNamed(context, '/role_select'),
            child: const Text('請先登入'),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false, // 移除左上角的返回按鈕
        title: const Text('乘客首頁'),
        actions: [
          if (_activeTrip != null)
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF1DB954),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.local_taxi, size: 16, color: Colors.black),
                  const SizedBox(width: 4),
                  Text(
                    '進行中',
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '行程紀錄',
            onPressed: _openTripHistory,
          ),
          IconButton(
            icon: const Icon(Icons.person),
            tooltip: '個人檔案',
            onPressed: _openProfile,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: '更多選項',
            onSelected: (value) {
              if (value == 'logout') {
                _handleLogout();
              } else if (value == 'delegation') {
                Navigator.pushNamed(context, '/delegation');
              } else if (value == 'wallet') {
                _showWalletSheet();
              }
            },
            itemBuilder: (BuildContext context) => [
              const PopupMenuItem<String>(
                value: 'wallet',
                child: Row(
                  children: [
                    Icon(Icons.account_balance_wallet, color: Color(0xFF1DB954)),
                    SizedBox(width: 8),
                    Text('錢包餘額 / 領測試幣'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'delegation',
                child: Row(
                  children: [
                    Icon(Icons.smart_toy, color: Color(0xFF7C3AED)),
                    SizedBox(width: 8),
                    Text('Agent 自動結算'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout, color: Colors.red),
                    SizedBox(width: 8),
                    Text('登出 / 切換身份', style: TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _userLocation,
                initialZoom: 13,
                onTap: (tapPosition, point) async {
                  // 使用反向地理編碼獲取地址
                  final address = await GooglePlacesService.reverseGeocode(
                    point,
                  );

                  setState(() {
                    _destination = point;
                    _destinationAddress = address ?? '未知地址';
                    _tripEstimate = null;
                    // 更新搜尋框顯示地址
                    if (address != null) {
                      _searchController.text = address;
                    }
                  });
                  _loadTripEstimate();
                },
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      MapConfig.darkTileUrl,
                  userAgentPackageName: 'com.autodrive.app',
                  // 使用默認的 NetworkTileProvider，不傳遞 httpClient
                ),
                // 🗺️ 路線顯示
                if (_routePoints.isNotEmpty)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _routePoints,
                        color: Colors.blue,
                        strokeWidth: 4,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    // 黃色乘客圖標：未上車時顯示在上車點，完成時顯示在目的地
                    if (!_isPassengerOnboard || _normalizeStatus(_activeTrip?['status']) == 'completed')
                      Marker(
                        point: () {
                          // 如果行程已完成，顯示在目的地
                          if (_normalizeStatus(_activeTrip?['status']) == 'completed') {
                            final dropoffLatLng = _parseLatLng(
                              _activeTrip?['dropoff_lat'],
                              _activeTrip?['dropoff_lng'],
                            );
                            return dropoffLatLng ?? (_routePoints.isNotEmpty ? _routePoints.last : _userLocation);
                          }
                          // 否則顯示在當前乘客位置（上車點）
                          return _passengerLocation ?? _userLocation;
                        }(),
                        width: 40,
                        height: 40,
                        child: const Icon(
                          Icons.person_pin_circle,
                          color: Colors.amber,
                          size: 32,
                        ),
                      ),
                    if (_destination != null)
                      Marker(
                        point: _destination!,
                        width: 36,
                        height: 36,
                        child: const Icon(
                          Icons.flag,
                          color: Colors.greenAccent,
                          size: 28,
                        ),
                      ),
                    // 🗺️ 停靠點標記
                    if (_waypoints.isNotEmpty)
                      ..._waypoints.map((waypoint) {
                        final wpLat = waypoint['lat'] as double;
                        final wpLng = waypoint['lng'] as double;
                        final sequence = waypoint['sequence'] as int;

                        return Marker(
                          point: LatLng(wpLat, wpLng),
                          width: 40,
                          height: 40,
                          child: Column(
                            children: [
                              Container(
                                width: 24,
                                height: 24,
                                decoration: const BoxDecoration(
                                  color: Colors.orange,
                                  shape: BoxShape.circle,
                                ),
                                child: Center(
                                  child: Text(
                                    '$sequence',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                              const Icon(
                                Icons.location_on,
                                color: Colors.orange,
                                size: 16,
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    // 🚗 顯示司機位置（行程進行中時）
                    if (_driverLocation != null)
                      Marker(
                        point: _driverLocation!,
                        width: 44,
                        height: 44,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.blue.withOpacity(0.2),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.directions_car,
                            color: Colors.blue,
                            size: 32,
                          ),
                        ),
                      ),
                    // ✅ 移除車輛標記 - 不再顯示附近車輛
                  ],
                ),
              ],
            ),
          ),
          _buildBottomSheet(),
        ],
      ),
    );
  }

  Widget _buildBottomSheet() {
    // 如果有進行中的行程，顯示行程狀態
    if (_activeTrip != null) {
      final status = _normalizeStatus(_activeTrip?['status'] ?? 'requested');
      final bool isCompleted = status == 'completed';

      // 定義狀態映射
      String getStatusText(String status) {
        switch (status) {
          case 'requested':
            return '🔍 等待配對車輛...';
          case 'matched':
            return '🚗 車輛已配對';
          case 'accepted':
            return '✅ 車輛已到達，請確認上車';
          case 'in_progress':
            return '🚗 前往目的地中';
          case 'picked_up':
            return '🎯 行程進行中';
          case 'completed':
            return '✅ 行程已完成';
          default:
            return '行程狀態：$status';
        }
      }

      // 計算進度（0-4 步驟）
      int getProgressStep(String status) {
        switch (status) {
          case 'requested':
            return 0;
          case 'matched':
          case 'accepted':
            return 1;
          case 'in_progress':
            return 2;
          case 'picked_up':
            return 3;
          case 'completed':
            return 4;
          default:
            return 0;
        }
      }

      final currentStep = getProgressStep(status);

      return Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.45,
        ),
        decoration: const BoxDecoration(
          color: Color(0xFF1E1E1E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          boxShadow: [
            BoxShadow(
              color: Colors.black45,
              blurRadius: 10,
              offset: Offset(0, -3),
            ),
          ],
        ),
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.local_taxi,
                    color: Color(0xFF1DB954),
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '進行中的行程',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          getStatusText(status),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // 🔥 行程進度指示器
              _buildTripProgressIndicator(currentStep),

              const SizedBox(height: 16),

              // 🗺️ 查看地圖按鈕（顯示行程路線和司機位置）
              if (status != 'requested')
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => _showTripMapDialog(),
                      icon: const Icon(Icons.map, color: Colors.white),
                      label: const Text(
                        '查看行程地圖',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1DB954),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ),

            // 如果行程狀態是 accepted，顯示確認上車按鈕（自駕車到達）
            if (status == 'accepted')
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _confirmPickup,
                    icon: const Icon(Icons.check_circle, color: Colors.white),
                    label: const Text(
                      '確認上車（車輛已到達）',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1DB954),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ),

            // 如果行程狀態是 picked_up，顯示支付按鈕
            if (status == 'picked_up')
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _goToPayment,
                    icon: const Icon(Icons.payment, color: Colors.white),
                    label: const Text(
                      '前往支付',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ),
            if (isCompleted)
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _openTripHistory,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1DB954),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        '查看行程歷史',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        _awaitingTripDismiss = false;
                        _dismissCompletedTripView();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueGrey.shade600,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        '完成',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _openTripHistory,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1DB954),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        '查看詳情',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // 上車後不顯示取消按鈕
                  if (!_isPassengerOnboard)
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _cancelActiveTrip,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red.shade700,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text(
                          '取消行程',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

    // 正常的叫車界面
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1E1E1E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          boxShadow: [
            BoxShadow(
              color: Colors.black45,
              blurRadius: 10,
              offset: Offset(0, -3),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GooglePlaceSearchField(
              controller: _searchController,
              hintText: '搜尋目的地',
              userLocation: _userLocation,
              onPlaceSelected: (coordinates, address) {
                setState(() {
                  _destination = coordinates;
                  _destinationAddress = address;
                  _tripEstimate = null;
                });
                _mapController.move(coordinates, 15);
                _loadTripEstimate();
              },
            ),
            const SizedBox(height: 6),
            if (_tripEstimate != null)
              _TripEstimateView(
                estimate: _tripEstimate!,
                selectedDynamic: _useDynamicPricing,
                onPricingSelected: (isDynamic) {
                  setState(() {
                    _useDynamicPricing = isDynamic;
                  });
                },
              ),
            if (_statusMessage != null && _tripEstimate == null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _statusMessage!,
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const SizedBox(height: 6),
            // ✅ 移除車輛選擇 UI - 配對系統會自動找司機
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed:
                        (_isRequestingRide || _destination == null)
                            ? null
                            : _requestRide,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1DB954),
                      foregroundColor: Colors.black,
                      disabledBackgroundColor: Colors.grey.shade700,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child:
                        _isRequestingRide
                            ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(
                                color: Colors.black,
                                strokeWidth: 2,
                              ),
                            )
                            : const Text(
                              '叫車',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                  ),
                ),
                // ✅ 移除刷新車輛按鈕 - 不再需要選擇車輛
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 🗺️ 顯示行程地圖對話框
  Future<void> _showTripMapDialog() async {
    if (_activeTrip == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('❌ 無法載入行程資訊'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // 🔥 先獲取完整的行程詳情（包含座標）
    final tripId = _activeTrip!['trip_id'];
    print('🗺️ 獲取行程詳情以顯示地圖: Trip ID $tripId');

    final detailResult = await ApiService.getTripDetails(tripId);

    if (!mounted) return;

    if (detailResult['success'] != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ 無法載入行程詳情: ${detailResult['error']}'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final tripDetail = detailResult['data'] as Map<String, dynamic>;
    print('🗺️ 行程詳情: ${tripDetail.keys}');

    final pickupLat = tripDetail['pickup_lat'];
    final pickupLng = tripDetail['pickup_lng'];
    final dropoffLat = tripDetail['dropoff_lat'];
    final dropoffLng = tripDetail['dropoff_lng'];

    print('🗺️ 座標資料 - pickup: ($pickupLat, $pickupLng), dropoff: ($dropoffLat, $dropoffLng)');

    if (pickupLat == null || pickupLng == null || dropoffLat == null || dropoffLng == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('❌ 行程座標資料不完整，無法顯示地圖'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final pickupPoint = LatLng(pickupLat.toDouble(), pickupLng.toDouble());
    final dropoffPoint = LatLng(dropoffLat.toDouble(), dropoffLng.toDouble());

    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(10),
        child: Container(
          height: MediaQuery.of(context).size.height * 0.8,
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            children: [
              // 標題欄
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.map, color: Color(0xFF1DB954)),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        '行程地圖',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, color: Colors.white70),
                    ),
                  ],
                ),
              ),
              // 地圖
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(18)),
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: pickupPoint,
                      initialZoom: 13.0,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: MapConfig.darkTileUrl,
                        userAgentPackageName: 'com.autodrive.app',
                      ),
                      // 標記層
                      MarkerLayer(
                        markers: [
                          // 起點標記
                          Marker(
                            point: pickupPoint,
                            width: 40,
                            height: 40,
                            child: const Icon(
                              Icons.location_on,
                              color: Color(0xFF1DB954),
                              size: 40,
                            ),
                          ),
                          // 終點標記
                          Marker(
                            point: dropoffPoint,
                            width: 40,
                            height: 40,
                            child: const Icon(
                              Icons.flag,
                              color: Colors.red,
                              size: 40,
                            ),
                          ),
                          // 司機位置標記（如果有）
                          if (_driverLocation != null)
                            Marker(
                              point: _driverLocation!,
                              width: 50,
                              height: 50,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.blue,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 3),
                                ),
                                child: const Icon(
                                  Icons.local_taxi,
                                  color: Colors.white,
                                  size: 25,
                                ),
                              ),
                            ),
                        ],
                      ),
                      // 路線層（起點到終點的直線）
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: [pickupPoint, dropoffPoint],
                            strokeWidth: 4.0,
                            color: const Color(0xFF1DB954),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 🔥 行程進度指示器
  Widget _buildTripProgressIndicator(int currentStep) {
    final steps = [
      {'icon': Icons.search, 'label': '等待接單'},
      {'icon': Icons.check_circle, 'label': '司機已接'},
      {'icon': Icons.directions_car, 'label': '前往中'},
      {'icon': Icons.person, 'label': '行程中'},
      {'icon': Icons.flag, 'label': '已完成'},
    ];

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(steps.length, (index) {
            final isActive = index <= currentStep;
            final step = steps[index];

            return Expanded(
              child: Column(
                children: [
                  // 圖標
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isActive
                          ? const Color(0xFF1DB954)
                          : Colors.grey.shade700,
                    ),
                    child: Icon(
                      step['icon'] as IconData,
                      color: isActive ? Colors.black : Colors.white54,
                      size: 18,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // 標籤
                  Text(
                    step['label'] as String,
                    style: TextStyle(
                      color: isActive ? Colors.white : Colors.white38,
                      fontSize: 10,
                      fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }),
        ),
        const SizedBox(height: 8),
        // 進度條
        LinearProgressIndicator(
          value: currentStep / (steps.length - 1),
          backgroundColor: Colors.grey.shade700,
          valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF1DB954)),
          minHeight: 4,
        ),
      ],
    );
  }
}

class _TripEstimateView extends StatelessWidget {
  const _TripEstimateView({
    required this.estimate,
    required this.selectedDynamic,
    required this.onPricingSelected,
  });

  final Map<String, dynamic> estimate;
  final bool selectedDynamic;
  final Function(bool) onPricingSelected;

  Widget _buildFareDisplay(dynamic fareData, {TextStyle? style}) {
    if (fareData == null) {
      return Text('--', style: style);
    }

    double? suiAmount;

    // 如果是 TripFareBreakdown 對象
    if (fareData is Map<String, dynamic>) {
      final totalAmount = fareData['total_amount'];
      if (totalAmount != null) {
        // 從 MIST 轉換為 SUI (除以 1,000,000,000)
        suiAmount = totalAmount / 1000000000.0;
      }
    }

    // 如果是數字
    if (fareData is num) {
      suiAmount = fareData / 1000000000.0;
    }

    if (suiAmount == null) {
      return Text(fareData.toString(), style: style);
    }

    // 使用 FutureBuilder 顯示雙幣種
    return FutureBuilder<String>(
      future: PriceService.formatDualCurrency(suiAmount),
      builder: (context, snapshot) {
        return Text(
          snapshot.data ?? '${suiAmount?.toStringAsFixed(4) ?? '--'} SUI',
          style: style,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final eta = estimate['estimated_duration_minutes'];
    final distance = estimate['estimated_distance_km'];
    final standardFare = estimate['standard_fare'];
    final dynamicFare = estimate['dynamic_fare'];
    final hasSurge = estimate['has_surge'] ?? false;
    final surgeInfo = estimate['surge_info'] as Map<String, dynamic>?;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 行程資訊
        Row(
          children: [
            if (distance != null) ...[
              const Icon(Icons.straighten, color: Colors.white70, size: 14),
              const SizedBox(width: 4),
              Text(
                '${distance.toStringAsFixed(1)} km',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
              const SizedBox(width: 12),
            ],
            if (eta != null) ...[
              const Icon(Icons.access_time, color: Colors.white70, size: 14),
              const SizedBox(width: 4),
              Text(
                '約 $eta 分鐘',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),

        // 標準叫車選項
        GestureDetector(
          onTap: () => onPricingSelected(false),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: !selectedDynamic ? const Color(0xFF1DB954) : const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: !selectedDynamic ? Colors.white : Colors.transparent,
                width: 2,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.local_taxi,
                  color: !selectedDynamic ? Colors.black : Colors.white70,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '標準叫車',
                        style: TextStyle(
                          color: !selectedDynamic ? Colors.black : Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '固定價格',
                        style: TextStyle(
                          color: !selectedDynamic ? Colors.black87 : Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                _buildFareDisplay(
                  standardFare,
                  style: TextStyle(
                    color: !selectedDynamic ? Colors.black : Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),

        // 快速叫車選項（動態定價）
        GestureDetector(
          onTap: () => onPricingSelected(true),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: selectedDynamic ? const Color(0xFF1DB954) : const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selectedDynamic ? Colors.white : Colors.transparent,
                width: 2,
              ),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.flash_on,
                      color: selectedDynamic ? Colors.black : const Color(0xFFFFB84D),
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '快速叫車',
                            style: TextStyle(
                              color: selectedDynamic ? Colors.black : Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            hasSurge ? '優先媒合 • 動態定價' : '優先媒合',
                            style: TextStyle(
                              color: selectedDynamic ? Colors.black87 : Colors.white70,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _buildFareDisplay(
                      dynamicFare,
                      style: TextStyle(
                        color: selectedDynamic ? Colors.black : Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                if (hasSurge && surgeInfo != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: selectedDynamic
                          ? Colors.black.withOpacity(0.2)
                          : const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 14,
                          color: selectedDynamic ? Colors.black87 : const Color(0xFFFFB84D),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            surgeInfo['reason'] ?? '需求較高',
                            style: TextStyle(
                              color: selectedDynamic ? Colors.black87 : Colors.white70,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _VehicleChip extends StatelessWidget {
  const _VehicleChip({
    required this.vehicle,
    required this.selected,
    required this.onTap,
  });

  final Map<String, dynamic> vehicle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final model = vehicle['model']?.toString() ?? '未知車輛';
    final distance = vehicle['distance_km'];
    final eta = vehicle['estimated_arrival_minutes'];

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 135,
        height: 65,
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1DB954) : const Color(0xFF2E2E2E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? Colors.white : Colors.transparent,
            width: 2,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              model,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? Colors.black : Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
            if (distance != null) ...[
              const SizedBox(height: 2),
              Text(
                '${distance.toStringAsFixed(1)} km',
                style: TextStyle(
                  color: selected ? Colors.black87 : Colors.white70,
                  fontSize: 10,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (eta != null) ...[
              const SizedBox(height: 1),
              Text(
                '約 $eta 分',
                style: TextStyle(
                  color: selected ? Colors.black87 : Colors.white54,
                  fontSize: 10,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 錢包餘額 + 一鍵領測試幣底部面板。
/// 付款用的是乘客自己的 zkLogin 錢包 SUI，這裡讓乘客先查餘額、不足時領測試幣（testnet）。
class _WalletSheet extends StatefulWidget {
  @override
  State<_WalletSheet> createState() => _WalletSheetState();
}

class _WalletSheetState extends State<_WalletSheet> {
  bool _loading = true;
  bool _fauceting = false;
  double? _balanceSui;
  String? _address;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadBalance();
  }

  Future<void> _loadBalance() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await ApiService.getWalletBalance();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res['success'] == true) {
        final data = res['data'] ?? res;
        _balanceSui = (data['balance_sui'] is num)
            ? (data['balance_sui'] as num).toDouble()
            : double.tryParse('${data['balance_sui'] ?? ''}');
        _address = data['address'] as String?;
      } else {
        _error = res['error']?.toString() ?? '查詢餘額失敗';
      }
    });
  }

  Future<void> _faucet() async {
    setState(() => _fauceting = true);
    final res = await ApiService.requestFaucet();
    if (!mounted) return;
    setState(() => _fauceting = false);
    final ok = res['success'] == true;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? '✅ 已向 faucet 請求測試幣，數秒後重查餘額'
          : '領測試幣失敗：${res['error'] ?? '未知錯誤'}'),
    ));
    if (ok) {
      await Future.delayed(const Duration(seconds: 3));
      if (mounted) _loadBalance();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: const [
              Icon(Icons.account_balance_wallet, color: Color(0xFF1DB954)),
              SizedBox(width: 8),
              Text('錢包餘額',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Center(child: Padding(
              padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
          else if (_error != null)
            Text('⚠️ $_error', style: const TextStyle(color: Colors.redAccent))
          else ...[
            Text('${_balanceSui?.toStringAsFixed(4) ?? '--'} SUI',
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            if (_address != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${_address!.substring(0, 10)}…${_address!.substring(_address!.length - 6)}',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _loading ? null : _loadBalance,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('重新查詢'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _fauceting ? null : _faucet,
                  icon: _fauceting
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.water_drop, size: 18),
                  label: Text(_fauceting ? '領取中…' : '領測試幣'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '付款時的車資由你的錢包 SUI 支出（gas 由平台贊助）。testnet 可免費領測試幣。',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
