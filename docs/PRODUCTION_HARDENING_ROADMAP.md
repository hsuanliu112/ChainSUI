# ChainSUI 生產級加固路線圖 (Production Hardening Roadmap)

> **這份文件是本次「上主網生產級」重構的單一事實來源 (Single Source of Truth)。**
> 任何 agent（Move 合約、後端、行動端、測試）接手前**必讀本檔**，並在完成工作後更新 [§7 進度追蹤](#7-進度追蹤-progress-tracker) 與 [§8 變更日誌](#8-變更日誌-changelog)。

- **專案**：ChainSUI — 去中心化叫車 DePIN 平台
- **目標**：side project，做到生產級品質（原 Sui Overflow 2026 參賽計畫已於 2026-09 取消，品質標準不變）
- **鏈**：Sui（testnet framework）。**注意：舊 IOTA 遺留（`iota_*` 服務等）是死碼，不要沿用；`contracts/iota-src/` 已於 2026-09-05 刪除。**
- **審查基準日**：2026-07-12
- **狀態圖例**：⬜ 未開始 / 🟡 進行中 / ✅ 完成 / ⛔ 卡住（需人工）

---

## 1. 為什麼要做這件事 (Context)

對 12 個已實作 Move 模組、後端 Sui 整合層、ZKP/DID 子系統做生產級審查後，發現**距離上主網有致命差距**：

1. **資金可被任意掏空** — 退款池與託管釋放缺存取控管。
2. **身分驗證形同虛設** — 鏈上 Groth16 驗證是 stub（只檢查 `length(proof) > 0`）。
3. **Agentic 主題未落地** — 「AI Agent」是規則式運算，且用**單一平台私鑰代表所有人簽章**，鏈上零授權委託。
4. **私鑰明碼** — 真實 Sui operator 私鑰、Google/FCM 金鑰寫在 `.env`。
5. **鏈上寫入多為 mock** — 大量流程回傳 `sha256` 假交易 hash 且 `success:True`。
6. **無去中心化存儲** — 批量資料全在 Postgres，GPS 軌跡根本沒落地，完全沒有 Walrus。

**產出要求**：先條列問題與「為什麼」，再提供**修改後、完整可運行**的 Move / Python 程式碼；並將 Agent 能力委託與 Walrus 端到端整合納入。

---

## 2. 架構事實（已確認，勿再重新調查）

| 項目 | 事實 |
|---|---|
| 框架 | Sui framework `testnet`（`Move.toml`/`Move.lock` 實際解析）。所有 source `use sui::`，無 `iota::`。 |
| 已發布 package | `contracts/Published.toml` → testnet `0xa6232c7f85812fe5e57c2e72071915e538ebd2fd7aba98371bd58490e790380b` |
| 已實作 Move 模組 | 12 個（見 §3）。另有 7 個 0-byte 空檔（`platform_controller.move` 等），對應測試無法編譯。 |
| 命名空間 | `autodrive::*`（financial + identity-DID）與 `decentralized_ride::*`（registries/rating/receipt），皆解析到同一 `0x0` package。 |
| 後端簽章 | 單一平台 `OPERATOR_PRIVATE_KEY`，用 `pysui==0.65.0`。**無 Capability 委託**。 |
| 鏈上寫入現況 | 大多 mock（假 hash）。真正會嘗試上鏈的只有 `sui_service.call_contract_lock_payment/release_payment`，但失敗即降級回假 hash。 |
| AI Agent | 100% 規則式，無 LLM。報價 = 線性公式；搓合 = 最近距離排序。 |
| 大容量資料 | 全在 Postgres。GPS 軌跡經 Socket.IO 廣播後**不落地**。IPFS 僅用於退款佐證（本地單節點）。**無 Walrus**。 |
| ZKP | snarkjs/Groth16，兩個電路（age、license）。**證明在後端產生（收原始 PII）**、後端 snarkjs 驗證。鏈上驗證是 stub。 |

---

## 3. 受影響模組地圖

**Move（`contracts/sources/`）**
- `financial/payment_escrow.move` — 託管（release 無授權 ⚠️）
- `financial/refund_module_v2.move` — 退款池（submit_for_auto_refund 可掏空 ⚠️⚠️）
- `financial/refund_module.move` — v1 舊版（建議刪除）
- `identity/credential_verifier.move` — ZKP 驗證 stub ⚠️
- `identity/user_registry.move` — 自我提權 ⚠️
- `identity/did_registry.move` — 弱格式驗證、borrow-before-exists
- `identity/{vehicle_registry,trusted_issuers}.move`
- `business/rating_proof.move` — 評分可被任意竄改 ⚠️
- `business/trip_receipt.move` — 僅記錄，加 Walrus 錨定欄位
- `utils/{constants,events}.move`（其餘 utils 為空檔）
- **新增** `agent/agent_registry.move` — OperatorCap 委託

**後端（`backend/app/`）**
- `config.py`、`.env`（+ repo 根 `docker-compose.yml`）
- `services/{sui_service,contract_service,escrow_service,refund_service_v2,wallet_service}.py`
- `services/{zkp_prover,zkp_verifier,identity_service}.py`
- `api/v1/{refunds,wallet,payment_proxy,zkp}.py`、`main.py`
- **新增** `services/{agent_service,walrus_service}.py`
- **刪除死碼**：`iota_*`、`real_blockchain_service.py`、`matching_service.py`、`refund_service.py`(v1)、`api/v1/{blockchain,iota,contract_integration}.py`

**行動端（`mobile/lib/`）**
- `services/zkp_service.dart`（改客戶端產證）、`mobile/assets/zkp/`

---

## 4. 執行優先序與 Agent 分工

> **P0 必須先於 P1，P1 先於 P2。** 每個 Agent 對應一組獨立工作包，可在同優先層內並行。

| # | 優先 | 工作包 | 負責 Agent | 依賴 |
|---|---|---|---|---|
| 1 | **P0** | Move 致命漏洞修復（escrow / refund / 自我提權 / did） | `move-security-fixer` | 需先有 #3 的 OperatorCap |
| 2 | **P0** | 後端秘密外洩 + 移除 mock 假交易 | `backend-secrets-fixer` | — |
| 3 | **P0** | ZKP 真驗證（`sui::groth16`）+ 客戶端產證 | `zkp-onchain-verifier` | — |
| 4 | **P1** | Agent 能力委託 `agent_registry` + PTB | `agent-capability-designer` | 阻擋 #1 的 release 授權 |
| 5 | **P1** | 後端 Agent runtime（附 cap 送單） | `agent-backend-integrator` | #4 |
| 6 | **P1** | Walrus 端到端（軌跡/評價/佐證） | `walrus-storage-integrator` + `move-anchor-author` | — |
| 7 | **P2** | PTB 合併、on-chain 瘦身、死碼清理 | `sui-gas-optimizer` + `deadcode-cleaner` | #1–#6 |
| 8 | **P2** | Move + 後端測試 | `move-test-author` + `backend-test-author` | #1–#6 |

> **排程備註**：#4（OperatorCap）是 #1 escrow release 授權的前置，因此實作順序為 **#4 → #1**，其餘 P0 可並行。

---

## 5. 詳細工作規格 (Task Specs)

每項格式：**問題 → 為什麼 → 修法 → 檔案**。逐行行號見 `~/.claude/plans/parsed-rolling-cerf.md` 與審查報告。

### P0-A · Move 致命漏洞

**A1. `refund_module_v2::submit_for_auto_refund` 可掏空退款池 (CRITICAL)**
- 問題：此 entry 無 `RefundCapability`、無 sender 檢查即從共享 `RefundPoolV2.balance` 出金給 `requester`；`create_refund_request` 讓任何人自填 `refund_amount`。
- 為什麼：共享物件的資金移動函式無能力物件把關＝無鎖金庫。
- 修法：**刪除** `submit_for_auto_refund`；所有出金走 `approve_and_execute`（已需 `&RefundCapability`）。退款金額改由鏈上託管餘額決定，不接受呼叫者自填。
- 檔案：`financial/refund_module_v2.move`

**A2. `payment_escrow::release_payment` 任何人可強制放款 (CRITICAL)**
- 問題：`Escrow` 為 shared object，release 只檢查 status/trip_id，無授權；用完的空 `Escrow` 永不刪除。
- 為什麼：託管信任模型要求「只有被授權者能觸發放款」。
- 修法：release 需授權來源之一 — (a) 乘客本人簽章確認完成，或 (b) 持 `OperatorCap`（見 P1-A）。放款後 `object::delete` 拆空 `Escrow`。退款同理加授權與時效。
- 檔案：`financial/payment_escrow.move`（依賴 `agent/agent_registry.move`）

**A3. 自我提權：`user_registry` / `rating_proof` (HIGH)**
- 問題：`user_registry::{update_reputation,add_ride,add_drive}` 為無 cap 的 `public fun`，owner 可在 PTB 自抬信譽越過 `can_drive`；`rating_proof::{create_rating_proof,create_vehicle_stats,update_vehicle_stats}` 無把關，任何人可竄改任一車評分（Sybil）。
- 為什麼：狀態變更對呼叫者身分零約束。
- 修法：跨模組狀態變更改需 witness / 平台 cap；評分寫入須綁定有效 `TripReceipt`（rater 必為該行程乘客）；`VehicleRatingStats` 以 registry Table 收斂為每車唯一。
- 檔案：`identity/user_registry.move`、`identity/vehicle_registry.move`、`business/rating_proof.move`

**A4. 合約強化**
- `did_registry`：補 DID 內嵌 address 與 `controller` 一致性（現 TODO）；`update/deactivate` 先查存在再 `borrow_mut`；`active_dids - 1` 防下溢。
- 時間戳統一為 `sui::clock::Clock`。
- 啟用 `constants::PLATFORM_FEE_RATE`（2.5%）鏈上計費，移除自填 `platform_fee`。
- 檔案：`identity/did_registry.move`、`utils/constants.move`、`financial/payment_escrow.move`

### P0-B · 後端秘密與真實鏈上寫入
- **秘密外洩 (CRITICAL)**：`.env` 有真實 `OPERATOR_PRIVATE_KEY` / `GOOGLE_MAPS_API_KEY` / `FCM_SERVER_KEY` / 弱 JWT。→ **視為已洩漏，立即輪替**；改由 secret manager 注入；移除 `config.py` 弱預設（缺值 fail-fast）；修 `wallet_service.py` salt（現用 `sha256(password)` 當 salt）。
- **mock 冒充真交易 (HIGH)**：移除所有「失敗即回假 hash」fallback，改明確拋錯 + 重試 + 告警；補齊 escrow/refund 真實 pysui 交易（走 PTB）。CORS/Socket.IO `*` → 白名單；補回 `refunds.py` 被註解的 admin 驗證；`wallet.py` 建錢包端點加驗證。
- 檔案：見 §3。

### P0-C · ZKP 端到端
- 鏈上改用 `sui::groth16::verify_groth16_proof(&pvk, &public_inputs, &proof_points)`；`VerificationKey` 存完整 vk bytes 並綁 `credential_type`；`register_verification_key` 加 `AdminCap`；補 `verify_license_credential` 的 deactivated 檢查。
- 客戶端產證：`mobile/lib/services/zkp_service.dart` 改用 `mobile/assets/zkp/*.wasm/*.zkey` 本地產證，後端/鏈上只收 proof + public signals。
- 移除 `zkp_prover.py` / `zkp_verifier.py` 的 simulated fallback（`public_signals[0]==1` 即過）。

### P1-A · Agent 能力委託（Agentic 核心）
- 新增 `contracts/sources/agent/agent_registry.move`：`OperatorCap { user, agent, max_spend_per_tx, daily_limit, spent_today, valid_until, allowed_actions }`。用戶簽發一次授權給 Agent；Agent 代發交易時各 entry 斷言 agent==sender、未過期、金額/累計在限、動作在白名單；用戶可 `revoke`。以 **PTB 原子化**：一筆完成「驗證完成→release→記 receipt→更新評分」。
- 後端 `agent_service.py` 包裝現有規則式報價/搓合為 Agent 決策層，觸發鏈上動作附 `OperatorCap` 走 PTB。

### P1-B · Walrus 端到端
- 新增 `backend/app/services/walrus_service.py`：封裝 publisher/aggregator（`PUT/GET /v1/blobs`）、epoch/存活期、重試、content-hash 驗證。
- 三條路徑（後端上傳 Walrus → 取 `blob_id` → Move 錨定 `blob_id`+`content_hash` → 讀取時比對 hash）：
  1. 行車軌跡：`app/websocket/events.py` 累積 GPS → 行程結束上傳 → `TripReceipt.trajectory_blob_id`
  2. 評價媒體/文字：`rating_service` → `RatingProof.content_blob_id`（+ 現有 32-byte `content_hash`）
  3. 退款佐證：`refund_requests.evidence_cid`(IPFS) → Walrus `evidence_blob_id`
- Move 端於 `trip_receipt.move`/`rating_proof.move`/`refund_module_v2.move` 加 `blob_id`/`content_hash` 欄位。淘汰單節點 `ipfs_service.py`。

### P2 · 優化與測試
- PTB 合併（accept→lock、complete→release、receipt、rating 併單）；on-chain 瘦身（大資料改指 Walrus blob）；死碼清理（IOTA 遺留、空 module、`run_tests.sh`→`sui move test`）。
- Move 測試：退款池授權、escrow release 授權、OperatorCap 額度/時效邊界、Groth16 正反例、評分需綁行程。
- 後端測試：escrow/refund 真實鏈上路徑、Agent PTB、Walrus 上傳/讀取/hash、ZKP 端到端。

---

## 6. 驗證方式 (Verification)

0. 部署：`scripts/ops/deploy_and_init.sh`（發布套件並印出所有 registry/pool/cap 的 object ID，貼進 `backend/.env`；範例見 `backend/.env.example`）。
1. `cd contracts && sui move build`（全編譯、無 IOTA 殘留）→ `sui move test`（P2 測試全綠，目前 9/9 PASS）。
2. Testnet 部署後驗證攻擊已封堵：
   - 非 cap 帳號呼叫舊 `submit_for_auto_refund` / `release_payment` → 應 abort。
   - 偽造空 proof 呼叫 `verify_age_credential` → 應 abort。
   - 用戶自呼 `update_reputation` 自抬信譽 → 應 abort。
3. 後端：移除 `.env` 私鑰後仍能從 secret manager 啟動；escrow lock→release 走真 PTB，Sui explorer 查得真實 tx（非 sha256 假 hash）。
4. Agent：模擬一趟行程，Agent 持 `OperatorCap` 在額度內完成 release；超額/過期 → 交易被拒。
5. Walrus：行程結束後軌跡上 Walrus，`blob_id` 出現在 `TripReceipt`，後端讀回並通過 content-hash 驗證。
6. 掃描確認無明碼私鑰、CORS 白名單生效、mock fallback 已移除。

---

## 7. 進度追蹤 (Progress Tracker)

> 每個 Agent 完成工作後更新此表對應列的狀態，並在 §8 追加一筆日誌。

### P0 — 安全止血
- [x] ✅ **A1** 刪除 `submit_for_auto_refund`，退款一律走 cap `refund_module_v2.move`
- [x] ✅ **A2** `payment_escrow.release_payment` 加授權（乘客簽章 / OperatorCap）+ 放款後刪 Escrow + 費率上鏈
- [x] ✅ **A3a** `user_registry` reputation/rides 提權防護（UserProfile 改共享 + admin 把關；`vehicle_registry.add_trip` 同）
- [x] ✅ **A3b** `rating_proof` 綁定 TripReceipt（評價者須為該行程乘客）+ 統計更新併入評價 + `RatingAdminCap` 建立統計
- [x] ✅ **A4** `did_registry` 存在檢查 + DID 內嵌位址綁定 controller + 下溢註記；`string::as_bytes`
- [x] ✅ **B1** `config.py` 移除弱預設 + fail-fast（缺 SECRET_KEY/DATABASE_URL/OPERATOR_PRIVATE_KEY 即拒絕啟動）；`wallet_service` salt 改隨機。✅ **operator 金鑰輪替已於 2026-09-14 完成**（新錢包重新部署整套合約，見 §8）
- [x] 🟡 **B2**（安全加固部分）移除 `sui_service` 靜默假成功 fallback + `escrow_service.refund` 假 hash；CORS/Socket.IO 收斂白名單；`refunds` approve/reject 還原 `get_current_admin`。**真實 pysui 交易串接（release_payment_by_agent + OperatorCap）移至 P1 D2**（依賴 cap 部署）
- [x] ✅ **C1** `credential_verifier` 改 `sui::groth16` 真驗證 + `CredentialAdminCap` + license deactivated 檢查
- [x] 🟡 **C2**（後端安全部分）移除**所有**可偽造的 simulated ZKP 路徑（`zkp_prover`/`zkp_verifier` 缺 key 改 fail-closed；`identity_service` 移除 `_simulate_zkp_verification` 兩條捷徑）；額外修掉 `trips.py` 的**免費搭車漏洞**（模擬付款改為只在 `MOCK_MODE` 生效）。**行動端本地產證待辦**（需 Flutter JS/WASM prover runtime，見下）
  - ⬜ **C2-mobile**：`zkp_service.dart` 目前把原始 PII（生日、駕照號）明碼送後端。需在 App 內用 `mobile/assets/zkp/*.wasm/*.zkey` + `witness_calculator.js`（透過 flutter_js 或原生 prover）本地產證，只送 proof + public signals。此為獨立 Flutter 工作包，需可執行/測試環境。

> **里程碑（2026-07-12）**：P0 全部**合約層**修復完成，`sui move build` 綠燈（0 error）。
> 附帶生產級改進：`Move.toml` 相依由移動分支 `framework/testnet` 釘到穩定 tag `testnet-v1.53.2`（可重現建置）。
> 剩餘 P0 為後端（B1/B2）與行動端（C2）。

### P1 — Agent 委託 + Walrus
- [x] ✅ **D1** 新增 `agent/agent_registry.move`（OperatorCap 模式，提前完成作為 A2 前置）
- [x] 🟡 **D2**（核心完成）新增 `agent_service.py`：Agent 以自身金鑰簽章、持乘客的 `OperatorCap` 呼叫 `release_payment_by_agent`/`refund_payment_by_agent`（PTB，含 `0x6` clock），鏈上失敗明確報錯不 mock。**剩餘**：per-user cap 發現（DB/鏈上映射「passenger→cap_object_id」）、把 `trip_service.complete_trip` 的釋放改走 `agent_service`（需用戶已簽發 cap 的產品流程）
- [x] ✅ **E1** 新增 `walrus_service.py`（PUT/GET blobs、重試、content-hash 校驗、單例）+ `config.py` Walrus 端點設定
- [x] ✅ **E2** Move 錨定欄位：`TripReceipt.{trajectory_blob_id,trajectory_hash}`、`RatingProof.content_blob_id`（`sui move build` 綠燈）
- [x] ✅ **E3** 三條 Walrus 路徑全部接上：
  - **軌跡**：`trajectory_service.py` 緩衝 → `complete_trip` flush→Walrus → 錨定 `TripReceipt`。
  - **評價**：`rating_service.create_rating` 上傳標準化評論到 Walrus（內容 hash == `rating_hash`）→ `content_blob_id`（+ migration 003 + 模型欄位）。
  - **退款佐證**：`refunds.py` 上傳改走 Walrus（`blob_id`→`evidence_cid`、內容 hash→`evidence_hash`），**淘汰單節點 IPFS** 依賴。

### P2 — 優化與測試
- [x] ✅ **F1** PTB 合併 + on-chain 瘦身：新增 `payment_escrow::release_and_receipt_by_agent`（單一交易原子完成釋放+開收據，省一筆 gas，杜絕「已放款但沒收據」中間態）；`trip_receipt::create_receipt_for` 供跨模組複合呼叫。費率已上鏈、大資料已改指 Walrus blob。（測試 13/13 PASS）
- [x] ✅ **F2** 死碼清理：刪 7 個 0-byte source module、17 個空/IOTA 測試檔、`run_tests.sh`
- [x] ✅ **G1** Move 安全測試（`tests/security_tests.move`，**12 tests 全 PASS**）：託管授權、Agent cap 額度/撤銷/動作白名單/時效、評價綁行程、reputation 提權防護、DID 位址綁定
- [x] ✅ **G2** 後端整合測試（`backend/tests/integration/`，**43 tests 全 PASS**）：agent 護欄額度/白名單/跨用戶、agent_service 缺金鑰與鏈上失敗明確報錯（不回假 hash）、delegation 過期/撤銷 cap 拒用、Walrus content-hash 校驗、zkp_verifier fail-closed、trips 模擬付款僅 MOCK_MODE、refund approve/reject。外部依賴全 fake，`docker compose exec backend python -m pytest` 執行；舊 hackathon 測試隔離至 `tests/legacy/`

> **里程碑（2026-07-12）**：`sui move test` 綠燈，9 個安全測試證明核心修復有效。

### H — Agent 智能決策層（守護 + 對話助理）
> 三層不變式：LLM 決策（可換模型、可失效）→ `agent_guardrails.validate_action`（Python 硬邊界）→ `agent_service.*_via_agent`（OperatorCap 鏈上硬邊界）。模型用開源（Qwen 系，OpenAI-compatible endpoint），`AGENT_LLM_ENABLED` 預設關閉時完全走既有規則路徑。
- [x] ✅ **H1** 後端結算決策層：`llm_client`（httpx 打 OpenAI-compatible）+ `agent_brain`（decide_settlement/settle_trip/execute_confirmed）+ migration 007（`agent_decisions` 表 + 委託 `auto_threshold_mist`）+ `trip_service.complete_trip/cancel_trip` 接線（fail-open 回規則）+ agent API（activities/confirm/decline/settings）+ WS `notify_agent_decision`。分級權限：小額自動代發、大額 pending 待乘客確認。**方向護欄**：LLM 只能確認規則方向或升級 needs_review，不能翻轉 release↔refund。**後端整合測試 71 passed**（43 基準 + 28 新）。
- [x] ✅ **H2** 前端 Agent 呈現：委託入口（profile_page + passenger_home PopupMenu，解決孤兒頁）、delegation_page 強化（額度/時效/門檻明細 + 自動門檻滑桿 + 活動 feed）、`agent_activity_card` widget（含大額確認/拒絕）、付款 dialog 標示簽署方（本人 zkLogin vs 平台代簽）。`flutter analyze` 新碼 0 error/warning。
- [ ] ⬜ **H3** 對話式行程助理（Phase B）：`POST /agent/chat` LLM function-calling（唯讀工具集，不可直接觸發資金動作）+ `assistant_page.dart`。待 H1/H2 實機驗收後啟動。

> **待處理（H1 test author 回報的設計項）**：多 cap 情境下 `_get_auto_threshold`（取最新 cap）與 `_get_cap_record`（依 cap id）可能取到不同 cap 的門檻——目前 `get_active_cap` 只回單一 cap，實務不發生；多 cap 功能上線前需統一。

### I — 付款效率改善（快速包 + 鏈上儲值 Vault）
> 目標：讓「轉錢進合約」在 app 內更順。付款本質仍是乘客自付 SUI（Enoki 只贊助 gas）。
- [x] ✅ **I1** 快速改善包（不動合約）：(a) 修 coin 挑選 bug——`_pick_passenger_coins` 支援多顆小 coin 加總湊足，PTB 內 `merge_coins` 後再 split（舊版只挑單顆足額，碎幣就付不了）；(b) `POST /wallet/faucet` 一鍵領 testnet 測試幣（限流 + 429 友善轉譯 + 僅 testnet）；(c) 前端 `_WalletSheet`（餘額顯示 + 領幣）+ passenger_home 入口 + 付款前餘額預檢（不足快速失敗給明確訊息，不再走到後端組交易才炸）。**整合測試 76 passed**（71 + 5 新 coin 挑選案例）；`flutter analyze` 新碼 0 error。
- [ ] ⬜ **I2** 鏈上儲值 Vault 合約：新 `ride_vault.move`（仿 RefundPoolV2 的 Balance<SUI> 存提，每乘客一個 shared RideVault，owner-only 存提 + Agent 持 cap 在額度內 `lock_payment_from_vault`）+ `agent_registry` 新增 `ACTION_VAULT_DEBIT=16`。⚠️ 需重新部署 = 新 package id + 更新 app_config + Enoki allowedMoveCallTargets。
- [ ] ⬜ **I3** Vault 後端 + 前端：`vault_service`（deposit/withdraw Enoki 贊助、lock_from_vault Agent 直簽）+ 司機接單後自動從 vault 扣款（餘額足且 cap 授權）→ 零簽名叫車，銜接 H1 決策層放款；委託 `allowedActions` 升 19；delegation_page 加儲值 UI。

### J — 登入 session 生命週期
> 起因：實機用一個月前的 access token 全 401，app 無過期處理（乘客端靜默失敗、WS 用死 token 反覆重連）。
- [x] ✅ **J1** Refresh token + 401 自動處理：access 15 分（`type=access`）/ admin 60 分（`type=admin`，不可互用）/ refresh 30 天（opaque、DB 存 sha256、每次使用輪替、重用即撤銷全家）。後端 `auth_service` + `refresh_tokens` 表（migration 008）+ `POST /auth/{refresh,logout,logout-all}`，三個登入端點回 bundle，4 處散落的 decode 收斂為 `decode_token`（舊格式無 type 一律拒絕）。前端 `ApiService._handleRequest` 401 → 單飛 refresh → 重送一次；refresh 被拒 → `forceLogout`（全域 `navigatorKey` 導回 `/role_select`）；網路錯誤不登出；refresh token 存 secure storage；WS 於 refresh 後 `reconnect()` 保留頁面監聽；5 處登出收斂為 `ApiService.logout()`。**後端 94 passed**（79 + 15）、`flutter test` 5 passed（4 新）、`flutter analyze` 0 error。Dashboard 尚未接 refresh、refresh 表清理排程列後續。
- [ ] ⬜ **J2** Dashboard（React）接 refresh（admin access 已縮為 60 分）；`refresh_tokens` 過期列清理排程。

---

## 8. 變更日誌 (Changelog)

- 2026-09-17 · [J1 Refresh token + 401 自動處理] · 起因見 §7 J。**後端**：`migrations/008_add_refresh_tokens.sql` + `models/refresh_token.py`（user_id/admin_id 二選一、`token_hash` sha256、`revoked_at`/`replaced_by_id`）；`services/auth_service.py`（`issue_refresh_token`/`rotate`/`revoke`/`revoke_all`/`issue_bundle_for_{user,admin}`，rotate 查詢順序固定「token 列 → 主體」以配合 FakeSession）；`core/security.py` 加 `type` claim 與 `decode_token`/`TokenError`，`deps.py`、`websocket/manager.py`、`verify_token`（admin）全部改用，舊格式 token 一律 401；`config.py` `ACCESS_TOKEN_EXPIRE_MINUTES` 30→15、新增 `ADMIN_ACCESS_TOKEN_EXPIRE_MINUTES=60`、`REFRESH_TOKEN_EXPIRE_DAYS=30`；`api/v1/auth.py` 新增 `/auth/refresh`（限流 30/60s，401 detail = `refresh_token_{invalid,expired,reused}` / `account_inactive`）、`/auth/logout`（冪等）、`/auth/logout-all`；zkLogin / users / admin 三個登入端點改回 bundle（`schemas/auth.py` 新增，`TokenResponse`/`AdminLoginResponse` 加 `refresh_token`，刪零引用的 `Token`/`TokenData`）；`issue_bundle_for_user` 順便首次寫入 `users.last_login_at`。**前端**：`session_manager.dart` 加 `refreshToken`（flutter_secure_storage）/`accessTokenExpiresAt`/`copyWith`/`updateTokens`，舊 session 仍可載入；`api_service.dart` 加 `setSession`/`adoptSession`/`expiresAtFrom`/`refreshTokens`（單飛、不走 `_handleRequest`、不帶 Bearer）/`forceLogout`/`logout`，`_handleRequest` 已知過期先換、401 換後重送一次、無 refresh 直接 forceLogout，移除 token 前 20 碼 print；`app_navigator.dart` 全域 key + `main.dart` `navigatorKey`，啟動時只在已知過期才主動 refresh；`websocket_service` token 優先取 `ApiService.token`、`disconnect(keepListeners)`、`reconnect()` 保留監聽；4 處建 session 補 `refresh_token`/`expires_in`；5 處登出改 `ApiService.logout()`，driver_home 的手動 401 導頁移除；`refund_service` 不再收 token 參數、送前檢查過期、401 refresh 重送（trip_history 不再傳 stale token）；`zklogin_service.logout()` 保留為唯一清 ephemeral key 的入口。**驗證**：migration 套於 dev DB（9 欄）；backend `Application startup complete` 零 Traceback；容器內 `pytest` **94 passed**；真實 DB 契約：新 access 200 → refresh 200 → 同把重用 401 `reused` → 換到的新 refresh 亦 401（全家撤銷）→ 舊格式 token 401 → logout 後 401 → logout-all 200；`flutter analyze` 0 error；`flutter test` 5 passed。**邊界**：既有登入者升級後被登出一次（預期）；dashboard 未接 refresh（J2）；未做表清理排程。 · `backend/migrations/008_add_refresh_tokens.sql`, `backend/migrations/README.md`, `backend/app/{config.py,core/security.py,api/deps.py,websocket/manager.py,models/{__init__,refresh_token}.py,services/auth_service.py,schemas/{auth,user,admin}.py,api/v1/{auth,users}.py,api/v1/admin/auth.py}`, `backend/tests/integration/test_auth_refresh.py`, `mobile/lib/{session_manager,app_navigator,main,login_page,profile_page,driver_home_page_new,passenger_home_page,trip_history_page}.dart`, `mobile/lib/services/{api_service,websocket_service,zklogin_service,refund_service}.dart`, `mobile/lib/pages/{auth_page,register_with_wallet_connect_page}.dart`, `mobile/test/session_manager_test.dart`, `docs/USER_ACTION_ITEMS.md`
- 2026-09-16 · [zkLogin 委託/付款 prepare 路徑修復（實機首次跑通到 Enoki）] · 使用者實機按「委託結算」得 400。逐層追到三個**從未執行過**的舊 bug（Phase 4/5/6 scaffold 一直卡在前面的 token/白屏問題）：(1) `zklogin_tx_service` / `payment_zklogin_service` 以 `getattr(settings,"PLATFORM_WALLET_ADDRESS","")` 讀設定，但 config.py 屬性名是 `PLATFORM_WALLET` → 永遠空字串 → 400「缺少 agent 位址」；改 `settings.PLATFORM_WALLET`，新增 `test_platform_wallet_setting.py` 三測試鎖住。(2) builder 以乘客位址當 `initial_sender`，pysui 要求 sender 在 keystore → `not found for ADDY`；TransactionKind 本不含 sender（Enoki 另傳），改用預設 operator 位址建 builder。(3) `txn.serialize()` 是 pysui builder 狀態序列化，非 BCS；Enoki `transactionKindBytes` 需 `txn.raw_kind().serialize()`。修後容器內驗證：kind bytes 242B 可反序列化為 `TransactionKind`、含 `issue_operator_cap` 與新 package。**Enoki 回 403 `Private API key required`**：`.env` 的 `ENOKI_API_KEY` 是 public key，贊助端點需 private key → 使用者待辦（USER_ACTION_ITEMS）。另：實機白屏三因（IP 過期 / LLDB 掛不上 / debug build 不能從主畫面啟動）已於 40275c1 處理；session token 過期無自動登出、無 refresh → 使用者選擇實作 refresh token（待規劃）。整合測試 **79 passed**。 · `backend/app/services/{zklogin_tx_service,payment_zklogin_service}.py`, `backend/tests/integration/test_platform_wallet_setting.py`, `docs/USER_ACTION_ITEMS.md`
- 2026-09-14 · [operator 金鑰輪替：新錢包全套重新部署] · `contracts/test_wallet_info.txt` 曾把平台錢包 `0x013a90ee…` 私鑰推上公開 repo（已刪檔，仍在 git 歷史）。該錢包同時是收費位址、Agent 簽章金鑰與合約部署者（持有全部 admin cap；`RefundPoolV2.platform_address` 亦在 init 綁死部署者），故採**全套重新部署**而非轉移 cap。
  - **鏈上**：`sui client new-address ed25519` 建新錢包 `platform_operator_v2`（`0x5b6d84…bf3ac`）；faucet 持續 429，改把舊錢包與舊部署者 `0x6dff…` 的 testnet SUI 全數轉入新錢包（順便清空洩漏錢包）；`sui client publish` 成功（digest `H6Jzju…oquC`，0.24 SUI），新 package `0x95f99809…79b0`，11 個 registry/pool/cap 物件全數擷取無空值，4 個 admin cap + UpgradeCap 經 CLI 確認 owner 為新錢包。註：`deploy_and_init.sh` 在 gas 分散於多 coin 時會因單 coin 不足 budget 靜默失敗，本次以 `--gas <coin>` 指定後成功。
  - **設定**：`.env`（gitignored）13 個變數（新私鑰、`PLATFORM_WALLET_ADDRESS`、`CONTRACT_PACKAGE_ID`、10 個 `*_ID`）以腳本就地改寫，私鑰全程未印出、未落 tracked 檔；`app_config.dart` 的 `contractPackageId`/`platformAddress` 換新；`Published.toml`/`Move.lock` 同步新 package；刪除過期 `deploy_output.json`/`.package_id`（零引用）；兩份 `.env.example` 補齊 config.py 實際讀取但漏列的 7 個 ID/cap 變數。
  - **死值清理**：`one_click_payment_dialog.dart` 手動付款區 5 處硬編碼舊 package/平台位址改引用 `AppConfig` 單一來源；刪除零引用死碼 `sui_wallet_service.dart`（硬編碼 `0xa6232c`/`0x6dff`），wallet_setup_page 兩行殘留註解一併清理。
  - **驗證**：後端 force-recreate 後 `/health` 200、容器內 `settings` 讀到新 package/位址/cap、整合測試 **76 passed**；`sui move test` **19/19**（Move.lock 新 rev 相容）；`flutter analyze` **0 error**；`mobile/lib` 零殘留舊地址/舊 package（app_config 註解除外）。
  - **邊界**：不重寫 git 歷史（testnet key、無真實價值）；舊 package/舊 escrow/舊 OperatorCap 整組棄置，用戶需重新委託；Enoki Portal allowedMoveCallTargets 換新 package 由使用者操作（USER_ACTION_ITEMS）。
  · `.env`(未入庫), `mobile/lib/config/app_config.dart`, `mobile/lib/widgets/one_click_payment_dialog.dart`, `mobile/lib/pages/wallet_setup_page.dart`, 刪 `mobile/lib/services/sui_wallet_service.dart`, `contracts/{Published.toml,Move.lock}`, 刪 `contracts/{deploy_output.json,.package_id}`, `.env.example`, `backend/.env.example`, `CLAUDE.md`, `docs/USER_ACTION_ITEMS.md`
- 2026-09-14 · [CI/CD 修復：三 job 首次全綠] · CI 自建立（run #12）起一直全紅，逐一查 GitHub Actions 實際失敗定位並修復（Move job 一直綠——因有釘 sui 版本）。
  - **backend pytest**：(1) 缺 `greenlet`——SQLAlchemy async engine 必要，只在特定平台 marker 自動帶，CI 乾淨 install 沒裝 → async 測試 collection 階段全滅；requirements 顯式釘 `greenlet==3.0.3`。(2) 測試依賴 .env——`agent_service` 建構讀 `CONTRACT_PACKAGE_ID`，CI 無 .env → 提早 return 使 2 個測試拿到非預期錯誤；conftest 補 `CONTRACT_PACKAGE_ID`/`PLATFORM_WALLET_ADDRESS` setdefault。
  - **flutter analyze**（真根因，本機測不出——因 gitignored 檔本機存在）：多個 **tracked 檔 import 到被 .gitignore 排除的檔**，origin 缺檔 → CI `uri_does_not_exist` + 連鎖 undefined error，等於 repo 一直無法編譯。(a) 刪死碼 `place_search_field.dart`（零引用，import 被忽略的 geocoding_service）；(b) `sui_wallet_connector.dart` / `google_directions_service.dart` 被 main.dart / trip_in_progress 引用卻因「當年含金鑰」被忽略（金鑰早已移至 config），徹底掃描無秘密後**納入版控**、移除過時 gitignore 行。寫了全面靜態掃描確認所有 tracked import 都指向 repo 內存在的檔。flutter job 也釘版本 3.35.2。
  - 驗證：GitHub Actions run #22 三 job（Move / Backend / Flutter）**全 success**。
  · `backend/requirements.txt`, `backend/tests/integration/conftest.py`, `.github/workflows/ci.yml`, `.gitignore`, 刪 `mobile/lib/widgets/place_search_field.dart`, 納入 `mobile/lib/services/{sui_wallet_connector,google_directions_service}.dart`

- 2026-09-08 · [I1 付款效率快速改善包] · 讓入金/付款在 app 內更順（不動合約）。
  - **coin 挑選 bug 修復**：`payment_zklogin_service._pick_passenger_coin`→`_pick_passenger_coins`——單顆足額優先（挑最小足額顆），否則由大到小湊足；`build_lock_payment_kind` 多顆時先 `txn.merge_coins` 合併再 `split_coin`。修掉「多顆小 coin 加總夠卻付不了」。加總不足才報錯（訊息帶目前總餘額）。
  - **一鍵領測試幣**：`POST /wallet/faucet`（authed，取 user zkLogin 位址打 testnet faucet）——僅 testnet、後端限流 3 次/10 分、429 轉友善訊息、連線失敗回 502。`GET /wallet/balance` 沿用既有。
  - **前端**：`_WalletSheet`（passenger_home PopupMenu「錢包餘額/領測試幣」入口，顯示餘額 + 領幣 + 重查）；付款 dialog 加 `_precheckBalance`——餘額不足在組交易前就明確報「現有 X / 需 Y SUI」，不再走到後端挑 coin 才炸；`api_service` 加 `requestFaucet`。
  - 驗證：整合測試 **76 passed**（71 + 5 新 coin 挑選，`test_payment_coin_selection.py`）；backend `/health` 200、faucet/balance 未帶 token 正確回 403、無 Traceback；`flutter analyze` 新碼 0 error。
  · `backend/app/services/payment_zklogin_service.py`, `backend/app/api/v1/wallet.py`, `backend/tests/integration/test_payment_coin_selection.py`(新), `backend/tests/integration/test_llm_client.py`(修環境依賴), `mobile/lib/{passenger_home_page.dart,services/api_service.dart,widgets/one_click_payment_dialog.dart}`

- 2026-09-05 · [H1+H2 Agent 智能決策層（守護）] · 導入 LLM 結算決策層（開源模型，`AGENT_LLM_ENABLED` 預設關）。三層不變式：LLM 建議 → `agent_guardrails`（Python 硬邊界）→ `agent_service`+OperatorCap（鏈上）。
  - 後端：`llm_client.py`（httpx 打 OpenAI-compatible /chat/completions，逾時/壞 JSON → None fallback）、`agent_brain.py`（`decide_settlement`/`settle_trip`/`execute_confirmed`；分級：≤ `auto_threshold_mist` 自動代發、> 則 pending 待確認、flag_review→needs_review）、`models/agent_decision.py` + migration 007（`agent_decisions` 表 + 委託 `auto_threshold_mist`，已套用 DB）、`trip_service` complete/cancel 接線（handled=False 時完全走既有規則路徑，行為不變）、`api/v1/agent.py`（+activities/confirm/decline/settings）、`notifier.notify_agent_decision`、`config.py`（LLM_* + fail-fast）。
  - **安全**：方向護欄——LLM 只能確認規則的資金方向或升級 needs_review，不能翻轉 release↔refund（防 prompt injection 改資金流向）；金額一律用系統值忽略 LLM 自報。
  - 前端：委託入口（profile_page + passenger_home，解決孤兒頁）、delegation_page 強化（明細 + 自動門檻滑桿 + Agent 活動 feed）、`agent_activity_card.dart`（大額確認/拒絕）、付款 dialog 簽署方標示、api_service 新增 4 端點。
  - 驗證：後端整合測試 **71 passed**（43 基準 + 28 新，`docker compose exec backend python -m pytest`）；backend `/health` 200 無 Traceback；`flutter analyze` 新碼 0 error/warning。外部依賴（LLM/鏈/DB）全 fake，不製造假交易 hash。
  · `backend/app/services/{llm_client,agent_brain}.py`(新), `backend/app/models/agent_decision.py`(新), `backend/migrations/007_add_agent_decisions.sql`(新), `backend/app/{config.py,services/trip_service.py,api/v1/agent.py,websocket/notifier.py,models/{delegation,__init__}.py}`, `backend/tests/integration/test_{llm_client,agent_brain_decide,agent_brain_settle}.py`(新), `mobile/lib/widgets/agent_activity_card.dart`(新), `mobile/lib/pages/delegation_page.dart`, `mobile/lib/{profile_page,passenger_home_page}.dart`, `mobile/lib/services/api_service.dart`, `mobile/lib/widgets/one_click_payment_dialog.dart`
- 2026-09-05 · [Mapbox token 洩漏處置 + push 解鎖] · push 被 GitHub push protection 擋（歷史 commit 含 Mapbox pk token）。處置：(1) 6 處硬編碼 token 改讀 gitignored `map_config.local.dart`（新 `MapConfig` 單一來源，無 token 退回 OSM；real_ride 舊 token 實測 401 已死，統一換有效顆）；(2) `git filter-repo --replace-text` 洗掉未推送 18 commit 中的 token blob（origin 錨點 SHA 不變）；(3) remote 更新至改名後的 `hsuanliu112/autodrive_platform` 並 push 成功。⚠️ token 自最初 commit 即在已推送歷史＝視為洩漏，輪替待辦已入 USER_ACTION_ITEMS P0。`flutter analyze` 0 error（419 issues＝既有基準線）。 · `mobile/lib/config/map_config*`, `mobile/lib/{passenger_home_page,driver_home_page_new}.dart`, `mobile/lib/pages/{trip_in_progress,vehicle_recall,real_ride}_page.dart`, `mobile/.gitignore`, `.github/workflows/ci.yml`
- 2026-09-05 · [定位變更 + 最後死碼清除] ·
  - **不再參加 Sui Overflow 2026**，專案改定位為「做到生產級品質的 side project」；CLAUDE.md、README、PROJECT_OVERVIEW、本檔頁首同步改寫（品質/安全標準不變）。
  - 刪除 `contracts/iota-src/`（539MB gitlink+目錄）與 `identity/`（TS 版 DID/VC 舊實作，後端零引用）。
  - 追加刪除 `backend/app/services/iota_contract_service.py` + `backend/app/api/v1/contract_integration.py`（router 未註冊於 main.py、前端零呼叫＝雙死碼；刪後 `py_compile main.py` 通過、live backend `/health` 200 無 Traceback）。IOTA 遺留至此全數清除。
  · `CLAUDE.md`, `README.md`, `PROJECT_OVERVIEW.md`, 刪 `contracts/iota-src/`, `identity/`, `backend/app/{services/iota_contract_service,api/v1/contract_integration}.py`
- 2026-09-05 · [全 repo 文件/腳本大掃除] · 刪除 80 個過期 .md/.sh（皆先以 `git grep` 驗證 0 活引用，遵守鐵律 5）：docs/{reports,guides,setup} 整包與 2025-10/11 AutoDrive 時代的計畫/報告文件（ZKP_IMPLEMENTATION_PLAN、DRIVE_TOKEN、token_economics、FINAL_PROGRESS_REPORT、INDEX 等）、16 個 0-byte 佔位 md（contracts/docs 全空）、被 scripts/ops 取代的舊部署腳本（deploy_payment_escrow/init_refund_pool/create_test_wallet）、被 pytest 取代的 scripts/testing、run_flutter/update_ip 重複副本（各留根目錄一份，root update_ip.sh 已確認指向現行 `app_config.local.dart`）。README「文檔」區連結改指現存文件。保留：migrations/config README、FIREBASE_SETUP_GUIDE（對應 USER_ACTION_ITEMS 待辦）、scripts/ops、zkp/scripts、init-test-db.sh（docker-compose 掛載）。⚠️ 遺留候選（非 .md/.sh，未動）：`identity/`（TS 版 DID/VC 舊實作，後端零引用，真實 ZKP 在 `zkp/`）與 `contracts/iota-src` submodule。 · 全 repo
- 2026-09-05 · [Claude 架構整備（loop engineering）] ·
  - Subagent 目錄修正：`move-auditor`/`backend-test-author` 由無效的 `.claudecode/agents/` 搬到 `.claude/agents/`（此前從未被載入）；backend-test-author 由一次性 G2 工人改寫為長期回歸角色；兩者與 CLAUDE.md §3 的「19/19 寫死基準線」全改為「failed=0、總數不低於 roadmap 記載」。
  - 確定性驗證 hook：新增 `.claude/settings.json` PostToolUse hook——Edit/Write 碰到 `contracts/**/*.move` 即自動跑 `sui move build`，失敗把錯誤餵回模型（已以真實 payload 實測觸發與通過）。
  - 過期 context 清除：刪除 `.claudecode/prompts/` 整包（內容停在 2025-10 舊架構，與 CLAUDE.md 現況矛盾）；仍有效的專案專屬排錯知識濃縮為 `docs/TROUBLESHOOTING.md`；論文 PDF 移至 `docs/references/`。
  - §8 歸檔：2026-07 全部條目（35 筆）搬至 `docs/changelog-2026-07.md`，§8 只留最近約一個月。
  - CI：重寫 `.github/workflows/ci.yml`——舊檔是 IOTA 時代遺留（裝 `iota-cli`、`flutter build apk`，必炸）。新版三個 job：Move build/test（釘版 testnet-v1.53.2 CLI，下載連結驗證 200）、後端 `pytest tests/integration`、Flutter analyze/test（gitignored `*.local.dart` 以 `.example` 補位，符號已驗證一致；analyze 用 `--no-fatal-warnings` 對齊「0 error」標準）。實際跑通需待 push 後確認。
  - 權限清單去沉積：`settings.local.json` 移除含過期 JWT 的一次性條目與多條 echo/curl 殘渣，收斂為通用 wildcard。
  · `.claude/agents/*`, `.claude/settings.json`, `.claude/settings.local.json`, `CLAUDE.md`, `docs/{TROUBLESHOOTING.md,changelog-2026-07.md,references/}`, `.github/workflows/ci.yml`, 刪 `.claudecode/`
- 2026-08-14 · [實機白屏根因修復：啟動期主執行緒卡死 + HTTP 無 timeout] ·
  - 症狀：實機白屏但 Dart log 持續輸出；`_getCurrentLocation` 無任何分支 log、`getUserTrips` 與 WebSocket 也無完成 log。
  - 根因：`passenger_home_page.initState` 第一行就呼叫 `Geolocator.isLocationServiceEnabled()`——iOS 上它在主執行緒執行且可能長時間無回應（Apple 文件明載），第一幀因此永遠畫不出來（白屏＝iOS 啟動畫面），系統權限對話框也跳不出。
  - 修法：(1) 定位改 `addPostFrameCallback` 延後到第一幀之後 + 該呼叫加 8s timeout；(2) `http_client_manager.executeRequest` 統一加 15s timeout，主機不可達時明確報「請求逾時＋排查指引」而非無聲卡住。`flutter analyze` 0 error。
  - 待驗證：手機 Safari 開 `http://<Mac IP>:8000/health` 確認網路可達（getUserTrips/WS 卡住疑似手機到 Mac 網路仍不通）。
  · `mobile/lib/passenger_home_page.dart`, `mobile/lib/services/http_client_manager.dart`
- 2026-08-14 · [實機偵錯環境修復] · 兩個互不相關的問題：(1) 無線偵錯「Dart VM Service was not discovered」＝ `Info.plist` 缺 `NSBonjourServices`（`_dartVmService._tcp`）與 `NSLocalNetworkUsageDescription`，缺了系統不會跳「區域網路」授權、Flutter 找不到 VM Service，已補上；(2) Google 登入 http timeout ＝ `app_config.local.dart` 的後端位址仍是舊熱點 IP `172.20.10.14`，Mac 現為 `192.168.150.143`，手機連不到後端（`/health` 於新 IP 驗證可達），已更新（該檔 gitignored）。另查 USB 完全看不到 iPhone（`system_profiler SPUSBDataType` 無 Apple 裝置）→ 連線全走無線的原因是線材/埠不傳資料。 · `mobile/ios/Runner/Info.plist`, `mobile/lib/config/app_config.local.dart`(不入庫)

- 2026-08-13 · [任務3 Flutter 靜態驗證] · `flutter pub get && flutter analyze`：唯一 error 是範本遺留 `test/widget_test.dart` 引用不存在的 `MyApp`，改為對應 `ProjectDappApp` 的最小 smoke test → **0 error**。剩 17 warning（全為 unused import/field/variable）與 402 info（`withOpacity`/`WillPopScope` deprecation、`avoid_print` 等），無功能影響，留待日後清理。 · `mobile/test/widget_test.dart`
- 2026-08-13 · [G2 後端整合測試 ✅] · 新增 `backend/tests/integration/` pytest harness（**43 tests 全 PASS**，`docker compose exec backend python -m pytest`）。外部依賴（Sui RPC、Walrus、DB、snarkjs）全用可注入 fake、不製造假交易 hash。覆蓋：agent 護欄額度/每日剩餘/動作白名單/跨用戶/髒 object id、agent_service 缺金鑰與鏈上失敗明確報錯不回假 hash、delegation 過期/撤銷 cap 拒用與額度時效解析、walrus content-hash 不符拋錯不重試、zkp_verifier 缺 key fail-closed、trips 模擬付款僅 MOCK_MODE、refund_service_v2 approve 鏈上失敗不落 DB / reject 僅改 DB / 已處理防重複。舊 hackathon 測試（需 docker DB、無法收集）隔離至 `tests/legacy/`。 · `backend/pytest.ini`, `backend/tests/integration/*`(新), `backend/tests/legacy/*`(移動)
- 2026-08-13 · [任務1 主題式 commit ✅] · 2026-07-12〜08-10 全部加固成果（80+ 修改、20+ 刪除、90+ 新檔）拆成 7 個主題 commit（chore 產物清理 / fix(contracts) / fix(backend) / feat(backend) / feat(mobile) / feat(dashboard) / docs），僅 commit 未 push。提交前驗證：`sui move build` 綠燈、`sui move test` **19/19 PASS**、後端 128 個 `.py` 全 py_compile 通過、秘密掃描無命中（`.env`/`*.local.dart` 均未入庫；`.DS_Store`、`mobile/.dart_tool/` 等已 `git rm --cached` 停止追蹤）。備註：`refund_service_v2._try_blockchain_refund`（create 路徑）仍會產生標記為 `pending_signature` 的 sha256 佔位 hash 回傳給呼叫端，雖未冒充成功但建議後續改為回傳待簽參數。 · 全 repo
- 2026-08-10 · [CLAUDE.md 過期 package id 更新（P3）] · 把 CLAUDE.md「關鍵事實」的 package 由過期 `0xa6232c…790380b` 改為現行加固版 `0xb761c6f5…e23f`（與 `.env` CONTRACT_PACKAGE_ID 一致），並註明舊值與 `Published.toml` 已過期勿引用。`Published.toml`（sui move 產生檔）待下次部署自動更新。檔案：`CLAUDE.md`, `docs/USER_ACTION_ITEMS.md`
  - 註：本輪 Bash 工具因 `/login` 後 CLI 進入需重裝狀態而失效，無法做 RPC 上鏈物件驗證；改做純文件工作。使用者需 `node node_modules/@anthropic-ai/claude-code/install.cjs` 或重開 session 修復。

> 格式：`YYYY-MM-DD · [工作包代號] · 摘要 · 影響檔案`。最新在上。
> 只保留最近約一個月；更早的條目歸檔於 [`docs/changelog-2026-07.md`](changelog-2026-07.md)（歸檔時同步搬移，勿在兩處重複記錄）。
