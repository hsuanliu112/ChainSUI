"""
非託管付款（zkLogin + Enoki 贊助交易）— Phase 4

為什麼是這個架構：
  - lock_payment 內 `passenger = tx_context::sender(ctx)`，所以「乘客本人」必須是交易 sender。
    後端 operator 代簽會讓 operator 變成 passenger（錯），因此要走 zkLogin 非託管簽名。
  - pysui 0.65 無 zkLogin 簽名組裝能力，故採 Enoki「贊助交易」：後端組交易 kind bytes →
    Enoki 贊助（付 gas）並回 {bytes, digest} → 乘客用臨時金鑰簽 → Enoki 組出 zkLogin 簽名並送鏈。

流程（與 zklogin_service.sponsor / execute_sponsored 搭配）：
  1. build_lock_payment_kind(passenger, amount, trip_id, driver, platform) → kind_bytes(base64)
     * 交易內容：從乘客自己的 Coin<SUI> 拆出 amount，呼叫 lock_payment（款項來自乘客，gas 由 Enoki 贊助）
  2. zklogin_service.sponsor(kind_bytes, sender=passenger, allowedMoveCallTargets=[lock_payment]) → {bytes, digest}
  3. （前端）乘客臨時金鑰簽 bytes（Sui intent），得 signature
  4. zklogin_service.execute_sponsored(digest, signature) → 送鏈 → 解析 escrow_object_id

⚠️ 待實機/Enoki portal 驗證：
  - Enoki app 需設定 sponsor 資金 + 允許的 move 目標（allowedMoveCallTargets）。
  - execute 傳入的 signature 形式（Enoki 是否由 ephemeral 簽名自行組裝 zkLogin 簽名）需以真實 JWT 實測；
    若 Enoki 要求「已組裝的 zkLogin 簽名」，需在客戶端組裝（見 zklogin_payment_service.dart 註記）。
"""
import base64
import logging
from typing import Any, Dict, Optional

import httpx

from app.config import settings
from app.services.zklogin_service import zklogin_service, ZkLoginError

logger = logging.getLogger(__name__)


class PaymentBuildError(Exception):
    pass


