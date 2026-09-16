"""
非託管動作（zkLogin + Enoki 贊助）— Phase 5（委託）/ Phase 6（爭議）

與 Phase 4 付款同一套機制：後端組交易 kind bytes → Enoki 贊助 → 乘客臨時金鑰簽 → Enoki 送鏈。
差別在這兩個動作不涉及 Coin（無需拆幣）：
  - issue_operator_cap：sender = user，發行委託給平台 Agent（額度/時效/動作白名單）。需 Clock(0x6)。
  - raise_dispute：sender = user（須為 escrow 的 passenger 或 driver），凍結該 escrow。

move 目標一律由後端決定（不由前端傳），sender 取自登入 JWT，避免冒名/亂呼叫。

⚠️ 與 Phase 4 相同的待驗證點：Enoki portal 需設 sponsor 資金 + allowedMoveCallTargets；
   execute 接受「臨時簽名 vs 已組裝 zkLogin 簽名」需以真實 JWT 實機測。
"""
import base64
import logging
from typing import Any, Dict, Optional

import httpx

from app.config import settings
from app.services.zklogin_service import zklogin_service

logger = logging.getLogger(__name__)

# 動作白名單 bits（對齊 agent_registry.move）
ACTION_RELEASE_ESCROW = 1
ACTION_REFUND = 2
MS_PER_DAY = 86_400_000


class ZkTxBuildError(Exception):
    pass


class ZkLoginTxService:
    def __init__(self):
        self.node_url = settings.SUI_NODE_URL
        self.package_id = settings.CONTRACT_PACKAGE_ID
        # 平台位址同時作為被授權的 Agent
        self.agent_address = settings.PLATFORM_WALLET

    def _txn_for(self, sender: str):
        """建立 pysui 交易 builder，只用來產生 TransactionKind（不簽名、不送出）。

        注意：TransactionKind 的 BCS 不含 sender / gas；乘客位址（sender）是在 Enoki
        sponsor 時另外傳的。builder 的 initial_sender 必須是 keystore 內的位址（pysui 會
        解析成 keypair），故一律用 operator 位址建，`sender` 參數僅保留供呼叫端語意。
        """
        try:
            from pysui import SuiConfig, SyncClient
            from pysui.sui.sui_types.address import SuiAddress
            from pysui.sui.sui_txn import SyncTransaction
        except ImportError as e:  # noqa: BLE001
            raise ZkTxBuildError(f"pysui 未安裝: {e}")

        operator_key = getattr(settings, "OPERATOR_PRIVATE_KEY", None)
        if not operator_key:
            raise ZkTxBuildError("缺少 OPERATOR_PRIVATE_KEY（僅用於建立 client 實例）")
        cfg = SuiConfig.user_config(rpc_url=self.node_url, prv_keys=[operator_key])
        client = SyncClient(cfg)
        return SyncTransaction(client=client)  # 預設 sender = keystore 的 active address（operator）

    # ── Phase 5：發行委託 ─────────────────────────────────────
    def issue_operator_cap_target(self) -> str:
        return f"{self.package_id}::agent_registry::issue_operator_cap"

    def build_issue_operator_cap(
        self,
        user: str,
        max_spend_mist: int,
        daily_limit_mist: int,
        valid_for_ms: int,
        allowed_actions: int = ACTION_RELEASE_ESCROW | ACTION_REFUND,
        agent: Optional[str] = None,
    ) -> Dict[str, str]:
        agent = agent or self.agent_address
        if not agent:
            raise ZkTxBuildError("缺少 agent 位址（PLATFORM_WALLET_ADDRESS）")
        from pysui.sui.sui_types.scalars import ObjectID, SuiU64, SuiString

        txn = self._txn_for(user)
        txn.move_call(
            target=self.issue_operator_cap_target(),
            arguments=[
                SuiString(agent),
                SuiU64(max_spend_mist),
                SuiU64(daily_limit_mist),
                SuiU64(valid_for_ms),
                SuiU64(allowed_actions),
                ObjectID("0x6"),  # Clock
            ],
        )
        return {"kind_bytes": base64.b64encode(txn.raw_kind().serialize()).decode(),
                "target": self.issue_operator_cap_target()}

    # ── Phase 6：發起爭議 ─────────────────────────────────────
    def raise_dispute_target(self) -> str:
        return f"{self.package_id}::payment_escrow::raise_dispute"

    def build_raise_dispute(self, user: str, escrow_id: str, reason: str) -> Dict[str, str]:
        from pysui.sui.sui_types.scalars import ObjectID

        txn = self._txn_for(user)
        txn.move_call(
            target=self.raise_dispute_target(),
            arguments=[
                ObjectID(escrow_id),          # &mut Escrow（shared）
                list(reason.encode("utf-8")),  # reason: vector<u8>
            ],
        )
        return {"kind_bytes": base64.b64encode(txn.raw_kind().serialize()).decode(),
                "target": self.raise_dispute_target()}

    # ── 贊助 / 送出 ──────────────────────────────────────────
    async def sponsor(self, kind_bytes: str, sender: str, target: str) -> Dict[str, Any]:
        return await zklogin_service.sponsor(
            tx_kind_bytes=kind_bytes, sender=sender, allowed_move_call_targets=[target],
        )

    async def execute(self, digest: str, signature: str, created_type_suffix: str) -> Dict[str, Any]:
        """送出簽好的贊助交易，回傳建立之物件 id（依 type 後綴過濾）。"""
        result = await zklogin_service.execute_sponsored(digest, signature)
        exec_digest = result.get("digest", digest)
        object_id = await self._created_object_id(exec_digest, created_type_suffix)
        return {"digest": exec_digest, "object_id": object_id}

    async def _created_object_id(self, digest: str, type_suffix: str) -> Optional[str]:
        async with httpx.AsyncClient(timeout=20.0) as client:
            resp = await client.post(self.node_url, json={
                "jsonrpc": "2.0", "id": 1, "method": "sui_getTransactionBlock",
                "params": [digest, {"showObjectChanges": True}],
            })
            resp.raise_for_status()
            changes = resp.json().get("result", {}).get("objectChanges", [])
        for ch in changes:
            if ch.get("type") == "created" and type_suffix in ch.get("objectType", ""):
                return ch.get("objectId")
        return None


zklogin_tx_service = ZkLoginTxService()
