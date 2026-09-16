import 'package:flutter/material.dart';

import 'services/api_service.dart';
import 'services/refund_service.dart';
import 'session_manager.dart';

class TripHistoryPage extends StatefulWidget {
  const TripHistoryPage({super.key, required this.session});

  final UserSession? session;

  @override
  State<TripHistoryPage> createState() => _TripHistoryPageState();
}

class _TripHistoryPageState extends State<TripHistoryPage> {
  bool _isLoading = true;
  List<Map<String, dynamic>> _trips = const [];
  String? _error;

  UserSession? get _session => widget.session;
  String? get _userRole => widget.session?.role;

  @override
  void initState() {
    super.initState();
    _loadTrips();
  }

  Future<void> _loadTrips() async {
    if (_session == null) {
      setState(() {
        _isLoading = false;
        _error = '帳戶尚未登入';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final result = await ApiService.getUserTrips(limit: 50);
    if (!mounted) return;

    if (result['success'] == true && result['data'] is List) {
      final trips = (result['data'] as List)
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
      setState(() {
        _trips = trips;
        _isLoading = false;
      });
    } else {
      setState(() {
        _isLoading = false;
        _error = result['error']?.toString() ?? '載入失敗';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('行程歷史'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _loadTrips,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF1DB954)),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
      );
    }

    if (_trips.isEmpty) {
      return const Center(
        child: Text(
          '目前沒有行程紀錄',
          style: TextStyle(color: Colors.white54),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _trips.length,
      itemBuilder: (_, index) {
        final trip = _trips[index];
        return _TripCard(
          trip: trip,
          userRole: _userRole,
          onRefund: () => _showRefundDialog(trip),
        );
      },
    );
  }

  /// 顯示退款對話框
  Future<void> _showRefundDialog(Map<String, dynamic> trip) async {
    final tripId = trip['trip_id'];
    final rawAmount = trip['total_amount'];

    // 計算可退款金額
    double? maxRefundAmount;
    if (rawAmount is num) {
      if (rawAmount > 100000000) {
        maxRefundAmount = rawAmount / 1000000000;
      } else if (rawAmount > 1000) {
        maxRefundAmount = rawAmount / 1000000;
      } else {
        maxRefundAmount = rawAmount.toDouble();
      }
    }

    final reasonController = TextEditingController();
    final amountController = TextEditingController(
      text: maxRefundAmount?.toStringAsFixed(4) ?? '',
    );

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('申請退款', style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '行程 #$tripId',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 16),
              const Text(
                '退款金額 (SUI)',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: amountController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: '輸入退款金額',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: const Color(0xFF2A2A2A),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              if (maxRefundAmount != null) ...[
                const SizedBox(height: 4),
                Text(
                  '最大退款金額: ${maxRefundAmount.toStringAsFixed(4)} SUI',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
              const SizedBox(height: 16),
              const Text(
                '退款原因（至少 10 個字）',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: reasonController,
                maxLines: 4,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: '請詳細說明退款原因...',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: const Color(0xFF2A2A2A),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            child: const Text('提交申請'),
          ),
        ],
      ),
    );

    if (result == true && mounted) {
      final reason = reasonController.text.trim();
      final amountText = amountController.text.trim();

      if (reason.length < 10) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('退款原因至少需要 10 個字'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      final amount = double.tryParse(amountText);
      if (amount == null || amount <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('請輸入有效的退款金額'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      if (maxRefundAmount != null && amount > maxRefundAmount) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('退款金額不能超過 ${maxRefundAmount.toStringAsFixed(4)} SUI'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // 提交退款請求（統一走 RefundService：multipart，支援佐證檔上傳）
      setState(() => _isLoading = true);

      // J1：token 由 RefundService 從 ApiService 取得（自動 refresh），不再傳 widget 內的舊 session token
      final refundResult = await RefundService.createRefundRequest(
        tripId: tripId,
        reason: reason,
        refundAmountSui: amount,
      );

      if (!mounted) return;

      setState(() => _isLoading = false);

      if (refundResult['success'] == true) {
        final txHash = refundResult['data']?['transaction_hash'] ?? '';
        final shortHash = txHash.length > 16 ? '${txHash.substring(0, 16)}...' : txHash;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '✅ 退款已成功執行！',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                if (txHash.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '交易: $shortHash',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ],
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 5),
          ),
        );
        _loadTrips(); // 重新加載行程列表
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ 退款失敗: ${refundResult['error']}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }

    // 延遲 dispose，確保 dialog 完全關閉
    Future.delayed(const Duration(milliseconds: 100), () {
      reasonController.dispose();
      amountController.dispose();
    });
  }
}

class _TripCard extends StatelessWidget {
  const _TripCard({
    required this.trip,
    this.userRole,
    this.onRefund,
  });

  final Map<String, dynamic> trip;
  final String? userRole;
  final VoidCallback? onRefund;

  @override
  Widget build(BuildContext context) {
    final tripId = trip['trip_id'] ?? '--';
    final status = trip['status']?.toString() ?? 'unknown';
    final pickup = trip['pickup_address']?.toString() ?? '未知';
    final dropoff = trip['dropoff_address']?.toString() ?? '未知';
    final distance = trip['distance_km'];

    // 處理金額：資料庫中的數據可能有多種格式
    // 1. MIST 格式 (> 100,000,000): 原始 MIST，需除以 10^9
    // 2. 錯誤的中間格式 (1,000 ~ 100,000,000): 之前除以 1000 的錯誤數據，需再除以 10^6
    // 3. 正確的 SUI 格式 (< 1,000): 已經是 SUI，直接使用
    final rawAmount = trip['total_amount'];
    double? amountSui;
    if (rawAmount is num) {
      if (rawAmount > 100000000) {
        // 原始 MIST 格式
        amountSui = rawAmount / 1000000000;
      } else if (rawAmount > 1000) {
        // 錯誤的中間格式（之前除以 1000 的結果）- 需要再除以 1,000,000
        amountSui = rawAmount / 1000000;
      } else {
        // 正確的 SUI 格式
        amountSui = rawAmount.toDouble();
      }
    }

    final requestedAt = trip['requested_at'];

    return Card(
      color: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.local_taxi, color: Colors.amber),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '行程 #$tripId',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
                _StatusChip(status: status),
              ],
            ),
            const SizedBox(height: 12),
            _InfoRow(icon: Icons.location_on, label: '起點', value: pickup),
            const SizedBox(height: 8),
            _InfoRow(icon: Icons.flag, label: '終點', value: dropoff),
            if (distance != null) ...[
              const SizedBox(height: 8),
              _InfoRow(
                icon: Icons.route,
                label: '距離',
                value: '${distance.toString()} 公里',
              ),
            ],
            if (requestedAt != null) ...[
              const SizedBox(height: 8),
              _InfoRow(
                icon: Icons.access_time,
                label: '發起時間',
                value: requestedAt.toString(),
              ),
            ],
            const SizedBox(height: 12),
            if (amountSui != null) ...[
              Text(
                '總金額：${amountSui.toStringAsFixed(4)} SUI',
                style: const TextStyle(color: Color(0xFF1DB954), fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 4),
              Text(
                '≈ \$${(amountSui * 2.63).toStringAsFixed(2)} USD',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ] else ...[
              const Text(
                '總金額：--',
                style: TextStyle(color: Color(0xFF1DB954), fontWeight: FontWeight.bold),
              ),
            ],
            // 退款按鈕（只有 completed 狀態的行程才顯示）
            if (status == 'completed' && onRefund != null) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onRefund,
                  icon: const Icon(Icons.money_off, size: 18),
                  label: const Text('申請退款'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.orange,
                    side: const BorderSide(color: Colors.orange),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: Colors.white60),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(color: Colors.white38, fontSize: 12)),
              Text(value, style: const TextStyle(color: Colors.white70, fontSize: 14)),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  Color get _color {
    switch (status) {
      case 'completed':
        return const Color(0xFF1DB954);
      case 'cancelled':
        return Colors.redAccent;
      case 'matched':
        return Colors.orange;
      case 'accepted':
        return Colors.blueAccent;
      default:
        return Colors.white24;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: _color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status,
        style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
      ),
    );
  }
}