class PaymentZkLoginService:
    def __init__(self):
        self.node_url = settings.SUI_NODE_URL
        self.package_id = settings.CONTRACT_PACKAGE_ID
        self.platform_address = getattr(settings, "PLATFORM_WALLET_ADDRESS", "")

    @property
    def lock_payment_target(self) -> str:
        return f"{self.package_id}::payment_escrow::lock_payment"

    async def _pick_passenger_coins(self, passenger: str, amount_mist: int) -> list[str]:
        """
        挑出加總 >= amount 的 SUI coin 清單（Enoki 贊助 gas，coin 只需覆蓋付款額本身）。
        優先單顆足額（挑最小的足額顆，減少碎幣佔用）；沒有單顆足額時由大到小湊足，
        由呼叫端在 PTB 內 merge 後再 split——修掉「多顆小 coin 加總夠卻付不了」的問題。
        """
        async with httpx.AsyncClient(timeout=20.0) as client:
            resp = await client.post(self.node_url, json={
                "jsonrpc": "2.0", "id": 1, "method": "suix_getCoins",
                "params": [passenger, "0x2::sui::SUI", None, 50],
            })
            resp.raise_for_status()
            coins = resp.json().get("result", {}).get("data", [])

        sufficient = [c for c in coins if int(c["balance"]) >= amount_mist]
        if sufficient:
            best = min(sufficient, key=lambda c: int(c["balance"]))
            return [best["coinObjectId"]]

        picked: list[str] = []
        total = 0
        for c in sorted(coins, key=lambda c: int(c["balance"]), reverse=True):
            picked.append(c["coinObjectId"])
            total += int(c["balance"])
            if total >= amount_mist:
                return picked
        raise PaymentBuildError(
            f"乘客 {passenger[:10]}… SUI 總餘額 {total} MIST 不足支付 {amount_mist} MIST，請先領測試幣"
        )

    async def build_lock_payment_kind(
        self,
        passenger: str,
        amount_mist: int,
        trip_id: int,
        driver: str,
        platform: Optional[str] = None,
    ) -> Dict[str, Any]:
        """組 lock_payment 的交易 kind bytes（供 Enoki 贊助）。回 {kind_bytes, target, coin}。"""
        platform = platform or self.platform_address
        if not platform:
            raise PaymentBuildError("缺少 platform 位址（PLATFORM_WALLET_ADDRESS）")

        coin_ids = await self._pick_passenger_coins(passenger, amount_mist)

        try:
            from pysui import SuiConfig, SyncClient
            from pysui.sui.sui_types.address import SuiAddress
            from pysui.sui.sui_types.scalars import ObjectID, SuiU64, SuiString
            from pysui.sui.sui_txn import SyncTransaction
        except ImportError as e:  # noqa: BLE001
            raise PaymentBuildError(f"pysui 未安裝: {e}")

        # 用 operator key 僅為取得可讀 RPC 的 client 實例；sender 覆寫為乘客，且我們只序列化不簽名。
        operator_key = getattr(settings, "OPERATOR_PRIVATE_KEY", None)
        if not operator_key:
            raise PaymentBuildError("缺少 OPERATOR_PRIVATE_KEY（僅用於建立 client 實例）")

        cfg = SuiConfig.user_config(rpc_url=self.node_url, prv_keys=[operator_key])
        client = SyncClient(cfg)

        # sender = 乘客 zkLogin 位址（非 operator）
        txn = SyncTransaction(client=client, initial_sender=SuiAddress(passenger))

        # 多顆小 coin 時先在 PTB 內合併到第一顆（gas 由 Enoki 贊助，乘客 coins 可全數參與合併），
        # 再從合併後的 coin 拆出精確付款額（只鎖 amount，不鎖整顆）。單顆足額時 coin_ids 只有一顆，不 merge。
        primary = ObjectID(coin_ids[0])
        if len(coin_ids) > 1:
            txn.merge_coins(merge_to=primary, merge_from=[ObjectID(c) for c in coin_ids[1:]])
        pay_coin = txn.split_coin(coin=primary, amounts=[amount_mist])

        # 呼叫 lock_payment（平台費由合約鏈上計算，不由後端傳入）
        txn.move_call(
            target=self.lock_payment_target,
            arguments=[
                pay_coin,
                SuiU64(trip_id),
                SuiString(driver),
                SuiString(platform),
            ],
        )

        # 序列化為 transaction kind bytes（不含 gas；由 Enoki 贊助填 gas）
        kind_bytes = base64.b64encode(txn.serialize()).decode()
        logger.info(
            f"✅ 已組 lock_payment kind bytes（trip={trip_id}, amount={amount_mist}, "
            f"coins={len(coin_ids)} 顆，primary={coin_ids[0][:10]}…）"
        )
        return {"kind_bytes": kind_bytes, "target": self.lock_payment_target, "coins": coin_ids}

    async def sponsor_lock_payment(self, kind_bytes: str, passenger: str) -> Dict[str, Any]:
        """請 Enoki 贊助這筆 lock_payment。回 {bytes, digest}。"""
        return await zklogin_service.sponsor(
            tx_kind_bytes=kind_bytes,
            sender=passenger,
            allowed_move_call_targets=[self.lock_payment_target],
        )

    async def execute_lock_payment(self, digest: str, signature: str) -> Dict[str, Any]:
        """送出已簽的贊助交易，並解析 escrow_object_id。回 {digest, escrow_object_id}。"""
        result = await zklogin_service.execute_sponsored(digest, signature)
        exec_digest = result.get("digest", digest)
        escrow_id = await self._escrow_id_from_digest(exec_digest)
        return {"digest": exec_digest, "escrow_object_id": escrow_id}

    async def _escrow_id_from_digest(self, digest: str) -> Optional[str]:
        """由交易 digest 讀出建立的 Escrow shared object id。"""
        async with httpx.AsyncClient(timeout=20.0) as client:
            resp = await client.post(self.node_url, json={
                "jsonrpc": "2.0", "id": 1, "method": "sui_getTransactionBlock",
                "params": [digest, {"showObjectChanges": True, "showEffects": True}],
            })
            resp.raise_for_status()
            changes = resp.json().get("result", {}).get("objectChanges", [])
        for ch in changes:
            if ch.get("type") == "created" and "payment_escrow::Escrow" in ch.get("objectType", ""):
                return ch.get("objectId")
        return None


payment_zklogin_service = PaymentZkLoginService()
