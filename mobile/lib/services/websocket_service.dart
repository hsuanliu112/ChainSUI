import 'dart:async';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:project_dapp/session_manager.dart';
import 'package:project_dapp/services/api_service.dart';

/// WebSocket 服務
/// 負責管理 Socket.IO 連接、事件監聽和推送通知
class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  IO.Socket? _socket;
  bool _isConnected = false;
  String? _currentToken;

  // 事件監聽器回調
  final Map<String, List<Function(dynamic)>> _eventListeners = {};

  /// 是否已連接
  bool get isConnected => _isConnected;

  /// 初始化並連接 WebSocket（只在未連接時才建立新連接）
  Future<void> connect() async {
    print('🔌 WebSocket.connect() 被呼叫');

    // ✅ 如果已經有 socket 且正在連接或已連接，直接返回
    if (_socket != null && (_socket!.connected || _isConnected)) {
      print('✅ WebSocket: 已連接，無需重複連接');
      return;
    }

    // 如果有舊 socket 但未連接，清理它
    if (_socket != null && !_socket!.connected) {
      print('🔧 WebSocket: 清理舊的未連接 socket');
      _socket!.dispose();
      _socket = null;
      _isConnected = false;
    }

    // 獲取 token：優先用 ApiService 記憶體中的（refresh 後最新），沒有才讀持久化 session
    String? token = ApiService.token;
    if (token == null || token.isEmpty) {
      final session = await SessionManager.loadSession();
      token = session?.accessToken;
    }
    if (token == null || token.isEmpty) {
      print('❌ WebSocket: 無法連接，缺少 token');
      return;
    }

    _currentToken = token;

    // 獲取 API 基礎 URL (不含 /api/v1)
    final apiUrl = ApiService.getBaseUrl();

    print('🔌 WebSocket: 嘗試連接到 $apiUrl');
    print('🔑 WebSocket: Token 長度 = ${_currentToken?.length ?? 0}');

    try {
      // 確保使用正確的 Socket.IO 路徑
      final socketUrl = apiUrl.endsWith('/') ? apiUrl.substring(0, apiUrl.length - 1) : apiUrl;
      print('🔌 WebSocket: Socket URL = $socketUrl');

      // 使用更簡單的配置方式
      _socket = IO.io(
        socketUrl,
        <String, dynamic>{
          'transports': ['websocket', 'polling'],
          'autoConnect': false, // 手動連接
          'reconnection': true,
          'reconnectionAttempts': 10,
          'reconnectionDelay': 1000,
          'reconnectionDelayMax': 5000,
          'timeout': 30000,
          'query': {'token': _currentToken},
          'auth': {'token': _currentToken},
          'path': '/socket.io/',
          'forceNew': true, // 強制創建新連接
        },
      );

      print('🔌 WebSocket: Socket 對象已創建');

      _setupSocketListeners();

      print('🔌 WebSocket: 事件監聽器已設置，準備連接...');

      // 手動觸發連接
      _socket!.connect();
      print('🔌 WebSocket: connect() 已調用');

      // 額外檢查連接狀態
      print('🔌 WebSocket: socket.id = ${_socket?.id}');
      print('🔌 WebSocket: socket.connected = ${_socket?.connected}');
      print('🔌 WebSocket: socket.disconnected = ${_socket?.disconnected}');

      print('✅ WebSocket: 初始化完成');
    } catch (e) {
      print('❌ WebSocket: 初始化失敗 - $e');
      print('❌ 錯誤堆疊: ${StackTrace.current}');
    }
  }

  /// 設置 Socket.IO 內建事件監聯器
  void _setupSocketListeners() {
    if (_socket == null) return;

    print('🔧 WebSocket: 開始設置事件監聽器');

    // 連接成功
    _socket!.onConnect((_) {
      _isConnected = true;
      print('✅ WebSocket: 已連接 (onConnect 觸發)');
      print('✅ WebSocket: socket.id = ${_socket?.id}');
      _notifyListeners('connection_status', {'connected': true});
    });

    // 連接失敗
    _socket!.onConnectError((error) {
      print('❌ WebSocket: 連接錯誤 (onConnectError) - $error');
      print('❌ 錯誤類型: ${error.runtimeType}');
      print('❌ 錯誤詳情: ${error.toString()}');
      _isConnected = false;
      _notifyListeners('connection_status', {'connected': false, 'error': error});
    });

    // 監聽任何事件（用於 debug）
    _socket!.onAny((event, data) {
      print('📨 WebSocket: 收到事件 [$event] - $data');
    });

    // 斷開連接
    _socket!.onDisconnect((_) {
      _isConnected = false;
      print('🔌 WebSocket: 已斷開連接');
      _notifyListeners('connection_status', {'connected': false});
    });

    // 重連中
    _socket!.on('reconnecting', (attempt) {
      print('🔄 WebSocket: 重連中 (第 $attempt 次)');
    });

    // 連接成功響應（後端自定義事件）
    _socket!.on('connected', (data) {
      print('📡 WebSocket: 收到連接確認 - $data');
      // 後端認證成功後會發送此事件，此時設置連接狀態
      if (!_isConnected) {
        _isConnected = true;
        print('✅ WebSocket: 已連接（通過 connected 事件確認）');
        _notifyListeners('connection_status', {'connected': true});
      }
    });

    // 錯誤事件
    _socket!.on('error', (error) {
      print('❌ WebSocket: 錯誤 - $error');
    });

    // 心跳回應
    _socket!.on('pong', (data) {
      print('💓 WebSocket: Pong - $data');
    });

    // 業務事件監聽
    _setupBusinessEventListeners();
  }

  /// 設置業務相關事件監聽器
  void _setupBusinessEventListeners() {
    if (_socket == null) return;

    // 行程相關事件
    _socket!.on('trip_accepted', (data) {
      print('📨 WebSocket: 收到 trip_accepted - $data');
      _notifyListeners('trip_accepted', data);
    });

    _socket!.on('trip_started', (data) {
      print('📨 WebSocket: 收到 trip_started - $data');
      _notifyListeners('trip_started', data);
    });

    _socket!.on('trip_arrived', (data) {
      print('📨 WebSocket: 收到 trip_arrived - $data');
      _notifyListeners('trip_arrived', data);
    });

    _socket!.on('trip_completed', (data) {
      print('📨 WebSocket: 收到 trip_completed - $data');
      _notifyListeners('trip_completed', data);
    });

    _socket!.on('trip_cancelled', (data) {
      print('📨 WebSocket: 收到 trip_cancelled - $data');
      _notifyListeners('trip_cancelled', data);
    });

    // 位置更新事件
    _socket!.on('driver_location_update', (data) {
      print('📍 WebSocket: 收到 driver_location_update');
      _notifyListeners('driver_location_update', data);
    });

    // 支付事件
    _socket!.on('payment_processing', (data) {
      print('📨 WebSocket: 收到 payment_processing - $data');
      _notifyListeners('payment_processing', data);
    });

    _socket!.on('payment_completed', (data) {
      print('📨 WebSocket: 收到 payment_completed - $data');
      _notifyListeners('payment_completed', data);
    });

    _socket!.on('payment_failed', (data) {
      print('📨 WebSocket: 收到 payment_failed - $data');
      _notifyListeners('payment_failed', data);
    });

    // 新行程通知（司機端）
    _socket!.on('new_trip_available', (data) {
      print('📨 WebSocket: 收到 new_trip_available - $data');
      _notifyListeners('new_trip_available', data);
    });

    // 加入行程房間確認
    _socket!.on('joined_trip', (data) {
      print('📨 WebSocket: 已加入行程房間 - $data');
      _notifyListeners('joined_trip', data);
    });

    // 離開行程房間確認
    _socket!.on('left_trip', (data) {
      print('📨 WebSocket: 已離開行程房間 - $data');
      _notifyListeners('left_trip', data);
    });

    // 加入司機房間確認
    _socket!.on('joined_drivers_room', (data) {
      print('📨 WebSocket: 已加入司機在線房間 - $data');
      _notifyListeners('joined_drivers_room', data);
    });

    // 新訊息（未來功能）
    _socket!.on('new_message', (data) {
      print('📨 WebSocket: 收到 new_message - $data');
      _notifyListeners('new_message', data);
    });

    // 車輛位置更新（召回功能）
    _socket!.on('vehicle_location_update', (data) {
      print('📍 WebSocket: 收到 vehicle_location_update - $data');
      _notifyListeners('vehicle_location_update', data);
    });

    // 車輛召回完成
    _socket!.on('vehicle_recall_completed', (data) {
      print('🎯 WebSocket: 收到 vehicle_recall_completed - $data');
      _notifyListeners('vehicle_recall_completed', data);
    });
  }

  /// 通知所有監聽該事件的回調
  void _notifyListeners(String event, dynamic data) {
    if (_eventListeners.containsKey(event)) {
      for (var callback in _eventListeners[event]!) {
        try {
          callback(data);
        } catch (e) {
          print('❌ WebSocket: 事件監聽器執行失敗 ($event) - $e');
        }
      }
    }
  }

  /// 註冊事件監聽器
  ///
  /// [event] 事件名稱
  /// [callback] 回調函數
  void on(String event, Function(dynamic) callback) {
    if (!_eventListeners.containsKey(event)) {
      _eventListeners[event] = [];
    }
    _eventListeners[event]!.add(callback);
    print('✅ WebSocket: 已註冊監聽器 - $event');
  }

  /// 移除事件監聽器
  void off(String event, [Function(dynamic)? callback]) {
    if (callback == null) {
      _eventListeners.remove(event);
      print('✅ WebSocket: 已移除所有監聽器 - $event');
    } else {
      _eventListeners[event]?.remove(callback);
      print('✅ WebSocket: 已移除監聽器 - $event');
    }
  }

  /// 加入行程房間
  void joinTrip(int tripId) {
    print('🔍 [DEBUG] joinTrip called with trip_id: $tripId');
    print('🔍 [DEBUG] _socket == null: ${_socket == null}');
    print('🔍 [DEBUG] _isConnected: $_isConnected');

    if (_socket == null) {
      print('❌ WebSocket: 無法加入房間，socket 為 null');
      return;
    }

    if (!_isConnected) {
      print('❌ WebSocket: 無法加入房間，_isConnected = false');
      return;
    }

    // 檢查 socket 的實際連接狀態
    print('🔍 [DEBUG] socket.connected: ${_socket!.connected}');
    print('🔍 [DEBUG] socket.disconnected: ${_socket!.disconnected}');

    if (!_socket!.connected) {
      print('❌ WebSocket: socket.connected 為 false，無法發送事件');
      return;
    }

    // 嘗試發送事件
    print('📤 WebSocket: 準備發送 join_trip - trip_id: $tripId');
    try {
      _socket!.emit('join_trip', {'trip_id': tripId});
      print('✅ WebSocket: join_trip 事件已發送');

      // 同時發送一個 ping 測試連接是否真的通暢
      _socket!.emit('ping', {'test': true, 'timestamp': DateTime.now().millisecondsSinceEpoch});
      print('📤 WebSocket: 測試 ping 已發送');
    } catch (e) {
      print('❌ WebSocket: 發送 join_trip 失敗 - $e');
    }
  }

  /// 離開行程房間
  void leaveTrip(int tripId) {
    if (_socket == null || !_isConnected) {
      print('❌ WebSocket: 無法離開房間，未連接');
      return;
    }

    _socket!.emit('leave_trip', {'trip_id': tripId});
    print('📤 WebSocket: 發送 leave_trip - trip_id: $tripId');
  }

  /// 更新司機位置（司機端使用）
  void updateLocation(int tripId, double lat, double lng) {
    if (_socket == null || !_isConnected) {
      print('❌ WebSocket: 無法更新位置，未連接');
      return;
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _socket!.emit('update_location', {
      'trip_id': tripId,
      'lat': lat,
      'lng': lng,
      'timestamp': timestamp,
    });
    print('📤 WebSocket: 發送 update_location - trip: $tripId, lat: $lat, lng: $lng');
  }

  /// 發送聊天訊息（未來功能）
  void sendMessage(int tripId, String message) {
    if (_socket == null || !_isConnected) {
      print('❌ WebSocket: 無法發送訊息，未連接');
      return;
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _socket!.emit('send_message', {
      'trip_id': tripId,
      'message': message,
      'timestamp': timestamp,
    });
    print('📤 WebSocket: 發送 send_message - trip: $tripId');
  }

  /// 發送心跳
  void ping() {
    if (_socket == null || !_isConnected) {
      return;
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _socket!.emit('ping', {'timestamp': timestamp});
  }

  /// 通用的 emit 方法
  ///
  /// 發送任意事件到服務器
  /// [event] 事件名稱
  /// [data] 要發送的數據
  void emit(String event, dynamic data) {
    if (_socket == null || !_isConnected) {
      print('❌ WebSocket: 無法發送事件 $event，未連接');
      return;
    }

    _socket!.emit(event, data);
    print('📤 WebSocket: 發送 $event');
  }

  /// 斷開連接。[keepListeners] 為 true 時保留頁面已註冊的事件監聽（重連用）。
  void disconnect({bool keepListeners = false}) {
    if (_socket != null) {
      print('🔌 WebSocket: 主動斷開連接');
      _socket!.disconnect();
      _socket!.dispose();
      _socket = null;
    }
    _isConnected = false;
    if (!keepListeners) {
      _eventListeners.clear();
    }
  }

  /// 重新連接（token 更新後由 ApiService.refreshTokens 呼叫）。
  /// socket.io 內建的自動重連會沿用建立時的舊 token，所以必須整個重建 socket；
  /// _setupSocketListeners 只是把事件轉發進 _eventListeners，頁面訂閱不受影響。
  Future<void> reconnect() async {
    print('🔄 WebSocket: 重新連接');
    disconnect(keepListeners: true);
    await connect();
  }
}
