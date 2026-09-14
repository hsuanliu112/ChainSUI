# CLAUDE.md — ChainSUI

去中心化叫車 DePIN 平台。**Side project，目標是把它做到生產級品質**（已不參加 Sui Overflow 2026，沒有賽程死線；品質與安全標準照舊，不因此鬆綁）。

## 目前的主線工作：生產級加固

我們正在把程式碼從 hackathon 原型提升到「上主網生產級」。
**接手任何工作前，先讀 [`docs/PRODUCTION_HARDENING_ROADMAP.md`](docs/PRODUCTION_HARDENING_ROADMAP.md)** — 那是本次重構的單一事實來源，含問題清單、優先序、各 Agent 分工、進度追蹤與驗證方式。
完成工作後**務必更新該檔的 §7 進度追蹤與 §8 變更日誌**。

## 關鍵事實（勿再重新調查）

- **鏈是 Sui（testnet）**，不是 IOTA。IOTA 遺留死碼已於 2026-09-05 全數清除
  （`contracts/iota-src/`、`iota_contract_service.py`、`contract_integration.py`、`run_tests.sh`）。
  不得復活任何 iota_* 程式。
- **Package ID / 平台位址不得硬編碼在任何文件或程式中**。
  唯一事實來源：`mobile/lib/config/app_config.dart` 的 `contractPackageId` / `platformAddress`。
  2026-09-14 金鑰輪替後以新錢包重新部署，`contracts/Published.toml` / `Move.lock` 已同步為新 package；
  舊文件中的 `0xb761c6f5…`、`0xa6232c…`、`0xda64…` 均為**死值**；需要 ID 時先讀 app_config.dart。
- Move 命名空間：`autodrive::*`（financial + identity/DID）、`decentralized_ride::*`
  （registries/rating/receipt）、`agent_registry`（OperatorCap 委託）。
- 後端：FastAPI + Postgres + `pysui==0.65.0`。已知坑：
  - 無 `SuiConfig.testnet()`，用 `SuiConfig.user_config`。
  - 無 zkLogin 簽名組裝 → zkLogin 交易一律走 **Enoki 贊助**路徑（prepare → 前端簽 → execute）。
- 行動端：Flutter（僅 ios + web）。**本開發環境無 Flutter**：凡改到 `mobile/`，
  回報中必須標註「待使用者本機 flutter build 驗證」，不得宣稱已驗證。
- 大容量資料（軌跡 / 評價內容 / 退款佐證）走 **Walrus**，鏈上只存 `blob_id` + `content_hash`；
  單節點 IPFS 已淘汰。
- 🔑 平台 operator 私鑰曾入庫洩漏（`test_wallet_info.txt`，仍在 git 歷史）→ **已於 2026-09-14 輪替**：
  新錢包重新部署整套合約，舊錢包 `0x013a90ee…` 已清空作廢。**任何時候都不得復用該舊地址/舊 package**。
  Mapbox pk token 輪替仍待使用者（見 USER_ACTION_ITEMS）。

## 2. 鐵律（違反即視為任務失敗）

1. **禁止 mock 冒充真交易**：不得回傳假 hash、不得「失敗即降級為假成功」。
   鏈上失敗就明確拋錯 + 記 log。模擬行為只允許存在於 `MOCK_MODE` 分支。
2. **fail-closed**：缺金鑰、缺設定、proof 無效 → 拒絕服務，不得走 simulated fallback。
3. **秘密零外洩**：私鑰 / API key 只能存在 `.env` 或 gitignored 的 `*.local.dart`。
   提交前自查：`git grep -nE "AIza|suiprivkey|BEGIN.*KEY" -- ':!*.local.*'` 應 0 命中。
   任何 tracked 檔出現金鑰 = CRITICAL，立即停手回報。
4. **授權優先**：資金移動與狀態變更的 Move 函式必須有存取控管
   （Capability 物件、witness 或 sender 斷言）；escrow release / refund 需乘客簽章
   或有效 `OperatorCap`（額度、時效、動作白名單）。
