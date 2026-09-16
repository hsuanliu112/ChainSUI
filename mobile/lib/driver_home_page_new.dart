import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'config/map_config.dart';
import 'package:latlong2/latlong.dart';

import 'services/api_service.dart';
import 'services/websocket_service.dart';
import 'services/notification_service.dart';
import 'services/price_service.dart';
import 'session_manager.dart';
import 'trip_history_page.dart';
import 'pages/trip_in_progress_page.dart';
import 'pages/available_trips_page.dart';
import 'pages/vehicle_recall_page.dart';
import 'widgets/new_trip_notification_card.dart';

class DriverHomePageNew extends StatefulWidget {
  const DriverHomePageNew({super.key, required this.session});

  final UserSession? session;

  @override
  State<DriverHomePageNew> createState() => _DriverHomePageNewState();
}

class _DriverHomePageNewState extends State<DriverHomePageNew> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final MapController _mapController = MapController();
  final LatLng _defaultCenter = const LatLng(25.0340, 121.5620);

  List<Map<String, dynamic>> _vehicles = [];
  bool _isLoading = false;
  double _totalEarnings = 0;
  Timer? _pollTimer;
  String? _statusMessage;
  Map<String, dynamic>? _activeTrip;

  UserSession? get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _refreshData(initial: true);
    _initializeWebSocket(); // ✅ 初始化並設置 WebSocket
    // ✅ 已移除輪詢 - 改用 WebSocket 實時通知
  }

  /// 設置 WebSocket 監聽（不重複建立連接）
  Future<void> _initializeWebSocket() async {
    final ws = WebSocketService();

    // ✅ 不再主動 connect()，由統一入口管理連接
    // WebSocket 應該在登入成功時或 app 啟動時統一初始化

    // 加入司機在線房間以接收新訂單通知
    ws.emit('join_drivers_room', {});
    print('✅ 司機端已加入在線司機房間');

    // 發送 FCM Token 到後端（如果有）
    try {
      final notificationService = NotificationService();
      if (notificationService.isInitialized && notificationService.fcmToken != null) {
        final fcmToken = notificationService.fcmToken!;
        print('📱 發送 FCM Token 到後端: ${fcmToken.substring(0, 20)}...');

        // 通過 WebSocket 發送 FCM Token
        ws.emit('update_fcm_token', {'fcm_token': fcmToken});

        // 也可以通過 HTTP API 發送
        // await ApiService.updateFCMToken(fcmToken);
      } else {
        print('⚠️ FCM Token 未初始化，可能是 Firebase 未配置');
      }
    } catch (e) {
      print('⚠️ 發送 FCM Token 失敗: $e');
    }

    // 監聽新行程推送
    ws.on('new_trip_available', (data) {
      print('📨 收到新行程推送: $data');
      if (!mounted) return;

      // 顯示推送通知卡片
      final tripInfo = data['trip'] ?? data;
      _showNewTripNotification(tripInfo);
    });

    // 監聽行程狀態更新（乘客取消等）
    ws.on('trip_cancelled', (data) {
      print('📨 收到行程取消通知: $data');
      if (!mounted) return;

      // 刷新數據以更新UI
      _refreshData();

      // 顯示通知
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('行程 ${data['trip_id']} 已被取消'),
          backgroundColor: Colors.orange,
        ),
      );
    });

    // 監聽行程完成通知
    ws.on('trip_completed', (data) {
      print('📨 收到行程完成通知: $data');
      if (!mounted) return;

      // 刷新數據以更新收益
      _refreshData();
    });

    print('✅ 司機端 WebSocket 監聽已設置');
  }

  /// 顯示新行程推送通知
  void _showNewTripNotification(Map<String, dynamic> data) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        // 需要先導入 widgets/new_trip_notification_card.dart
        return NewTripNotificationCard(
          tripId: data['trip_id'] ?? 0,
          distanceToPickup: (data['distance_to_pickup'] ?? 0).toDouble(),
          pickupAddress: data['pickup_address'] ?? '未知地點',
          dropoffAddress: data['dropoff_address'] ?? '未知地點',
          distanceKm: (data['distance_km'] ?? 0).toDouble(),
          estimatedFareSui: (data['estimated_fare_sui'] ?? 0).toDouble(),
          timeoutSeconds: data['timeout_seconds'] ?? 60,
          passengerCount: data['passenger_count'] ?? 1,
          priority: data['priority'] ?? 2,
          surgeReason: data['surge_reason'],
          onAccept: () {
            Navigator.of(context).pop(); // 關閉彈窗
            _acceptTripFromNotification(data['trip_id']);
          },
          onDismiss: () {
            Navigator.of(context).pop(); // 關閉彈窗
          },
        );
      },
    );
  }

  /// 從推送通知接受行程
  Future<void> _acceptTripFromNotification(int tripId) async {
    setState(() => _isLoading = true);

    final result = await ApiService.acceptTrip(
      tripId: tripId,
      etaMinutes: 10,
    );

    if (!mounted) return;

    setState(() => _isLoading = false);

    if (result['success'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ 接單成功！'),
          backgroundColor: Colors.green,
        ),
      );

      // 跳轉到行程進行頁面
      Navigator.pushNamed(
        context,
        '/trip_in_progress',
        arguments: {
          'session': _session,
          'tripId': tripId,
        },
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ 接單失敗: ${result['error']}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _pollTimer?.cancel();
    _mapController.dispose(); // ✅ 釋放 MapController

    // 清理 WebSocket 監聽器
    final ws = WebSocketService();
    ws.off('new_trip_available');
    ws.off('trip_cancelled');
    ws.off('trip_completed');

    super.dispose();
  }

  /// 登出並返回角色選擇頁面
  Future<void> _handleLogout() async {
    // 離開司機在線房間
    WebSocketService().emit('leave_drivers_room', {});

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

    // J1：統一登出（後端撤銷 refresh + 清 session + 斷 WS + 導回 /role_select）
    await ApiService.logout();
  }

  Future<void> _refreshData({bool initial = false}) async {
    if (_session == null) return;
    setState(() {
      _isLoading = true;
      if (initial) {
        _statusMessage = '載入資訊...';
      }
    });

    final vehicleResult = await ApiService.getMyVehicles();
    final activeTripResult = await ApiService.getDriverActiveTrip();

    if (!mounted) return;

    // 401 已由 ApiService._handleRequest 統一處理（refresh 或 forceLogout），此處不再自行導頁
    if (vehicleResult['statusCode'] == 401 || activeTripResult['statusCode'] == 401) {
      return;
    }

    // 處理進行中行程
    if (activeTripResult['success'] == true && activeTripResult['data'] != null) {
      setState(() {
        _activeTrip = activeTripResult['data'] as Map<String, dynamic>?;
      });
    } else {
      setState(() {
        _activeTrip = null;
      });
    }

    if (vehicleResult['success'] == true && vehicleResult['data'] is List) {
      final vehicles = (vehicleResult['data'] as List)
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
      vehicles.sort((a, b) => (a['vehicle_id'] ?? '').compareTo(b['vehicle_id'] ?? ''));

      double total = 0;
      for (final vehicle in vehicles) {
        final value = vehicle['total_earnings_micro_sui'];
        if (value is num) {
          total += value.toDouble();
        } else if (value is String) {
          total += double.tryParse(value) ?? 0;
        }
      }

      setState(() {
        _vehicles = vehicles;
        // ✅ 修復：根據金額大小動態選擇除數
        // 如果金額 > 100,000,000，表示是 MIST 單位（1 SUI = 1,000,000,000 MIST）
        // 否則是舊的 micro SUI 單位（1 SUI = 1,000,000 micro SUI）
        if (total > 100000000) {
          _totalEarnings = total / 1000000000; // MIST -> SUI
        } else {
          _totalEarnings = total / 1000000; // micro SUI -> SUI
        }
        _statusMessage = '已更新';
      });

      // ✅ 添加 mounted 檢查，避免在 dispose 後操作地圖
      if (mounted && vehicles.isNotEmpty) {
        final vehicle = vehicles.first;
        final lat = vehicle['current_lat']?.toDouble();
        final lng = vehicle['current_lng']?.toDouble();
        if (lat != null && lng != null) {
          try {
            _mapController.move(LatLng(lat, lng), 13);
          } catch (e) {
            // 忽略地圖移動錯誤
            print('⚠️ 地圖移動錯誤: $e');
          }
        }
      }
    } else {
      setState(() {
        _vehicles = [];
        _statusMessage = vehicleResult['error']?.toString() ?? '取得資料失敗';
      });
    }

    setState(() => _isLoading = false);
  }

  void _openActiveTrip() {
    if (_activeTrip == null) return;

    final tripId = _activeTrip!['trip_id'] as int;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TripInProgressPage(
          session: _session,
          tripId: tripId,
        ),
      ),
    ).then((_) => _refreshData());
  }

  @override
  Widget build(BuildContext context) {
    if (_session == null) {
      return Scaffold(
        backgroundColor: const Color(0xFF121212),
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.pushReplacementNamed(context, '/role_select'),
            child: const Text('請先登入'),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        automaticallyImplyLeading: false, // 移除左上角的返回按鈕
        title: const Text('司機控制台'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _refreshData,
          ),
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => TripHistoryPage(session: _session)),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () => Navigator.pushNamed(context, '/profile', arguments: {'session': _session}),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: '更多選項',
            onSelected: (value) {
              if (value == 'logout') {
                _handleLogout();
              }
            },
            itemBuilder: (BuildContext context) => [
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
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF1DB954),
          labelColor: const Color(0xFF1DB954),
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(icon: Icon(Icons.home), text: '首頁'),
            Tab(icon: Icon(Icons.list_alt), text: '接單'),
            Tab(icon: Icon(Icons.directions_car), text: '車隊'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildHomePage(),
          _buildOrdersPage(),
          _buildVehiclesPage(),
        ],
      ),
    );
  }

  // ========== 首頁 - 地圖 + 快速操作 ==========
  Widget _buildHomePage() {
    return Column(
      children: [
        // 進行中行程提示
        if (_activeTrip != null)
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.blue.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.blue, width: 2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.navigation, color: Colors.blue, size: 20),
                    SizedBox(width: 8),
                    Text(
                      '您有進行中的行程',
                      style: TextStyle(
                        color: Colors.blue,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _openActiveTrip,
                    icon: const Icon(Icons.play_arrow, size: 20),
                    label: Text('繼續行程 #${_activeTrip!['trip_id']}'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),

        // 地圖
        Expanded(
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _defaultCenter,
              initialZoom: 12,
            ),
            children: [
              TileLayer(
                urlTemplate:
                    MapConfig.darkTileUrl,
                userAgentPackageName: 'com.autodrive.driver',
                // 使用默認的 NetworkTileProvider，不傳遞 httpClient
              ),
              MarkerLayer(
                markers: [
                  ..._vehicles.map((vehicle) {
                    final lat = vehicle['current_lat']?.toDouble();
                    final lng = vehicle['current_lng']?.toDouble();
                    if (lat == null || lng == null) return null;
                    return Marker(
                      point: LatLng(lat, lng),
                      width: 36,
                      height: 36,
                      child: const Icon(Icons.directions_car, color: Colors.lightBlueAccent),
                    );
                  }).whereType<Marker>(),
                ],
              ),
            ],
          ),
        ),

        // 收益摘要
        Container(
          padding: const EdgeInsets.all(20),
          decoration: const BoxDecoration(
            color: Color(0xFF1E1E1E),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '總收益',
                    style: TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${_totalEarnings.toStringAsFixed(4)} SUI',
                        style: const TextStyle(
                          color: Color(0xFF1DB954),
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      FutureBuilder<double?>(
                        future: PriceService.convertSuiToUsd(_totalEarnings),
                        builder: (context, snapshot) {
                          if (snapshot.hasData && snapshot.data != null) {
                            return Text(
                              '≈ \$${snapshot.data!.toStringAsFixed(2)} USD',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 14,
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ],
                  ),
                ],
              ),
              if (_statusMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  _statusMessage!,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ========== 接單頁 ==========
  Widget _buildOrdersPage() {
    return AvailableTripsPage(session: _session);
  }

  // ========== 車隊頁 ==========
  Widget _buildVehiclesPage() {
    return Container(
      color: const Color(0xFF121212),
      child: Column(
        children: [
          // 操作按鈕區
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // 新增車輛按鈕
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => Navigator.pushNamed(
                      context,
                      '/register_vehicle',
                      arguments: {'session': _session},
                    ),
                    icon: const Icon(Icons.add),
                    label: const Text('新增車輛'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1DB954),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // 車輛召回按鈕
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => VehicleRecallPage(session: _session!),
                      ),
                    ),
                    icon: const Icon(Icons.location_searching),
                    label: const Text('車輛召回'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 車輛列表
          Expanded(
            child: _isLoading && _vehicles.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _vehicles.isEmpty
                    ? const Center(
                        child: Text(
                          '您目前沒有註冊車輛\n點擊上方按鈕新增',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54, fontSize: 16),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _refreshData,
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          itemCount: _vehicles.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 12),
                          itemBuilder: (_, index) {
                            final vehicle = _vehicles[index];
                            return _VehicleCard(
                              vehicle: vehicle,
                              onUpdateStatus: _updateVehicleStatus,
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Future<void> _updateVehicleStatus(String vehicleId, String status) async {
    final result = await ApiService.updateVehicleStatus(
      vehicleId: vehicleId,
      status: status,
    );

    if (result['success'] == true) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('車輛 $vehicleId 狀態已更新為 $status')),
      );
      await _refreshData();
    } else if (mounted) {
      final message = result['data']?['detail'] ?? result['error'] ?? '更新失敗';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message.toString())),
      );
    }
  }
}

// ========== 車輛卡片組件 ==========
class _VehicleCard extends StatelessWidget {
  const _VehicleCard({
    required this.vehicle,
    required this.onUpdateStatus,
  });

  final Map<String, dynamic> vehicle;
  final void Function(String vehicleId, String status) onUpdateStatus;

  @override
  Widget build(BuildContext context) {
    final id = vehicle['vehicle_id']?.toString() ?? '未知';
    final model = vehicle['model']?.toString() ?? '未命名車輛';
    final plate = vehicle['plate_number']?.toString() ?? '未設定';
    final charge = vehicle['current_charge_percent'];
    final status = vehicle['status']?.toString() ?? 'unknown';
    final distance = vehicle['total_distance_km'];
    final trips = vehicle['total_trips'];

    return Card(
      color: const Color(0xFF2A2A2A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.directions_car, color: Colors.lightBlueAccent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '$model ($plate)',
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: status == 'available' ? const Color(0xFF1DB954) : Colors.amber,
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: Text(
                    status,
                    style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (charge != null)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('電量：${charge.toString()}%',
                      style: const TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: (charge as num).clamp(0, 100) / 100,
                    backgroundColor: Colors.grey[800],
                    color: Colors.lightBlueAccent,
                    minHeight: 6,
                  ),
                ],
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                _InfoChip(icon: Icons.route, value: '${distance ?? '--'} km'),
                const SizedBox(width: 8),
                _InfoChip(icon: Icons.assignment_turned_in, value: '${trips ?? '--'} 趟'),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => onUpdateStatus(id, 'available'),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFF1DB954)),
                      foregroundColor: const Color(0xFF1DB954),
                    ),
                    child: const Text('可接單'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => onUpdateStatus(id, 'offline'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                    child: const Text('離線'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.icon,
    required this.value,
  });

  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF323232),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white54),
          const SizedBox(width: 6),
          Text(
            value,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
