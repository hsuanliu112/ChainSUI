/// 應用配置
///
/// 開發時可以創建 app_config.local.dart 來覆蓋這些設置
/// app_config.local.dart 不會被提交到 git

// 嘗試導入本地配置
import 'app_config.local.dart' as local;

class AppConfig {
  // 後端 API 配置
  static String get backendUrl {
    // 嘗試從本地配置讀取（如果存在）
    try {
      return local.localBackendUrl;
    } catch (e) {
      // 本地配置不存在，使用默認值
      print('⚠️ 未找到本地配置，使用默認 URL: $defaultBackendUrl');
      return defaultBackendUrl;
    }
  }

  // 默認後端 URL（提交到 git 的版本）
  static const String defaultBackendUrl = 'http://localhost:8000/api/v1';

  // WebSocket URL
  static String get websocketUrl {
    final baseUrl = backendUrl.replaceAll('/api/v1', '');
    return baseUrl;
  }

  // OSM 地圖配置
  static const String osmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  // ---- 鏈上合約（單一事實來源）----
  // 2026-09-14 金鑰輪替後以新平台錢包重新部署（testnet，含 dispute/agent-cap/pool-refund）。
  // 與後端 .env CONTRACT_PACKAGE_ID 一致；所有 admin cap（Refund/CredentialAdmin/Rating/Arbiter）
  // 與 RefundPoolV2.platform_address 皆綁定新錢包。
  // 舊 package 0xb761c6f5…e23f（部署者私鑰已洩漏）、0xa6232c…380b、0xda64…542f 均為死值，整組棄置。
  static const String contractPackageId =
      '0x95f9980906fb946ffd1c7474e59c9155d9075d62b8c3ca5511b6ca53fed779b0';

  // 平台收費 / Agent 簽章地址（與後端 .env PLATFORM_WALLET_ADDRESS 一致）。
  // 舊地址 0x013a90ee…af36 的私鑰曾入庫洩漏，已於 2026-09-14 作廢並清空。
  static const String platformAddress =
      '0x5b6d842300004da9b766ecd92e5f7c44fab986ae900e0c7e4d6f372b917bf3ac';

  // ---- zkLogin（Google OAuth）----
  // 需在 Google Cloud 建立 OAuth Client（iOS/Android/Web），並在 Enoki Portal
  // 註冊同一個 client id 為 Google Auth Provider。填好後 zkLogin 即可端到端運作。
  // 可在 app_config.local.dart 以 localGoogleOAuthClientId 覆蓋。
  static String get googleOAuthClientId {
    try {
      return local.localGoogleOAuthClientId;
    } catch (_) {
      return defaultGoogleOAuthClientId;
    }
  }

  static const String defaultGoogleOAuthClientId = ''; // TODO: 填入 Google OAuth Client ID

  // AppAuth redirect：iOS/Android 原生 client 慣例為反轉的 client id
  // 例：com.googleusercontent.apps.<CLIENT_ID_不含.apps...>:/oauth2redirect
  static String get googleOAuthRedirectUrl {
    try {
      return local.localGoogleOAuthRedirectUrl;
    } catch (_) {
      return defaultGoogleOAuthRedirectUrl;
    }
  }

  static const String defaultGoogleOAuthRedirectUrl = '';
}
