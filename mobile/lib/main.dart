import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'theme/app_theme.dart';
import 'app_navigator.dart';
import 'pages/delegation_page.dart';
import 'package:uni_links/uni_links.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart';

import 'driver_earnings_page.dart';
import 'driver_home_page_new.dart';
import 'pages/trip_in_progress_page.dart';
import 'login_page.dart' as login;
import 'passenger_home_page.dart';
import 'payment_page.dart';
import 'profile_page.dart';
import 'role_select_page.dart';
import 'services/api_service.dart';
import 'services/websocket_service.dart';
import 'services/sui_wallet_connector.dart';
import 'services/notification_service.dart';
import 'session_manager.dart';
import 'trip_history_page.dart';
import 'vehicle_register_page.dart';
// 新增錢包相關頁面
import 'pages/wallet_page.dart';
import 'pages/wallet_setup_page.dart';
import 'pages/register_with_wallet_connect_page.dart';
import 'pages/auth_page.dart';
import 'pages/available_trips_page.dart';

// 全域 WalletConnector 實例
final globalWalletConnector = SuiWalletConnector();

// Deep Link 訂閱
StreamSubscription? _linkSubscription;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // widget/framework 例外 → 明確印出（原本可能造成畫面直接掛掉）
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('🔴 FlutterError: ${details.exception}');
    debugPrint('${details.stack}');
  };

  UserSession? session;
  try {
    // 初始化 Firebase
    // ⚠️ 若 apiKey 仍是佔位符（未設定真實 key），必須「跳過」而非呼叫 initializeApp：
    //    原生 +[FIRInstallations validateAPIKey:] 會對格式不符的 key 丟 NSException → SIGABRT，
    //    這是原生例外，下面的 Dart try/catch 攔不到，會讓整個 app 在啟動時直接閃退。
    try {
      final firebaseOptions = DefaultFirebaseOptions.currentPlatform;
      if (firebaseOptions.apiKey.startsWith('AIza')) {
        await Firebase.initializeApp(options: firebaseOptions);
        print('✅ Firebase 初始化成功');

        // 設置背景消息處理器
        FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

        // 初始化通知服務
        await NotificationService().initialize();
      } else {
        print('⚠️ Firebase apiKey 為佔位符（${firebaseOptions.apiKey}）→ 跳過 Firebase 初始化，'
            'app 照常啟動但暫無推播(FCM)。要啟用：從 Firebase Console 下載真實的 '
            'GoogleService-Info.plist 放進 ios/Runner/，並用 `flutterfire configure` 更新 firebase_options.dart。');
      }
    } catch (e) {
      print('⚠️ Firebase 初始化失敗: $e');
      print('   請檢查 firebase_options.dart 配置');
    }

    // 初始化 WalletConnector
    await globalWalletConnector.initialize();

    // 處理應用啟動時的 Deep Link
    try {
      final initialUri = await getInitialUri();
      if (initialUri != null) {
        print('📱 Initial Deep Link: $initialUri');
        await globalWalletConnector.handleWalletCallback(initialUri);
      }
    } catch (e) {
      print('❌ Failed to get initial URI: $e');
    }

    // 監聽應用運行時的 Deep Link
    _linkSubscription = uriLinkStream.listen((Uri? uri) {
      if (uri != null) {
        print('📱 Received Deep Link: $uri');
        globalWalletConnector.handleWalletCallback(uri);
      }
    }, onError: (err) {
      print('❌ Deep link error: $err');
    });

    session = await SessionManager.loadSession();
    if (session != null) {
      ApiService.adoptSession(session);
      // J1：啟動時只在「已知 access 過期」才主動 refresh（避免 WS 拿死 token 連線）；
      // 執行期靠 _handleRequest 的 401 兜底。refresh 被拒 → forceLogout 已清 session。
      if (ApiService.accessLikelyExpired && ApiService.hasRefreshToken) {
        final ok = await ApiService.refreshTokens();
        if (!ok && ApiService.token == null) {
          session = null;
        }
      }
      if (session != null) {
        // 如果用戶已登入，初始化 WebSocket 連接
        await WebSocketService().connect();
      }
    }
  } catch (e, s) {
    // 任何啟動階段的未捕捉例外 → 印出來，而非靜默閃退；仍嘗試啟動 UI
    print('🔴🔴 啟動未捕捉例外: $e');
    print('$s');
  }

  runApp(ProjectDappApp(initialSession: session));
}