5. **刪除死碼前必查引用**：`grep -rn` 確認 0 引用才可刪
   （先例：`payment_page` 曾被誤判為死碼，實為現行付款流程）。
6. 文件與註解使用**繁體中文**，不得出現簡體字。
7. 提交訊息結尾加：`Co-Authored-By: Claude <noreply@anthropic.com>`

## 3. 驗證迴圈（每次修改後依觸及範圍執行；沒跑驗證 = 沒有完成）

| 觸及範圍 | 指令 | 通過標準 |
|---|---|---|
| Move | `cd contracts && sui move build` | 0 error |
| Move | `cd contracts && sui move test` | failed=0，總數不低於 roadmap §7/§8 最後記載（只增不減） |
| 後端 | `python -m py_compile $(git diff --name-only -- '*.py')` | 全過 |
| 後端 | `docker compose logs backend --tail 50` | `Application startup complete`、無 Traceback |
| Dashboard | `cd dashboard && npm run build` | build 成功 |
| Flutter | （本環境不可執行） | 標註待使用者本機驗證 |
| 部署 | `scripts/ops/deploy_and_init.sh` | object ID 全數印出並回填 `.env` |

失敗處理：讀錯誤 → 修 → 重跑。**同一錯誤連續 3 次未解 → 停手，
在 roadmap §7 標 ⛔ 並回報人工**，不得繼續空轉或繞過驗證。

## 4. 完成定義（Definition of Done，全滿足才算完成）

- [ ] §3 對應驗證全綠（測試數只增不減）
- [ ] 無新增 mock fallback、無秘密外洩（鐵律 1–3 自查）
- [ ] roadmap §7 狀態已更新（⬜/🟡/✅/⛔）
- [ ] roadmap §8 新增一筆：`YYYY-MM-DD · [工作包代號] · 摘要 · 影響檔案`（最新在上）
- [ ] 回報：改了什麼 / 為什麼 / 如何驗證 / 剩餘風險

## 5. Subagent 分工

主 session 是**協調者**：讀 roadmap、拆任務、派工、整合、更新進度。
專項工作委派給 `.claude/agents/` 下的 subagent：

- `move-auditor` — 唯讀安全審查 + 跑 `sui move test`（不寫程式）。
  觸發時機：任何 `contracts/sources/**/*.move` 修改之後。
- `backend-test-author` — 維護/擴充 `backend/tests/integration/` 回歸測試
  （G2 已完成，現為長期角色；只寫 `backend/tests/`，不改業務邏輯）。
  觸發時機：後端功能變更後跑回歸、或需要為新功能補測試時。

派工規則：subagent 間**不共享狀態**、各自對應獨立檔案集；唯讀審查與可寫實作分離；
subagent 結論回到主 session 後，仍以 §3 驗證為準。

## 6. 常用指令

```bash
# 合約
cd contracts && sui move build
cd contracts && sui move test

# 後端（日常以 docker compose 為準；改 .env 後需 force-recreate 才會載入）
docker compose up -d
docker compose up -d --force-recreate backend
docker compose logs backend --tail 50 -f

# 部署與初始化
scripts/ops/deploy_and_init.sh
scripts/ops/fund_refund_pool.sh
```

## 7. 目前優先序（快照，以 roadmap §7 為準；發現不一致以 roadmap 為準並回頭更新本節）

1. ⬜ **C2-mobile** 客戶端本地產證（`mobile/assets/zkp/*.wasm/*.zkey`，停止送原始 PII）
2. 🟡 zkLogin Phase 4/5/6 實機驗證（Enoki sponsor 設定 + 真實簽名格式，需使用者
配合）
3. 🟡 **D2 收尾** per-user cap 發現（passenger → cap_object_id 映射）+
   `trip_service.complete_trip` 放款改走 `agent_service`
4. ✅ operator 金鑰輪替（2026-09-14 完成，新錢包重新部署）；🟡 Enoki Portal 的 allowedMoveCallTargets 改指新 package（使用者手動）

（✅ 已完成不再列入：G2 整合測試 43/43、G1 Move 安全測試、P0 合約/後端加固）