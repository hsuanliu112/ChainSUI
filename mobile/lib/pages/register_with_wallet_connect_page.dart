// mobile/lib/pages/register_with_wallet_connect_page.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../services/did_service.dart';
import '../services/zkp_service.dart';
import '../session_manager.dart';
import '../main.dart'; // 使用全域 WalletConnector
import '../widgets/age_verification_dialog.dart';
import '../widgets/license_verification_dialog.dart';

class RegisterWithWalletConnectPage extends StatefulWidget {
  const RegisterWithWalletConnectPage({super.key});

  @override
  State<RegisterWithWalletConnectPage> createState() =>
      _RegisterWithWalletConnectPageState();
}

class _RegisterWithWalletConnectPageState
    extends State<RegisterWithWalletConnectPage> {
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _walletAddressController = TextEditingController();

  bool _isLoading = false;
  bool _showPassword = false;
  String _userType = 'passenger';
  String? _connectedWalletAddress;
  int _currentStep = 0;

  // ZKP 相關狀態
  final ZkpService _zkpService = ZkpService();
  ZkpHealthStatus? _zkpHealthStatus;
  bool _isZkpHealthLoading = false;

  // 身份驗證狀態
  bool _ageVerified = false;
  bool _licenseVerified = false;

  // 開發模式：自動生成測試錢包地址
  static const bool _devMode = true;

  @override
  void initState() {
    super.initState();
    // 監聽全域 WalletConnector 的變化
    globalWalletConnector.addListener(_onWalletChanged);
    // 檢查是否已經連接
    if (globalWalletConnector.isConnected) {
      _connectedWalletAddress = globalWalletConnector.walletAddress;
      _walletAddressController.text = _connectedWalletAddress ?? '';
    }
    // 檢查 ZKP 服務健康狀態
    _checkZkpHealth();
  }

  Future<void> _checkZkpHealth() async {
    setState(() => _isZkpHealthLoading = true);
    try {
      final status = await _zkpService.getHealthStatus();
      if (mounted) {
        setState(() {
          _zkpHealthStatus = status;
          _isZkpHealthLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isZkpHealthLoading = false);
      }
    }
  }

  @override
  void dispose() {
    globalWalletConnector.removeListener(_onWalletChanged);
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _walletAddressController.dispose();
    super.dispose();
  }

  void _onWalletChanged() {
    // 當錢包連接狀態改變時更新 UI
    if (globalWalletConnector.isConnected && mounted) {
      setState(() {
        _connectedWalletAddress = globalWalletConnector.walletAddress;
        _walletAddressController.text = _connectedWalletAddress ?? '';
      });
      _showSuccess('✅ 錢包已連接！');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('註冊帳號')),
      body: Stepper(
        currentStep: _currentStep,
        onStepContinue: _onStepContinue,
        onStepCancel: _onStepCancel,
        controlsBuilder: (context, details) {
          return Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Row(
              children: [
                if (_currentStep > 0)
                  TextButton(
                    onPressed: details.onStepCancel,
                    child: const Text('上一步'),
                  ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _isLoading ? null : details.onStepContinue,
                  child:
                      _isLoading
                          ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                          : Text(_currentStep == 3 ? '完成註冊' : '下一步'),
                ),
              ],
            ),
          );
        },
        steps: [
          // 步驟 1: 基本信息
          Step(
            title: const Text('基本信息'),
            content: Column(
              children: [
                TextField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: '用戶名',
                    hintText: '3-50 個字符',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _emailController,
                  decoration: const InputDecoration(
                    labelText: '郵箱',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: _userType,
                  decoration: const InputDecoration(
                    labelText: '用戶類型',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'passenger', child: Text('乘客')),
                    DropdownMenuItem(value: 'driver', child: Text('司機')),
                    DropdownMenuItem(value: 'both', child: Text('乘客和司機')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _userType = value);
                    }
                  },
                ),
              ],
            ),
            isActive: _currentStep >= 0,
            state: _currentStep > 0 ? StepState.complete : StepState.indexed,
          ),

          // 步驟 2: 連接錢包
          Step(
            title: const Text('連接錢包'),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_connectedWalletAddress == null) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              color: Colors.blue.shade700,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '連接您的 Sui 錢包',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.blue.shade700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '您需要一個 Sui 錢包來使用本平台。\n'
                          '如果您還沒有錢包，請先從 App Store 安裝 Slush Wallet 應用。',
                          style: TextStyle(fontSize: 14, color: Colors.blue.shade800),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 連接錢包按鈕
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _connectWallet,
                      icon: const Icon(Icons.account_balance_wallet),
                      label: const Text('連接 Slush Wallet'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),
                  const Text(
                    '或者手動輸入錢包地址：',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _walletAddressController,
                    decoration: const InputDecoration(
                      labelText: '錢包地址',
                      hintText: '0x...',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      if (value.startsWith('0x') && value.length == 66) {
                        setState(() => _connectedWalletAddress = value);
                      }
                    },
                  ),
                ] else ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.green.shade200),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.check_circle,
                              color: Colors.green.shade700,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '錢包已連接',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.green.shade700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '錢包地址：',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.green.shade800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: SelectableText(
                                _connectedWalletAddress!,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                  color: Colors.green.shade900,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: Icon(Icons.copy, size: 16, color: Colors.green.shade700),
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: _connectedWalletAddress!));
                                _showSuccess('錢包地址已複製');
                              },
                              tooltip: '複製地址',
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        // 顯示 DID 信息
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.blue.shade200),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.fingerprint,
                                    color: Colors.blue.shade700,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '您的去中心化身份 (DID)',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.blue.shade700,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: SelectableText(
                                      DIDService.generateDID(_connectedWalletAddress!),
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontFamily: 'monospace',
                                        color: Colors.blue.shade900,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    icon: Icon(Icons.copy, size: 16, color: Colors.blue.shade700),
                                    onPressed: () {
                                      Clipboard.setData(ClipboardData(
                                        text: DIDService.generateDID(_connectedWalletAddress!),
                                      ));
                                      _showSuccess('DID 已複製');
                                    },
                                    tooltip: '複製 DID',
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'DID 是您在區塊鏈上的唯一身份標識，用於隱私保護驗證。',
                                style: TextStyle(fontSize: 11, color: Colors.blue.shade600),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        // ZKP 零知識證明信息區塊
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.purple.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.purple.shade200),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.security,
                                    color: Colors.purple.shade700,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '零知識證明 (ZKP) 隱私保護',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.purple.shade700,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '本平台使用零知識證明技術保護您的隱私：',
                                style: TextStyle(fontSize: 12, color: Colors.purple.shade800),
                              ),
                              const SizedBox(height: 6),
                              _buildZkpFeatureRow(Icons.cake, '年齡驗證', '證明您已滿 18 歲，但不暴露生日'),
                              const SizedBox(height: 4),
                              _buildZkpFeatureRow(Icons.drive_eta, '駕照驗證', '證明您持有有效駕照，但不暴露駕照號碼'),
                              const SizedBox(height: 8),
                              // ZKP 服務狀態
                              Row(
                                children: [
                                  Text(
                                    'ZKP 服務狀態：',
                                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.purple.shade800),
                                  ),
                                  const SizedBox(width: 8),
                                  if (_isZkpHealthLoading)
                                    const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  else if (_zkpHealthStatus != null)
                                    Row(
                                      children: [
                                        Icon(
                                          _zkpHealthStatus!.isHealthy
                                              ? Icons.check_circle
                                              : Icons.warning,
                                          color: _zkpHealthStatus!.isHealthy
                                              ? (_zkpHealthStatus!.isDegraded ? Colors.orange : Colors.green)
                                              : Colors.red,
                                          size: 14,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          _zkpHealthStatus!.isHealthy
                                              ? (_zkpHealthStatus!.isSimulatedMode
                                                  ? '可用 (模擬模式)'
                                                  : '正常 (真實模式)')
                                              : '服務不可用',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: _zkpHealthStatus!.isHealthy
                                                ? (_zkpHealthStatus!.isDegraded ? Colors.orange : Colors.green)
                                                : Colors.red,
                                          ),
                                        ),
                                      ],
                                    )
                                  else
                                    const Text(
                                      '無法連接',
                                      style: TextStyle(fontSize: 11, color: Colors.grey),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextButton.icon(
                          onPressed: () {
                            setState(() => _connectedWalletAddress = null);
                            _walletAddressController.clear();
                          },
                          icon: const Icon(Icons.refresh),
                          label: const Text('重新連接'),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            isActive: _currentStep >= 1,
            state: _currentStep > 1 ? StepState.complete : StepState.indexed,
          ),

          // 步驟 3: 身份驗證
          Step(
            title: const Text('身份驗證'),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 說明
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.purple.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.security, color: Colors.purple.shade700, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '使用零知識證明驗證您的身份，您的私人資訊不會被存儲或洩露。',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.purple.shade700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // 年齡驗證（必須）
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _ageVerified ? Colors.green.shade300 : Colors.grey.shade300,
                    ),
                    borderRadius: BorderRadius.circular(8),
                    color: _ageVerified ? Colors.green.shade50 : null,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _ageVerified ? Icons.check_circle : Icons.cake,
                            color: _ageVerified ? Colors.green : Colors.orange,
                          ),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              '年齡驗證',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.red.shade100,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '必須',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.red.shade700,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _ageVerified
                            ? '已驗證您年滿 18 歲'
                            : '證明您已年滿 18 歲，您的出生日期不會被存儲',
                        style: TextStyle(
                          fontSize: 13,
                          color: _ageVerified ? Colors.green.shade700 : Colors.grey.shade600,
                        ),
                      ),
                      if (!_ageVerified) ...[
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _verifyAge,
                            icon: const Icon(Icons.verified_user),
                            label: const Text('驗證年齡'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orange,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // 駕照驗證（司機必須）
                if (_userType == 'driver' || _userType == 'both') ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: _licenseVerified ? Colors.green.shade300 : Colors.grey.shade300,
                      ),
                      borderRadius: BorderRadius.circular(8),
                      color: _licenseVerified ? Colors.green.shade50 : null,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              _licenseVerified ? Icons.check_circle : Icons.drive_eta,
                              color: _licenseVerified ? Colors.green : Colors.blue,
                            ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                '駕照驗證',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.red.shade100,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '司機必須',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.red.shade700,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _licenseVerified
                              ? '已驗證您持有有效駕照'
                              : '證明您持有有效駕照，駕照號碼不會被存儲',
                          style: TextStyle(
                            fontSize: 13,
                            color: _licenseVerified ? Colors.green.shade700 : Colors.grey.shade600,
                          ),
                        ),
                        if (!_licenseVerified) ...[
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: _verifyLicense,
                              icon: const Icon(Icons.badge),
                              label: const Text('驗證駕照'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blue,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ] else ...[
                  // 乘客可選駕照驗證
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: _licenseVerified ? Colors.green.shade300 : Colors.grey.shade200,
                      ),
                      borderRadius: BorderRadius.circular(8),
                      color: _licenseVerified ? Colors.green.shade50 : Colors.grey.shade50,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              _licenseVerified ? Icons.check_circle : Icons.drive_eta,
                              color: _licenseVerified ? Colors.green : Colors.grey,
                            ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                '駕照驗證',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade200,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                '可選',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _licenseVerified
                              ? '已驗證您持有有效駕照'
                              : '如果日後想成為司機，可以先驗證駕照',
                          style: TextStyle(
                            fontSize: 13,
                            color: _licenseVerified ? Colors.green.shade700 : Colors.grey.shade600,
                          ),
                        ),
                        if (!_licenseVerified) ...[
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _verifyLicense,
                              icon: const Icon(Icons.badge),
                              label: const Text('驗證駕照（可選）'),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
            isActive: _currentStep >= 2,
            state: _currentStep > 2 ? StepState.complete : StepState.indexed,
          ),

          // 步驟 4: 設置密碼
          Step(
            title: const Text('設置密碼'),
            content: Column(
              children: [
                TextField(
                  controller: _passwordController,
                  obscureText: !_showPassword,
                  decoration: InputDecoration(
                    labelText: '密碼',
                    hintText: '至少 8 個字符',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _showPassword ? Icons.visibility_off : Icons.visibility,
                      ),
                      onPressed: () {
                        setState(() => _showPassword = !_showPassword);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _confirmPasswordController,
                  obscureText: !_showPassword,
                  decoration: const InputDecoration(
                    labelText: '確認密碼',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.blue),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '此密碼用於登入平台，與您的錢包密碼無關',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            isActive: _currentStep >= 3,
            state: StepState.indexed,
          ),
        ],
      ),
    );
  }

  Future<void> _onStepContinue() async {
    if (_currentStep == 0) {
      // 驗證基本信息
      if (_usernameController.text.trim().isEmpty ||
          _emailController.text.trim().isEmpty) {
        _showError('請填寫所有欄位');
        return;
      }

      // 檢查用戶名是否可用
      setState(() => _isLoading = true);
      try {
        final checkResult = await ApiService.checkUsername(
          _usernameController.text.trim(),
        );

        if (checkResult['success'] == true) {
          final data = checkResult['data'];
          if (data['available'] != true) {
            _showError('用戶名已被使用，請換一個');
            setState(() => _isLoading = false);
            return;
          }
        }
      } catch (e) {
        _showError('檢查用戶名失敗: $e');
        setState(() => _isLoading = false);
        return;
      }
      setState(() => _isLoading = false);

      setState(() => _currentStep = 1);
    } else if (_currentStep == 1) {
      // 驗證錢包連接
      if (_connectedWalletAddress == null) {
        _showError('請連接錢包或輸入錢包地址');
        return;
      }
      setState(() => _currentStep = 2);
    } else if (_currentStep == 2) {
      // 驗證身份驗證狀態
      if (!_ageVerified) {
        _showError('請先完成年齡驗證');
        return;
      }
      // 司機必須驗證駕照
      if ((_userType == 'driver' || _userType == 'both') && !_licenseVerified) {
        _showError('司機需要完成駕照驗證');
        return;
      }
      setState(() => _currentStep = 3);
    } else if (_currentStep == 3) {
      // 驗證密碼並註冊
      if (_passwordController.text.length < 8) {
        _showError('密碼至少需要 8 個字符');
        return;
      }
      if (_passwordController.text != _confirmPasswordController.text) {
        _showError('兩次輸入的密碼不一致');
        return;
      }

      await _registerUser();
    }
  }

  void _onStepCancel() {
    if (_currentStep > 0) {
      setState(() => _currentStep -= 1);
    }
  }

  Future<void> _connectWallet() async {
    setState(() => _isLoading = true);

    try {
      final result = await globalWalletConnector.connectWallet();

      if (result['success'] == true) {
        if (result['pending'] == true) {
          _showInfo('請在 Slush Wallet 中授權連接');
          // 等待用戶在錢包中授權
          // Deep Link 回調會觸發 _onWalletChanged
        } else if (globalWalletConnector.walletAddress != null) {
          setState(() {
            _connectedWalletAddress = globalWalletConnector.walletAddress;
            _walletAddressController.text = _connectedWalletAddress!;
          });
          _showSuccess('錢包連接成功');
        }
      } else {
        _showError(result['error'] ?? '連接錢包失敗');
      }
    } catch (e) {
      _showError('連接錢包失敗: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _verifyAge() async {
    final result = await AgeVerificationDialog.show(context);
    if (result == true) {
      setState(() => _ageVerified = true);
      _showSuccess('年齡驗證成功！');
    }
  }

  Future<void> _verifyLicense() async {
    final result = await LicenseVerificationDialog.show(context);
    if (result == true) {
      setState(() => _licenseVerified = true);
      _showSuccess('駕照驗證成功！');
    }
  }

  Future<void> _registerUser() async {
    setState(() => _isLoading = true);

    try {
      print('開始註冊用戶...');
      final registerResult = await ApiService.registerUser(
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        walletAddress: _connectedWalletAddress!,
        email: _emailController.text.trim(),
        userType: _userType,
      );
      print('註冊結果: $registerResult');

      if (registerResult['success'] != true) {
        final errorMsg =
            registerResult['data']?['detail'] ??
            registerResult['error'] ??
            '註冊失敗';
        throw Exception(errorMsg);
      }

      // 自動登入
      print('開始登入...');
      final loginResult = await ApiService.loginUser(
        identifier: _usernameController.text.trim(),
        password: _passwordController.text,
      );

      if (loginResult['success'] != true) {
        final errorMsg =
            loginResult['data']?['detail'] ?? loginResult['error'] ?? '登入失敗';
        throw Exception(errorMsg);
      }

      // 保存 session
      final userData = loginResult['data']['user'];
      final session = UserSession(
        userId: userData['id'],
        username: userData['username'],
        role: _userType,
        accessToken: loginResult['data']['access_token'],
        refreshToken: loginResult['data']['refresh_token']?.toString(),
        accessTokenExpiresAt: ApiService.expiresAtFrom(loginResult['data']['expires_in']),
        walletAddress: _connectedWalletAddress,
        phoneNumber: userData['phone_number'],
        email: _emailController.text.trim(),
      );

      await SessionManager.saveSession(session);
      ApiService.adoptSession(session);

      // 跳轉到主頁
      if (mounted) {
        if (_userType == 'driver') {
          Navigator.pushReplacementNamed(
            context,
            '/driver',
            arguments: {'session': session},
          );
        } else {
          Navigator.pushReplacementNamed(
            context,
            '/passenger',
            arguments: {'session': session},
          );
        }
      }
    } catch (e) {
      print('註冊流程錯誤: $e');
      if (mounted) {
        _showError('註冊失敗: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.green),
    );
  }

  void _showInfo(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.blue),
    );
  }

  Widget _buildZkpFeatureRow(IconData icon, String title, String description) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: Colors.purple.shade600),
        const SizedBox(width: 6),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: TextStyle(fontSize: 11, color: Colors.purple.shade900),
              children: [
                TextSpan(
                  text: '$title: ',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                TextSpan(text: description),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
