"""
回歸：zkLogin 交易組裝服務必須讀到平台位址。

先例（2026-09-16）：zklogin_tx_service / payment_zklogin_service 以
getattr(settings, "PLATFORM_WALLET_ADDRESS", "") 讀設定，但 config.py 的屬性名是
PLATFORM_WALLET（環境變數才叫 PLATFORM_WALLET_ADDRESS），永遠拿到空字串 →
委託 prepare 一律 400「缺少 agent 位址」。此測試鎖住正確的屬性名。
"""
from app.config import settings
from app.services.payment_zklogin_service import PaymentZkLoginService
from app.services.zklogin_tx_service import ZkLoginTxService


def test_config_exposes_platform_wallet_from_env_name():
    # 屬性名固定為 PLATFORM_WALLET；不得再依賴不存在的 PLATFORM_WALLET_ADDRESS 屬性
    assert hasattr(settings, "PLATFORM_WALLET")
    assert not hasattr(settings, "PLATFORM_WALLET_ADDRESS")


def test_zklogin_tx_service_reads_platform_wallet(monkeypatch):
    monkeypatch.setattr(settings, "PLATFORM_WALLET", "0x" + "ab" * 32)
    assert ZkLoginTxService().agent_address == "0x" + "ab" * 32


def test_payment_zklogin_service_reads_platform_wallet(monkeypatch):
    monkeypatch.setattr(settings, "PLATFORM_WALLET", "0x" + "cd" * 32)
    assert PaymentZkLoginService().platform_address == "0x" + "cd" * 32