class ProjectDappApp extends StatelessWidget {
  const ProjectDappApp({super.key, this.initialSession});

  final UserSession? initialSession;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey, // J1：讓 ApiService.forceLogout 能導回登入
      title: 'Decentralized Ride App',
      debugShowCheckedModeBanner: false,
      // 本地化設定
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'TW'),
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      locale: const Locale('zh', 'TW'),
      theme: AppTheme.dark(),
      home: _buildInitialHome(),
      routes: {
        '/role_select': (context) => const RoleSelectPage(),
        '/delegation': (context) => const DelegationPage(),
        '/login': (context) {
          final args =
              ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>? ?? {};
          final role = args['role']?.toString() ?? 'passenger';
          return login.LoginPage(role: role);
        },
        '/passenger': (context) {
          final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
          final session = args?['session'] as UserSession? ?? initialSession;
          return PassengerHomePage(session: session);
        },
        '/driver': (context) {
          final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
          final session = args?['session'] as UserSession? ?? initialSession;
          return DriverHomePageNew(session: session);
        },
        '/register_vehicle': (context) {
          final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
          final session = args?['session'] as UserSession? ?? initialSession;
          return RegisterVehiclePage(session: session);
        },
        '/profile': (context) {
          final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>? ?? {};
          final session = args['session'] as UserSession? ?? initialSession;
          return ProfilePage(session: session);
        },
        '/payment': (context) {
          final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>? ?? {};
          final session = args['session'] as UserSession? ?? initialSession;
          return PaymentPage(
            fare: args['fare'],
            session: session,
            startAddress: args['start_address'],
            endAddress: args['end_address'],
            vehicleId: args['vehicle_id'],
            tripId: args['trip_id'] as int?,
          );
        },
        '/trip_history': (context) {
          final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>? ?? {};
          final session = args['session'] as UserSession? ?? initialSession;
          return TripHistoryPage(session: session);
        },
        '/driver_earnings': (context) {
          final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>? ?? {};
          final session = args['session'] as UserSession? ?? initialSession;
          return DriverEarningsPage(session: session);
        },
        '/trip_in_progress': (context) {
          final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>? ?? {};
          final session = args['session'] as UserSession? ?? initialSession;
          final tripId = args['tripId'] as int;
          return TripInProgressPage(session: session, tripId: tripId);
        },
        // 錢包相關路由
        '/wallet': (context) => const WalletPage(),
        '/wallet/setup': (context) => const WalletSetupPage(),
        '/register_with_wallet_connect': (context) => const RegisterWithWalletConnectPage(),
        // 認證路由
        '/auth': (context) => const AuthPage(),
        // 司機功能路由
        '/available_trips': (context) {
          final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>? ?? {};
          final session = args['session'] as UserSession? ?? initialSession;
          return AvailableTripsPage(session: session);
        },
      },
    );
  }

  Widget _buildInitialHome() {
    if (initialSession == null) {
      // 未登入時先顯示角色選擇頁面
      return const RoleSelectPage();
    }

    // 已登入：根據用戶類型跳轉
    if (initialSession!.role == 'driver') {
      return DriverHomePageNew(session: initialSession);
    } else if (initialSession!.role == 'both') {
      // "both" 類型用戶預設進入乘客頁面，可以在個人資料中切換
      return PassengerHomePage(session: initialSession);
    }

    return PassengerHomePage(session: initialSession);
  }
}
