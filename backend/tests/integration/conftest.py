"""
G2 後端整合測試 harness。

原則（見 docs/PRODUCTION_HARDENING_ROADMAP.md §5 P2）：
  - 外部依賴（Sui RPC、Walrus、DB、snarkjs）一律用可注入的 fake。
  - 絕不製造假交易 hash 冒充真實上鏈；測試反而要驗證「鏈上失敗 → 明確報錯」。
  - 可在 backend 容器內直接執行：docker compose exec backend python -m pytest
"""
import os

# 在 import app.* 之前備妥 config fail-fast 需要的最小環境。
# 容器內已有真實環境變數時 setdefault 不會覆蓋。
os.environ.setdefault("SECRET_KEY", "integration-test-only-secret")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://unused:unused@localhost:5432/unused")
os.environ.setdefault("MOCK_MODE", "false")
os.environ.setdefault("OPERATOR_PRIVATE_KEY", "suiprivkey1-test-placeholder-never-used")
# agent_service / payment 等服務在建構時讀 CONTRACT_PACKAGE_ID；乾淨環境（CI 無 .env）
# 下若為空會提早 return「缺少 CONTRACT_PACKAGE_ID」，使依賴鏈上路徑的測試拿到非預期錯誤。
# 給一個良構 dummy（64 hex）；容器有真值時 setdefault 不覆蓋。
os.environ.setdefault("CONTRACT_PACKAGE_ID", "0x" + "ab" * 32)
os.environ.setdefault("PLATFORM_WALLET_ADDRESS", "0x" + "cd" * 32)

from types import SimpleNamespace

import pytest


class FakeResult:
    """模擬 SQLAlchemy execute() 的回傳。"""

    def __init__(self, value=None, many=None):
        self._value = value
        self._many = list(many or [])

    def scalar_one_or_none(self):
        return self._value

    def scalars(self):
        many = list(self._many)
        return SimpleNamespace(
            all=lambda: list(many),
            first=lambda: (many[0] if many else None),
        )


class FakeSession:
    """依呼叫順序回傳預排的查詢結果；記錄 commit / rollback / add。"""

    def __init__(self, results=None):
        self.results = list(results or [])
        self.commits = 0
        self.rollbacks = 0
        self.added = []
        self._next_id = 1

    async def execute(self, *_args, **_kwargs):
        if not self.results:
            raise AssertionError("FakeSession: 查詢次數超出預期")
        return self.results.pop(0)

    def add(self, obj):
        self.added.append(obj)

    async def commit(self):
        self.commits += 1

    async def rollback(self):
        self.rollbacks += 1

    async def refresh(self, obj):
        # 模擬 DB flush 後回填自增主鍵：讓 record.id 從 None 變成有值，
        # 使 agent_brain._record 之後能取用 record.id（decision_id）。
        if getattr(obj, "id", None) is None:
            try:
                obj.id = self._next_id
                self._next_id += 1
            except (AttributeError, TypeError):
                pass


@pytest.fixture
def fake_session_factory():
    return lambda results=None: FakeSession(results)
