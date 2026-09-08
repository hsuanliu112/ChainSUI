"""
I1-a 回歸測試：payment_zklogin_service._pick_passenger_coins 的 coin 挑選/合併邏輯。

修的 bug：舊 _pick_passenger_coin 只挑「單顆足額」的 coin，乘客有多顆小 coin
加總足夠也會付款失敗。新版：單顆足額優先（挑最小的足額顆），否則由大到小湊足，
加總仍不足才報錯（訊息帶目前總餘額）。外部 RPC 用 fake httpx 注入，不打真鏈。
"""
import httpx
import pytest

from app.services import payment_zklogin_service as mod
from app.services.payment_zklogin_service import PaymentBuildError


class _FakeResp:
    def __init__(self, coins):
        self._coins = coins

    def raise_for_status(self):
        pass

    def json(self):
        return {"result": {"data": self._coins}}


class _FakeAsyncClient:
    """替身 httpx.AsyncClient：回注入的 coin 清單。"""

    coins = []

    def __init__(self, *a, **k):
        pass

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def post(self, url, json=None):
        return _FakeResp(type(self).coins)


def _coin(obj_id, balance):
    return {"coinObjectId": obj_id, "balance": str(balance)}


@pytest.fixture
def fake_coins(monkeypatch):
    _FakeAsyncClient.coins = []
    monkeypatch.setattr(httpx, "AsyncClient", _FakeAsyncClient)
    return _FakeAsyncClient


def _svc():
    return mod.PaymentZkLoginService()


@pytest.mark.asyncio
async def test_single_sufficient_coin_returns_one(fake_coins):
    # 有單顆足額 → 只回一顆（且挑最小的足額顆，減少碎幣佔用）
    fake_coins.coins = [_coin("0xa", 5_000_000_000), _coin("0xb", 2_000_000_000)]
    picked = await _svc()._pick_passenger_coins("0xpassenger", 1_000_000_000)
    assert picked == ["0xb"]  # 2 SUI 是較小的足額顆


@pytest.mark.asyncio
async def test_no_single_but_total_enough_returns_multiple(fake_coins):
    # 沒有單顆足額，但多顆加總足夠 → 回多顆（由大到小），交呼叫端在 PTB 內 merge
    fake_coins.coins = [
        _coin("0xa", 400_000_000),
        _coin("0xb", 400_000_000),
        _coin("0xc", 400_000_000),
    ]
    picked = await _svc()._pick_passenger_coins("0xpassenger", 1_000_000_000)
    assert len(picked) == 3
    assert set(picked) == {"0xa", "0xb", "0xc"}


@pytest.mark.asyncio
async def test_partial_multiple_stops_when_enough(fake_coins):
    # 由大到小累加，湊夠就停（不必用到全部）
    fake_coins.coins = [
        _coin("0xbig", 700_000_000),
        _coin("0xmid", 400_000_000),
        _coin("0xsmall", 100_000_000),
    ]
    picked = await _svc()._pick_passenger_coins("0xpassenger", 1_000_000_000)
    # 700 + 400 = 1100 >= 1000，第三顆不需要
    assert picked == ["0xbig", "0xmid"]


@pytest.mark.asyncio
async def test_total_insufficient_raises_with_total(fake_coins):
    # 加總仍不足 → 明確報錯，訊息含目前總餘額
    fake_coins.coins = [_coin("0xa", 300_000_000), _coin("0xb", 200_000_000)]
    with pytest.raises(PaymentBuildError) as ei:
        await _svc()._pick_passenger_coins("0xpassenger", 1_000_000_000)
    msg = str(ei.value)
    assert "500000000" in msg  # 目前總餘額
    assert "1000000000" in msg  # 需要的金額


@pytest.mark.asyncio
async def test_no_coins_raises(fake_coins):
    fake_coins.coins = []
    with pytest.raises(PaymentBuildError):
        await _svc()._pick_passenger_coins("0xpassenger", 1_000_000_000)
