// mobile/lib/services/sui_wallet_connector.dart

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// Slush Wallet 錢包連接器
/// 使用 Deep Links 連接 Slush 移動錢包 (前身為 Suiet Wallet)
class SuiWalletConnector extends ChangeNotifier {
  final _storage = const FlutterSecureStorage();
  
  String? _walletAddress;
  bool _isConnected = false;
  
  // Getters
  String? get walletAddress => _walletAddress;
  bool get isConnected => _isConnected;
  
  // Sui Testnet RPC URL
  static const String suiNodeUrl = 'https://fullnode.testnet.sui.io:443';
  
  /// 初始化 - 檢查是否已連接錢包
  Future<void> initialize() async {
    try {
      final address = await _storage.read(key: 'connected_wallet_address');
      
      if (address != null) {
        _walletAddress = address;
        _isConnected = true;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('初始化錢包連接失敗: $e');
    }
  }
  
  /// 連接錢包（使用 Deep Link）
  ///
  /// 流程：
  /// 1. 生成連接請求
  /// 2. 打開 Slush Wallet 應用
  /// 3. 用戶在錢包中授權
  /// 4. 錢包返回地址
  Future<Map<String, dynamic>> connectWallet() async {
    try {
      // 對於 iOS/Android，我們使用 Deep Link 方案
      // 這需要用戶安裝 Slush Wallet 移動應用

      // 嘗試多個 URL Scheme (新舊版本相容性)
      final schemes = ['slush', 'suiet'];

      for (final scheme in schemes) {
        final connectUrl = _generateConnectUrl(scheme);
        final uri = Uri.parse(connectUrl);

        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);

          return {
            'success': true,
            'message': '請在 Slush Wallet 中授權連接',
            'pending': true,
          };
        }
      }

      // 如果都無法打開，返回錯誤
      return {
        'success': false,
        'error': '未安裝 Slush Wallet，請先從 App Store 安裝',
      };
    } catch (e) {
      debugPrint('連接錢包錯誤: $e');
      return {
        'success': false,
        'error': e.toString(),
      };
    }
  }
  
  /// 手動設置錢包地址（用於測試或手動輸入）
  Future<void> setWalletAddress(String address) async {
    _walletAddress = address;
    _isConnected = true;
    
    await _storage.write(key: 'connected_wallet_address', value: address);
    notifyListeners();
  }
  
  /// 生成連接 URL
  String _generateConnectUrl(String scheme) {
    // Slush Wallet Deep Link 格式
    // slush://connect?callback=autodrive://wallet-callback
    // 或向後兼容: suiet://connect?callback=autodrive://wallet-callback

    final callbackUrl = Uri.encodeComponent('autodrive://wallet-callback');
    return '$scheme://connect?callback=$callbackUrl';
  }
  
  /// 查詢餘額
  Future<Map<String, dynamic>> getBalance() async {
    if (_walletAddress == null) {
      return {'success': false, 'error': '錢包未連接'};
    }
    
    try {
      final response = await http.post(
        Uri.parse(suiNodeUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'suix_getBalance',
          'params': [_walletAddress],
        }),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        
        if (data['result'] != null) {
          final balanceMist = int.parse(data['result']['totalBalance']);
          final balanceSui = balanceMist / 1000000000;
          
          return {
            'success': true,
            'balance_mist': balanceMist,
            'balance_sui': balanceSui,
          };
        }
      }
      
      throw Exception('查詢餘額失敗');
    } catch (e) {
      debugPrint('查詢餘額錯誤: $e');
      return {
        'success': false,
        'error': e.toString(),
      };
    }
  }
  
  /// 請求簽署交易
  /// 
  /// 這會打開 Sui Wallet 讓用戶簽署交易
  Future<Map<String, dynamic>> signTransaction({
    required Map<String, dynamic> transactionData,
  }) async {
    if (_walletAddress == null) {
      return {'success': false, 'error': '錢包未連接'};
    }
    
    try {
      // 將交易數據編碼為 Base64
      final txDataJson = jsonEncode(transactionData);
      final txDataBase64 = base64Encode(utf8.encode(txDataJson));
      
      // 生成簽署請求 URL
      final signUrl = _generateSignUrl(txDataBase64);
      
      // 打開 Sui Wallet 進行簽署
      final uri = Uri.parse(signUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        
        return {
          'success': true,
          'message': '請在 Sui Wallet 中簽署交易',
          'pending': true,
        };
      } else {
        return {
          'success': false,
          'error': '無法打開 Sui Wallet',
        };
      }
    } catch (e) {
      debugPrint('簽署交易錯誤: $e');
      return {
        'success': false,
        'error': e.toString(),
      };
    }
  }
  
  /// 生成簽署 URL
  String _generateSignUrl(String txDataBase64) {
    // Slush Wallet Deep Link 格式 (保持 suiet:// scheme 向後兼容)
    // suiet://sign?data=<base64>&callback=autodrive://sign-callback

    final callbackUrl = Uri.encodeComponent('autodrive://sign-callback');
    return 'suiet://sign?data=$txDataBase64&callback=$callbackUrl';
  }
  
  /// 處理錢包回調
  /// 
  /// 當用戶在 Sui Wallet 中完成操作後，會通過 Deep Link 返回
  Future<void> handleWalletCallback(Uri uri) async {
    try {
      final path = uri.path;
      final params = uri.queryParameters;
      
      if (path == '/wallet-callback') {
        // 連接回調
        final address = params['address'];
        if (address != null) {
          await setWalletAddress(address);
        }
      } else if (path == '/sign-callback') {
        // 簽署回調
        final signature = params['signature'];
        final txDigest = params['digest'];
        
        if (signature != null && txDigest != null) {
          // 保存簽署結果（可以通過 EventBus 或 Stream 通知）
          debugPrint('交易已簽署: $txDigest');
        }
      }
    } catch (e) {
      debugPrint('處理錢包回調錯誤: $e');
    }
  }
  
  /// 斷開錢包連接
  Future<void> disconnect() async {
    _walletAddress = null;
    _isConnected = false;
    
    await _storage.delete(key: 'connected_wallet_address');
    
    notifyListeners();
  }
  
  /// 獲取交易歷史
  Future<List<Map<String, dynamic>>> getTransactionHistory() async {
    if (_walletAddress == null) return [];
    
    try {
      final response = await http.post(
        Uri.parse(suiNodeUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'suix_queryTransactionBlocks',
          'params': [
            {
              'filter': {'FromAddress': _walletAddress},
              'options': {
                'showInput': true,
                'showEffects': true,
                'showEvents': true,
              },
            },
            null,
            10,
            false,
          ],
        }),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        
        if (data['result'] != null && data['result']['data'] != null) {
          return List<Map<String, dynamic>>.from(data['result']['data']);
        }
      }
      
      return [];
    } catch (e) {
      debugPrint('獲取交易歷史錯誤: $e');
      return [];
    }
  }
}
