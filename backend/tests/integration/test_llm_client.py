"""
llm_client：決策層的 fail-open 行為驗證。

這一層不是安全邊界（邊界在 agent_guardrails + 鏈上 cap），因此：
  - 缺 base_url / model 或 AGENT_LLM_ENABLED=false → enabled=False。
  - enabled=False 時 complete_json 直接回 None，且**絕不**發出任何 HTTP。
  - _extract_json 能剝 markdown fence；壞字串回 None（讓上層 fallback）。
"""
import httpx
import pytest

from app.config import settings
from app.services.llm_client import LLMClient


# --- enabled 判定 ---------------------------------------------------------

def test_enabled_true_when_all_present(monkeypatch):
    monkeypatch.setattr(settings, "AGENT_LLM_ENABLED", True)
    client = LLMClient(base_url="http://llm.local/v1", model="qwen2.5")
    assert client.enabled is True


def test_enabled_false_when_flag_off(monkeypatch):
    monkeypatch.setattr(settings, "AGENT_LLM_ENABLED", False)
    client = LLMClient(base_url="http://llm.local/v1", model="qwen2.5")
    assert client.enabled is False


def test_enabled_false_when_missing_base_url(monkeypatch):
    # 直接測 enabled property：base_url 為空 → False（不依賴 __init__ 的 settings fallback，
    # 也不受 .env 是否已設 LLM_BASE_URL 影響）。
    monkeypatch.setattr(settings, "AGENT_LLM_ENABLED", True)
    client = LLMClient(base_url="http://llm.local/v1", model="qwen2.5")
    client.base_url = ""
    assert client.enabled is False


def test_enabled_false_when_missing_model(monkeypatch):
    monkeypatch.setattr(settings, "AGENT_LLM_ENABLED", True)
    client = LLMClient(base_url="http://llm.local/v1", model="qwen2.5")
    client.model = ""
    assert client.enabled is False


# --- complete_json fail-open ---------------------------------------------

async def test_complete_json_returns_none_when_disabled_without_http(monkeypatch):
    """未啟用時直接回 None，且不得建立任何 HTTP client。"""
    monkeypatch.setattr(settings, "AGENT_LLM_ENABLED", False)

    def _boom(*_a, **_kw):
        raise AssertionError("disabled 時不應發出 HTTP")

    monkeypatch.setattr(httpx, "AsyncClient", _boom)

    client = LLMClient(base_url="http://llm.local/v1", model="qwen2.5")
    result = await client.complete_json("sys", "user")
    assert result is None


# --- _extract_json --------------------------------------------------------

def test_extract_json_plain_object():
    obj = LLMClient._extract_json('{"action": "release", "amount_mist": 100}')
    assert obj == {"action": "release", "amount_mist": 100}


def test_extract_json_strips_markdown_fence():
    fenced = '```json\n{"action": "refund", "confidence": 0.9}\n```'
    obj = LLMClient._extract_json(fenced)
    assert obj == {"action": "refund", "confidence": 0.9}


def test_extract_json_strips_leading_text():
    noisy = '好的，這是我的決策：{"action": "flag_review"} 以上。'
    obj = LLMClient._extract_json(noisy)
    assert obj == {"action": "flag_review"}


def test_extract_json_garbage_returns_none():
    assert LLMClient._extract_json("這完全不是 JSON，沒有大括號") is None


def test_extract_json_broken_braces_returns_none():
    assert LLMClient._extract_json('{"action": "release", ') is None


def test_extract_json_array_returns_none():
    """頂層是陣列（非 dict）→ 回 None（呼叫端只接受物件）。"""
    assert LLMClient._extract_json('[1, 2, 3]') is None
