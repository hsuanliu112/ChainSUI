// mobile/lib/pages/wallet_setup_page.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
// 舊 sui_wallet_service（硬編碼過期 package/平台位址的 WebView 方案）已於 2026-09-14 刪除；
// 錢包/付款一律走 zkLogin + Enoki 路徑（services/zklogin_*），合約 ID 取自 config/app_config.dart。

class WalletSetupPage extends StatefulWidget {
  const WalletSetupPage({Key? key}) : super(key: key);

  @override
  State<WalletSetupPage> createState() => _WalletSetupPageState();
}

class _WalletSetupPageState extends State<WalletSetupPage> {
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _mnemonicController = TextEditingController();
  
  bool _isCreating = false;
  bool _showPassword = false;
  bool _isImportMode = false;
  String? _generatedMnemonic;
  
  @override
  void dispose() {
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _mnemonicController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isImportMode ? '導入錢包' : '創建錢包'),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _isImportMode = !_isImportMode;
              });
            },
            child: Text(
              _isImportMode ? '創建新錢包' : '導入錢包',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 說明卡片
            Card(
              color: Colors.blue.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline, color: Colors.blue.shade700),
                        const SizedBox(width: 8),
                        Text(
                          _isImportMode ? '導入現有錢包' : '創建 Sui 錢包',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.blue.shade700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isImportMode
                          ? '使用您的助記詞恢復錢包。請確保在安全的環境中操作。'
                          : '創建一個新的 Sui 錢包來支付車費。您的私鑰將被安全加密存儲。',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 24),
            
            // 導入模式：助記詞輸入
            if (_isImportMode) ...[
              TextField(
                controller: _mnemonicController,
                decoration: const InputDecoration(
                  labelText: '助記詞',
                  hintText: '輸入 12 個單詞，用空格分隔',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.key),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 16),
            ],
            
            // 密碼輸入
            TextField(
              controller: _passwordController,
              obscureText: !_showPassword,
              decoration: InputDecoration(
                labelText: '設置密碼',
                hintText: '至少 8 個字符',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock),
                suffixIcon: IconButton(
                  icon: Icon(
                    _showPassword ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () {
                    setState(() {
                      _showPassword = !_showPassword;
                    });
                  },
                ),
              ),
            ),
            
            const SizedBox(height: 16),
            
            // 確認密碼
            TextField(
              controller: _confirmPasswordController,
              obscureText: !_showPassword,
              decoration: const InputDecoration(
                labelText: '確認密碼',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
            
            const SizedBox(height: 24),
            
            // 創建/導入按鈕
            ElevatedButton(
              onPressed: _isCreating ? null : _handleWalletSetup,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: Colors.blue,
              ),
              child: _isCreating
                  ? const CircularProgressIndicator(color: Colors.white)
                  : Text(
                      _isImportMode ? '導入錢包' : '創建錢包',
                      style: const TextStyle(fontSize: 16),
                    ),
            ),
            
            // 顯示生成的助記詞
            if (_generatedMnemonic != null) ...[
              const SizedBox(height: 24),
              Card(
                color: Colors.orange.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.warning_amber, color: Colors.orange.shade700),
                          const SizedBox(width: 8),
                          Text(
                            '請備份您的助記詞',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.orange.shade700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.orange.shade200),
                        ),
                        child: SelectableText(
                          _generatedMnemonic!,
                          style: const TextStyle(
                            fontSize: 14,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '請將助記詞抄寫並妥善保管。這是恢復錢包的唯一方式！',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy),
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(text: _generatedMnemonic!),
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已複製到剪貼板')),
                              );
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: () {
                          Navigator.pop(context, true);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                        ),
                        child: const Text('我已備份，繼續'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _handleWalletSetup() async {
    // 驗證輸入
    if (_passwordController.text.length < 8) {
      _showError('密碼至少需要 8 個字符');
      return;
    }
    
    if (_passwordController.text != _confirmPasswordController.text) {
      _showError('兩次輸入的密碼不一致');
      return;
    }
    
    if (_isImportMode && _mnemonicController.text.trim().isEmpty) {
      _showError('請輸入助記詞');
      return;
    }
    
    setState(() {
      _isCreating = true;
    });
    
    try {
      // TODO: 實現錢包服務（走 zkLogin 路徑；勿復活已刪除的 SuiWalletService）
      
      Map<String, dynamic> result = {
        'success': false,
        'error': '錢包管理服務尚未實現'
      };
      
      // if (_isImportMode) {
      //   result = await walletService.importWallet(...);
      // } else {
      //   result = await walletService.createWallet(...);
      // }
      
      if (result['success']) {
        if (!_isImportMode && result['mnemonic'] != null) {
          // 顯示助記詞
          setState(() {
            _generatedMnemonic = result['mnemonic'];
          });
        } else {
          // 導入成功，直接返回
          if (mounted) {
            Navigator.pop(context, true);
          }
        }
      } else {
        _showError(result['error'] ?? '操作失敗');
      }
    } catch (e) {
      _showError('發生錯誤: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isCreating = false;
        });
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }
}
