# backend/app/config.py
"""
應用配置管理

安全原則：
  - 機密（SECRET_KEY / 資料庫帳密 / OPERATOR_PRIVATE_KEY）一律由環境變數注入，
    程式碼中不放任何可用的預設值。
  - 生產模式（DEBUG=false）啟動時做 fail-fast 檢查：缺少或仍是佔位字串的機密會直接
    讓程式無法啟動，避免帶著弱預設上線。
"""
import os
from pydantic_settings import BaseSettings
from pydantic import model_validator
from typing import Optional


# 已知不可用於生產的佔位值（歷史上曾硬編碼於此）
_PLACEHOLDER_SECRETS = {
    "",
    "your-secret-key-change-in-production",
    "your-jwt-secret-key-change-in-production",
    "change-me",
}


class Settings(BaseSettings):
    """應用設置"""

    # 應用基礎配置
    APP_NAME: str = "AutoDrive API"
    DEBUG: bool = os.getenv("DEBUG", "false").lower() == "true"
    API_V1_STR: str = "/api/v1"

    # 數據庫配置（無帳密預設；必須由環境變數提供）
    DATABASE_URL: str = os.getenv("DATABASE_URL", "")

    # Redis 配置
    REDIS_URL: str = os.getenv("REDIS_URL", "redis://redis:6379")

    # 安全配置（無弱預設；由環境變數提供）
    SECRET_KEY: str = os.getenv("SECRET_KEY", "")
    ALGORITHM: str = "HS256"
    # J1 token 有效期（非秘密，不進 .env）：
    #   一般使用者 access 15 分（過期由 app 用 refresh token 靜默換新）；
    #   dashboard 管理員 access 60 分（dashboard 尚未接 refresh，暫維持較長）；
    #   refresh 30 天，DB 存雜湊、每次使用輪替。
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 15
    ADMIN_ACCESS_TOKEN_EXPIRE_MINUTES: int = 60
    REFRESH_TOKEN_EXPIRE_DAYS: int = 30

    # CORS 允許來源（逗號分隔）。預設只允許本機開發來源，生產須明確設定。
    CORS_ALLOW_ORIGINS: str = os.getenv(
        "CORS_ALLOW_ORIGINS",
        "http://localhost,http://localhost:3000,http://localhost:8080",
    )

    # Sui 配置
    SUI_NODE_URL: str = os.getenv("SUI_NODE_URL", "https://fullnode.testnet.sui.io:443")
    SUI_NETWORK: str = os.getenv("SUI_NETWORK", "testnet")
    CONTRACT_PACKAGE_ID: str = os.getenv("CONTRACT_PACKAGE_ID", "")
    USER_REGISTRY_ID: str = os.getenv("USER_REGISTRY_ID", "")
    VEHICLE_REGISTRY_ID: str = os.getenv("VEHICLE_REGISTRY_ID", "")
    MATCHING_SERVICE_ID: str = os.getenv("MATCHING_SERVICE_ID", "")
    PLATFORM_WALLET: str = os.getenv("PLATFORM_WALLET_ADDRESS", "")
    REFUND_POOL_ID: str = os.getenv("REFUND_POOL_ID", "")
    REFUND_CAPABILITY_ID: str = os.getenv("REFUND_CAPABILITY_ID", "")
    DID_REGISTRY_ID: str = os.getenv("DID_REGISTRY_ID", "")
    CREDENTIAL_REGISTRY_ID: str = os.getenv("CREDENTIAL_REGISTRY_ID", "")
    TRUSTED_ISSUERS_ID: str = os.getenv("TRUSTED_ISSUERS_ID", "")
    CREDENTIAL_ADMIN_CAP_ID: str = os.getenv("CREDENTIAL_ADMIN_CAP_ID", "")
    RATING_ADMIN_CAP_ID: str = os.getenv("RATING_ADMIN_CAP_ID", "")
    ARBITER_CAP_ID: str = os.getenv("ARBITER_CAP_ID", "")

    # Mock 模式設置（默認關閉，使用真實區塊鏈驗證）
    MOCK_MODE: bool = os.getenv("MOCK_MODE", "false").lower() == "true"

    # 操作錢包私鑰（僅用於代發交易/支付 gas）。務必由 secret manager 注入，切勿落地檔案。
    OPERATOR_PRIVATE_KEY: str = os.getenv("OPERATOR_PRIVATE_KEY", "")

    # Firebase Cloud Messaging 配置
    FCM_SERVER_KEY: Optional[str] = os.getenv("FCM_SERVER_KEY", None)

    # zkLogin（Mysten Enoki）— 非託管登入 + 贊助交易
    # ENOKI_API_KEY 由 Enoki Portal 建立的私鑰（後端用，勿外流）；缺則 zkLogin 端點停用。
    ENOKI_API_KEY: str = os.getenv("ENOKI_API_KEY", "")
    ENOKI_BASE_URL: str = os.getenv("ENOKI_BASE_URL", "https://api.enoki.mystenlabs.com")
    ENOKI_NETWORK: str = os.getenv("ENOKI_NETWORK", "testnet")

    # Walrus 去中心化存儲（大容量資料：GPS 軌跡、評價媒體、退款佐證）
    WALRUS_PUBLISHER_URL: str = os.getenv(
        "WALRUS_PUBLISHER_URL", "https://publisher.walrus-testnet.walrus.space"
    )
    WALRUS_AGGREGATOR_URL: str = os.getenv(
        "WALRUS_AGGREGATOR_URL", "https://aggregator.walrus-testnet.walrus.space"
    )
    # blob 存活的 epoch 數（Walrus 以 epoch 計費存活期）
    WALRUS_EPOCHS: int = int(os.getenv("WALRUS_EPOCHS", "5"))

    # Agent LLM 決策層（開源模型，OpenAI-compatible endpoint）
    # 預設關閉：關閉時結算走既有規則路徑，行為與導入前完全相同。
    # 本機開發可用 Ollama（LLM_BASE_URL=http://host.docker.internal:11434/v1
    # + LLM_MODEL=qwen2.5:14b-instruct，LLM_API_KEY 任意非空值即可）。
    AGENT_LLM_ENABLED: bool = os.getenv("AGENT_LLM_ENABLED", "false").lower() == "true"
    LLM_BASE_URL: str = os.getenv("LLM_BASE_URL", "")
    LLM_API_KEY: str = os.getenv("LLM_API_KEY", "")
    LLM_MODEL: str = os.getenv("LLM_MODEL", "")
    # LLM 呼叫逾時（秒）與重試次數；逾時或失敗一律 fallback 回規則路徑，不阻斷結算。
    LLM_TIMEOUT_SECONDS: float = float(os.getenv("LLM_TIMEOUT_SECONDS", "10"))
    LLM_MAX_RETRIES: int = int(os.getenv("LLM_MAX_RETRIES", "1"))

    @property
    def cors_allow_origins_list(self) -> list[str]:
        """把逗號分隔的 CORS 設定拆成清單。"""
        return [o.strip() for o in self.CORS_ALLOW_ORIGINS.split(",") if o.strip()]

    @model_validator(mode="after")
    def _enforce_required_secrets(self) -> "Settings":
        """
        缺失或使用佔位機密時 fail-fast。
        - SECRET_KEY / DATABASE_URL：一律必填（JWT 簽章與資料庫連線的根本依賴）。
        - OPERATOR_PRIVATE_KEY：非 MOCK_MODE 時必填（否則無法送出真實鏈上交易）。
        DEBUG 模式下僅記錄警告，方便本機開發；非 DEBUG（生產）則直接拋錯阻止啟動。
        """
        problems: list[str] = []

        if self.SECRET_KEY in _PLACEHOLDER_SECRETS:
            problems.append("SECRET_KEY 未設定或仍為佔位值")
        if not self.DATABASE_URL:
            problems.append("DATABASE_URL 未設定")
        if not self.MOCK_MODE and not self.OPERATOR_PRIVATE_KEY:
            problems.append("非 MOCK_MODE 但 OPERATOR_PRIVATE_KEY 未設定")
        if self.AGENT_LLM_ENABLED and (not self.LLM_BASE_URL or not self.LLM_MODEL):
            problems.append("AGENT_LLM_ENABLED=true 但 LLM_BASE_URL / LLM_MODEL 未設定")

        if problems:
            msg = "設定檢查失敗：" + "；".join(problems)
            if self.DEBUG:
                import logging
                logging.getLogger(__name__).warning("%s（DEBUG 模式僅警告）", msg)
            else:
                raise RuntimeError(msg + "。請由環境變數/secret manager 注入這些機密。")
        return self

    class Config:
        env_file = ".env"
        case_sensitive = True


# 創建全局設置實例
settings = Settings()
