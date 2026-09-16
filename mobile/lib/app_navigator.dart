import 'package:flutter/widgets.dart';

/// 全域 Navigator key：讓非 widget 層（例如 ApiService 偵測到登入失效時）也能導頁。
/// 獨立成檔以避免 services 反向 import main.dart。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
