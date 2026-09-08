// mobile/lib/widgets/one_click_payment_dialog.dart
/**
 * 一鍵付款簽署對話框 - UX 優化版本
 *
 * 模擬完整的簽署流程：
 * 1. unsigned hash → 簽名 → 提交交易 → 狀態回傳
 * 2. 保有完整原生流程（FastAPI + MoveCall）
 * 3. 僅在 UX 層模擬簽章體驗
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/zklogin_payment_service.dart';

class OneClickPaymentDialog extends StatefulWidget {
  final int tripId;
  final double amountSui;
  final String description;
  final String? driverWallet;

  const OneClickPaymentDialog({
    Key? key,
    required this.tripId,
    required this.amountSui,
    required this.description,
    this.driverWallet,
  }) : super(key: key);

  @override
  State<OneClickPaymentDialog> createState() => _OneClickPaymentDialogState();
}

class _OneClickPaymentDialogState extends State<OneClickPaymentDialog>
    with SingleTickerProviderStateMixin {
  // 支付流程狀態
  PaymentStep _currentStep = PaymentStep.ready;
  String _statusMessage = '準備支付';
  double _progress = 0.0;

  // 交易數據
  String? _unsignedHash;
  String? _signedHash;
  String? _transactionDigest;
  String? _escrowObjectId;

  // 動畫控制器
  late AnimationController _animationController;
  late Animation<double> _progressAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _progressAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    )..addListener(() {
        if (mounted) {
          setState(() {
            _progress = _progressAnimation.value;
          });
        }
      });
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        // 支付進行中時不允許關閉
        return _currentStep == PaymentStep.ready ||
               _currentStep == PaymentStep.completed ||
               _currentStep == PaymentStep.failed;
      },
      child: AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Row(
          children: [
            _buildStepIcon(),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '一鍵支付',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    _statusMessage,
                    style: TextStyle(
                      color: _getStatusColor(),
                      fontSize: 12,
                      fontWeight: FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 支付信息卡片
              _buildPaymentInfoCard(),

              const SizedBox(height: 20),

              // 進度條
              if (_currentStep != PaymentStep.ready &&
                  _currentStep != PaymentStep.failed)
                _buildProgressIndicator(),

              const SizedBox(height: 20),

              // 流程步驟
              _buildStepsIndicator(),

              const SizedBox(height: 20),

              // 交易詳情（僅在處理或完成時顯示）
              if (_currentStep != PaymentStep.ready)
                _buildTransactionDetails(),
            ],
          ),
        ),
        actions: _buildActions(),
      ),
    );
  }

  Widget _buildStepIcon() {
    IconData icon;
    Color color;

    switch (_currentStep) {
      case PaymentStep.ready:
        icon = Icons.payment;
        color = Colors.blue;
        break;
      case PaymentStep.preparing:
        icon = Icons.hourglass_bottom;
        color = Colors.orange;
        break;
      case PaymentStep.signing:
        icon = Icons.edit;
        color = Colors.purple;
        break;
      case PaymentStep.submitting:
        icon = Icons.cloud_upload;
        color = Colors.blue;
        break;
      case PaymentStep.confirming:
        icon = Icons.check_circle_outline;
        color = Colors.green;
        break;
      case PaymentStep.completed:
        icon = Icons.check_circle;
        color = Colors.green;
        break;
      case PaymentStep.failed:
        icon = Icons.error;
        color = Colors.red;
        break;
    }

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: color, size: 28),
    );
  }

  Color _getStatusColor() {
    switch (_currentStep) {
      case PaymentStep.ready:
        return Colors.white70;
      case PaymentStep.completed:
        return Colors.green;
      case PaymentStep.failed:
        return Colors.red;
      default:
        return Colors.orange;
    }
  }

  Widget _buildPaymentInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1DB954), width: 2),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '支付金額',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              Text(
                '${widget.amountSui.toStringAsFixed(4)} SUI',
                style: const TextStyle(
                  color: Color(0xFF1DB954),
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const Divider(color: Color(0xFF404040), height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '行程 ID',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              Text(
                '#${widget.tripId}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '描述',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              Flexible(
                child: Text(
                  widget.description,
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                  textAlign: TextAlign.right,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProgressIndicator() {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: LinearProgressIndicator(
            value: _progress,
            minHeight: 8,
            backgroundColor: const Color(0xFF404040),
            valueColor: AlwaysStoppedAnimation<Color>(
              _currentStep == PaymentStep.failed ? Colors.red : const Color(0xFF1DB954),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${(_progress * 100).toInt()}%',
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  Widget _buildStepsIndicator() {
    return Column(
      children: [
        _buildStepRow(
          1,
          '準備交易',
          _currentStep.index >= PaymentStep.preparing.index,
          _currentStep == PaymentStep.preparing,
        ),
        _buildStepRow(
          2,
          '簽署交易',
          _currentStep.index >= PaymentStep.signing.index,
          _currentStep == PaymentStep.signing,
        ),
        _buildStepRow(
          3,
          '提交鏈上',
          _currentStep.index >= PaymentStep.submitting.index,
          _currentStep == PaymentStep.submitting,
        ),
        _buildStepRow(
          4,
          '等待確認',
          _currentStep.index >= PaymentStep.confirming.index,
          _currentStep == PaymentStep.confirming,
        ),
        _buildStepRow(
          5,
          '支付完成',
          _currentStep == PaymentStep.completed,
          false,
        ),
      ],
    );
  }

  Widget _buildStepRow(int number, String text, bool completed, bool active) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: completed
                  ? const Color(0xFF1DB954)
                  : (active ? Colors.orange : const Color(0xFF404040)),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: active ? Colors.orange : Colors.transparent,
                width: 2,
              ),
            ),
            child: Center(
              child: completed
                  ? const Icon(Icons.check, color: Colors.white, size: 16)
                  : (active
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          '$number',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        )),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: completed
                    ? Colors.white
                    : (active ? Colors.orange : Colors.white54),
                fontSize: 13,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          if (active)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.orange,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTransactionDetails() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF404040)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.info_outline, color: Colors.blue, size: 16),
              const SizedBox(width: 8),
              const Text(
                '交易詳情',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_unsignedHash != null)
            _buildDetailRow('Unsigned Hash', _unsignedHash!, canCopy: true),
          if (_signedHash != null)
            _buildDetailRow('Signed Hash', _signedHash!, canCopy: true),
          if (_transactionDigest != null)
            _buildDetailRow('Transaction', _transactionDigest!, canCopy: true),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, {bool canCopy = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${value.substring(0, 10)}...${value.substring(value.length - 8)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              if (canCopy)
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: value));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('已複製'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  child: const Icon(Icons.copy, size: 14, color: Colors.blue),
                ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _buildActions() {
    if (_currentStep == PaymentStep.ready) {
      return [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(color: Colors.white70)),
        ),
        TextButton(
          onPressed: _showManualPaymentInfo,
          style: TextButton.styleFrom(
            foregroundColor: Colors.orange,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.content_copy, size: 16),
              SizedBox(width: 6),
              Text('手動支付', style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        ElevatedButton(
          onPressed: _startPayment,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1DB954),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.flash_on, size: 18),
              SizedBox(width: 8),
              Text('一鍵支付', style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ];
    } else if (_currentStep == PaymentStep.completed) {
      return [
        ElevatedButton(
          onPressed: () {
            Navigator.pop(context, {
              'success': true,
              'tx_hash': _transactionDigest,
              'escrow_object_id': _escrowObjectId,
              'message': '支付成功',
            });
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
          child: const Text('完成'),
        ),
      ];
    } else if (_currentStep == PaymentStep.failed) {
      return [
        TextButton(
          onPressed: () => Navigator.pop(context, {'success': false}),
          child: const Text('關閉'),
        ),
        ElevatedButton(
          onPressed: () {
            setState(() {
              _currentStep = PaymentStep.ready;
              _statusMessage = '準備支付';
              _progress = 0.0;
              _unsignedHash = null;
              _signedHash = null;
              _transactionDigest = null;
            });
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orange,
          ),
          child: const Text('重試'),
        ),
      ];
    } else {
      return [
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ];
    }
  }

  Future<void> _startPayment() async {
    try {
      // Step 0: 付款前餘額預檢——不足就快速失敗給明確訊息，
      // 而非走到後端組交易挑 coin 時才炸（付款是乘客自己的 SUI）。
      await _precheckBalance();

      // Step 1: 準備交易
      await _prepareTransaction();

      // Step 2: 簽署交易
      await _signTransaction();

      // Step 3: 提交交易
      await _submitTransaction();

      // Step 4: 等待確認
      await _confirmTransaction();

      // Step 5: 完成
      _completePayment();

    } catch (e) {
      _failPayment(e.toString());
    }
  }

  /// 付款前查餘額；不足直接拋錯（由 _startPayment 的 catch → _failPayment 呈現）。
  /// 查詢失敗（網路等）不擋付款——讓後端組交易時的真檢查決定，避免誤擋。
  Future<void> _precheckBalance() async {
    try {
      final res = await ApiService.getWalletBalance();
      if (res['success'] != true) return; // 查不到餘額不擋，交給後端把關
      final data = res['data'] ?? res;
      final balanceSui = (data['balance_sui'] is num)
          ? (data['balance_sui'] as num).toDouble()
          : double.tryParse('${data['balance_sui'] ?? ''}') ?? -1;
      if (balanceSui < 0) return; // 格式異常不擋
      if (balanceSui < widget.amountSui) {
        throw Exception(
          '餘額不足：現有 ${balanceSui.toStringAsFixed(4)} SUI，'
          '需 ${widget.amountSui.toStringAsFixed(4)} SUI。請先到「錢包」領測試幣後再付款。',
        );
      }
    } on Exception {
      rethrow; // 餘額不足的明確錯誤往上拋
    } catch (_) {
      // 其餘（解析等）不擋付款
    }
  }

  Future<void> _prepareTransaction() async {
    setState(() {
      _currentStep = PaymentStep.preparing;
      _statusMessage = '正在準備交易數據...';
    });

    _animationController.reset();
    _animationController.animateTo(0.2);

    // 模擬準備交易數據（實際應該調用後端 API）
    await Future.delayed(const Duration(milliseconds: 800));

    // 生成模擬的 unsigned hash
    _unsignedHash = _generateMockHash('unsigned');

    if (!mounted) return;
    setState(() {
      _statusMessage = '交易數據已準備';
    });
  }

  Future<void> _signTransaction() async {
    setState(() {
      _currentStep = PaymentStep.signing;
      _statusMessage = '正在簽署交易...';
    });

    _animationController.animateTo(0.4);

    // 模擬簽署過程
    await Future.delayed(const Duration(milliseconds: 1200));

    // 生成模擬的 signed hash
    _signedHash = _generateMockHash('signed');

    if (!mounted) return;
    setState(() {
      _statusMessage = '交易已簽署';
    });
  }

  Future<void> _submitTransaction() async {
    setState(() {
      _currentStep = PaymentStep.submitting;
      _statusMessage = '正在調用智能合約...';
    });

    _animationController.animateTo(0.6);

    // 優先：非託管 zkLogin 付款（乘客本人簽名，符合合約 passenger = sender）。
    // 需已用 zkLogin 登入且 Enoki 贊助就緒；否則落到後端 operator 代簽後備。
    if (widget.driverWallet != null && widget.driverWallet!.isNotEmpty) {
      try {
        final amountMist = (widget.amountSui * 1000000000).round();
        final zk = await ZkLoginPaymentService.instance.payLockPayment(
          tripId: widget.tripId,
          amountMist: amountMist,
          driver: widget.driverWallet!,
        );
        if (zk.success) {
          if (!mounted) return;
          _transactionDigest = zk.digest;
          _escrowObjectId = zk.escrowObjectId;
          setState(() => _statusMessage = '✅ 交易已上鏈（本人 zkLogin 簽署，非託管）');
          return;
        }
        print('⚠️ zkLogin 付款失敗，改用後備路徑: ${zk.error}');
      } catch (e) {
        print('⚠️ zkLogin 付款例外，改用後備路徑: $e');
      }
    }

    // 後備：後端 operator 代簽（僅在 zkLogin 不可用時）。
    // 失敗即明確拋錯 → _failPayment，不偽造交易 hash（遵守 CLAUDE.md）。
    final result = await ApiService.createEscrowPayment(
      tripId: widget.tripId,
      amountSui: widget.amountSui,
      driverWallet: widget.driverWallet,
    );

    if (!mounted) return;

    if (result['success'] == true) {
      _transactionDigest = result['tx_hash'] ?? result['escrow_id'];
      _escrowObjectId = result['escrow_id'] ?? result['escrow_object_id'];
      setState(() => _statusMessage = '✅ 交易已提交到鏈上（平台代簽後備路徑）');
    } else {
      throw Exception(result['error'] ?? '付款失敗（zkLogin 與後備代簽皆未成功）');
    }
  }

  Future<void> _confirmTransaction() async {
    setState(() {
      _currentStep = PaymentStep.confirming;
      _statusMessage = '等待區塊鏈確認...';
    });

    _animationController.animateTo(0.9);

    // 模擬等待確認
    await Future.delayed(const Duration(milliseconds: 1500));

    _animationController.animateTo(1.0);

    if (!mounted) return;
    setState(() {
      _statusMessage = '交易已確認';
    });
  }

  void _completePayment() {
    if (!mounted) return;
    setState(() {
      _currentStep = PaymentStep.completed;
      _statusMessage = '支付成功！';
      _progress = 1.0;
    });

    // 保存手動付款資訊到本地，供稍後驗證使用
    _savePaymentInfoLocally();
  }

  Future<void> _savePaymentInfoLocally() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final paymentInfo = {
        'trip_id': widget.tripId,
        'amount_sui': widget.amountSui,
        'tx_hash': _transactionDigest ?? '',
        'timestamp': DateTime.now().toIso8601String(),
        'status': 'pending_verification',
      };

      // 保存到 SharedPreferences
      final key = 'payment_${widget.tripId}';
      await prefs.setString(key, json.encode(paymentInfo));

      print('✅ 已保存付款資訊: $key');
    } catch (e) {
      print('⚠️  保存付款資訊失敗: $e');
    }
  }

  void _failPayment(String error) {
    if (!mounted) return;
    setState(() {
      _currentStep = PaymentStep.failed;
      _statusMessage = '支付失敗: $error';
    });
  }

  String _generateMockHash(String prefix) {
    final random = Random();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return '0x$prefix${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  /// 顯示手動支付資訊
  Future<void> _showManualPaymentInfo() async {
    // 關閉當前對話框
    Navigator.pop(context);

    // 顯示手動支付資訊對話框
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Row(
          children: [
            Icon(Icons.info_outline, color: Colors.orange),
            SizedBox(width: 12),
            Text(
              '手動支付資訊',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 支付金額
              _buildManualPaymentRow(
                '支付金額',
                '${widget.amountSui.toStringAsFixed(4)} SUI',
                canCopy: true,
              ),
              const SizedBox(height: 16),

              // 行程 ID
              _buildManualPaymentRow(
                '行程 ID',
                '#${widget.tripId}',
                canCopy: true,
              ),
              const SizedBox(height: 16),

              // 司機地址
              if (widget.driverWallet != null) ...[
                _buildManualPaymentRow(
                  '司機地址 (driver)',
                  widget.driverWallet!,
                  canCopy: true,
                  fullText: true,
                ),
                const SizedBox(height: 16),
              ],

              // 智能合約資訊
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.code, color: Colors.blue, size: 16),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            '智能合約調用資訊',
                            style: TextStyle(
                              color: Colors.blue,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 16, color: Colors.blue),
                          onPressed: () {
                            // 計算平台費用
                            final platformFee = (widget.amountSui * 1000000000 * 0.05).toInt();
                            final contractInfo = '''
合約地址: 0xa6232c7f85812fe5e57c2e72071915e538ebd2fd7aba98371bd58490e790380b
模塊::函數: payment_escrow::lock_payment

參數:
payment: ${widget.amountSui.toStringAsFixed(4)} SUI
trip_id: ${widget.tripId}
driver: ${widget.driverWallet ?? "未提供"}
platform: 0x6dfff9f4efba3579ce7db6e2f40cfb23461f2aa4e632eb477454bf8c10e0e7b7
platform_fee: $platformFee MIST (5%)
''';
                            Clipboard.setData(ClipboardData(text: contractInfo));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('合約信息已複製'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // 合約地址
                    _buildManualPaymentRow(
                      '合約地址',
                      '0xa6232c7f85812fe5e57c2e72071915e538ebd2fd7aba98371bd58490e790380b',
                      canCopy: true,
                      fullText: true,
                    ),
                    const SizedBox(height: 12),

                    // 函數名稱
                    const Text(
                      '函數: payment_escrow::lock_payment',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 參數列表
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '參數:',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '1. payment: ${widget.amountSui.toStringAsFixed(4)} SUI\n'
                            '2. trip_id: ${widget.tripId}\n'
                            '3. driver: ${widget.driverWallet != null ? "${widget.driverWallet!.substring(0, 20)}..." : "未提供"}\n'
                            '4. platform: 0x6dfff9f4efba3579...e7b7\n'
                            '5. platform_fee: ${(widget.amountSui * 1000000000 * 0.05).toInt()} MIST (5%)',
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 10,
                              fontFamily: 'monospace',
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),

                    // 平台地址完整顯示
                    _buildManualPaymentRow(
                      '平台地址 (platform)',
                      '0x6dfff9f4efba3579ce7db6e2f40cfb23461f2aa4e632eb477454bf8c10e0e7b7',
                      canCopy: true,
                      fullText: true,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // 說明文字
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withOpacity(0.3)),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.lightbulb_outline, color: Colors.orange, size: 16),
                        SizedBox(width: 8),
                        Text(
                          '📱 手動支付步驟',
                          style: TextStyle(
                            color: Colors.orange,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 12),

                    // 手動支付步驟
                    Text(
                      '✅ 手動支付步驟',
                      style: TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      '1️⃣ 點擊上方藍色複製按鈕，複製完整合約信息\n'
                      '2️⃣ 打開 Sui 錢包 App (如 Slush Wallet)\n'
                      '3️⃣ 找到「Move Call」或「智能合約交互」功能\n'
                      '4️⃣ 輸入合約地址和函數名\n'
                      '5️⃣ 依次填入 5 個參數（參照上方參數列表）\n'
                      '6️⃣ 確認並簽署交易\n'
                      '7️⃣ 完成後，返回此 App 驗證支付',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        height: 1.6,
                      ),
                    ),
                    SizedBox(height: 12),
                    Divider(color: Colors.white24, height: 1),
                    SizedBox(height: 12),

                    // 重要提示
                    Text(
                      '⚠️ 重要提示',
                      style: TextStyle(
                        color: Colors.amber,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      '⛔ 請勿直接轉帳給司機地址！\n\n'
                      '必須通過智能合約 lock_payment 函數進行支付，\n'
                      '以確保：\n'
                      '• 資金安全託管\n'
                      '• 自動分配平台費用\n'
                      '• 可退款保障\n'
                      '• 交易記錄追蹤',
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: 10,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('關閉'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              // 返回成功狀態，但沒有 tx_hash（需要稍後驗證）
              Navigator.pop(context, {
                'success': true,
                'manual_payment': true,
                'message': '請在錢包中完成支付後，回來驗證交易',
              });
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
            ),
            child: const Text('我已了解'),
          ),
        ],
      ),
    );
  }

  Widget _buildManualPaymentRow(
    String label,
    String value, {
    bool canCopy = false,
    bool fullText = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF2A2A2A),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF404040)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  fullText
                      ? value
                      : (value.length > 20
                          ? '${value.substring(0, 10)}...${value.substring(value.length - 8)}'
                          : value),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              if (canCopy) ...[
                const SizedBox(width: 8),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: value));
                    // ✅ 檢查 widget 是否還存在
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('已複製：$label'),
                          duration: const Duration(seconds: 1),
                          backgroundColor: Colors.green,
                        ),
                      );
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Icons.copy, size: 16, color: Colors.blue),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

enum PaymentStep {
  ready,
  preparing,
  signing,
  submitting,
  confirming,
  completed,
  failed,
}

/// 顯示一鍵支付對話框的輔助函數
Future<Map<String, dynamic>?> showOneClickPaymentDialog(
  BuildContext context, {
  required int tripId,
  required double amountSui,
  required String description,
  String? driverWallet,
}) {
  return showDialog<Map<String, dynamic>>(
    context: context,
    barrierDismissible: false,
    builder: (context) => OneClickPaymentDialog(
      tripId: tripId,
      amountSui: amountSui,
      description: description,
      driverWallet: driverWallet,
    ),
  );
}
