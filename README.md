# ChainSUI — 去中心化 DePIN 叫車平台

> 基於 **Sui 區塊鏈**的去中心化叫車平台。
> 系統含乘客、司機，以及能為雙方自動報價、搓合、並在**受限授權下代發交易**的 AI Agent。

## 專案簡介

ChainSUI 用區塊鏈實現透明、安全的叫車與支付，三項核心能力：

- **Agent 能力委託（Agentic Web）** — 用戶用 `OperatorCap` 授權平台 Agent 在**額度/時效/動作白名單**內代發交易；私鑰留在用戶端，平台不再是「全權代理」。
- **Walrus 去中心化存儲** — GPS 軌跡、評價內容、退款佐證等大容量資料存 Walrus，鏈上只錨定 `blob_id` + 內容雜湊。
- **ZKP / DID 身分** — 以 `sui::groth16` 原生驗證年齡/駕照憑證，不揭露原始個資。

### 核心特色

- **鏈上託管支付** — 車資鎖入智能合約，完成後釋放給司機、取消則退款；釋放需乘客簽章或 Agent 的 OperatorCap。
- **跨平台應用** — Flutter（iOS/Android）+ React 管理後台。
- **PTB 原子操作** — 「釋放託管 + 開立收據」可在單一交易原子完成，省 gas。
- **即時追蹤** — Socket.IO 實時行程狀態與定位。

> 生產級加固的完整進度、問題清單與各工作包，見 **[`docs/PRODUCTION_HARDENING_ROADMAP.md`](docs/PRODUCTION_HARDENING_ROADMAP.md)**（單一事實來源）。

## 系統架構

```
┌─────────────────────────────────────────────────────────┐
│                    Frontend Layer                        │
│   Flutter App (iOS/Android)   │   React Dashboard (Web)  │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│              Backend API (Python + FastAPI)              │
│  業務邏輯 · Agent 決策層 · 合約互動(pysui) · Socket.IO   │
└─────────────────────────────────────────────────────────┘
        │                  │                      │
        ▼                  ▼                      ▼
┌────────────────┐ ┌──────────────────┐ ┌──────────────────┐
│  PostgreSQL    │ │  Sui Blockchain  │ │  Walrus 存儲      │
│  應用資料(SoR) │ │  託管/身分/評價   │ │  軌跡/評價/佐證   │
│                │ │  Agent OperatorCap│ │  (blob 由鏈上錨定)│
└────────────────┘ └──────────────────┘ └──────────────────┘
```

### 合約模組（`contracts/sources/`）

| 領域 | 模組 | 重點 |
|---|---|---|
| Agent | `agent/agent_registry` | `OperatorCap` 委託（額度/時效/動作白名單/可撤銷） |
| 金流 | `financial/payment_escrow` | 託管鎖定/釋放/退款；釋放需乘客或 OperatorCap；複合原子結算 |
| 金流 | `financial/refund_module_v2` | 退款池，出金一律需 `RefundCapability` |
| 身分 | `identity/credential_verifier` | `sui::groth16` 原生 ZKP 驗證 + AdminCap |
| 身分 | `identity/did_registry` | DID（內嵌位址綁定 controller） |
| 身分 | `identity/{user,vehicle}_registry`, `trusted_issuers` | 用戶/車輛/受信簽發者 |
| 業務 | `business/{trip_receipt,rating_proof}` | 行程收據、評價存證（綁行程、錨定 Walrus blob） |

### 技術棧

- **後端**：Python 3.11+ / FastAPI / SQLAlchemy / PostgreSQL / **pysui** / Socket.IO
- **合約**：Move（Sui Framework，釘 `testnet-v1.53.2`）
- **存儲**：Walrus（去中心化 blob）
- **ZKP**：Circom + snarkjs（Groth16 / bn254），鏈上 `sui::groth16` 驗證
- **前端**：Flutter（Mobile）、React + Vite（Dashboard）

## 快速開始

### 環境需求
Python 3.11+ · Node.js 18+ · Flutter 3.x · Docker & Compose · PostgreSQL 15+ · **Sui CLI**

### 1. 部署合約
```bash
cd contracts && sui move build && sui move test      # 建置 + 安全測試（13 tests）
# 發布並擷取所有 registry/pool/cap 的 object ID：
../scripts/ops/deploy_and_init.sh                    # 輸出貼進 backend/.env
```

### 2. 後端
```bash
cd backend
cp .env.example .env          # 依註解填入機密（缺 SECRET_KEY/DATABASE_URL/OPERATOR_PRIVATE_KEY 會 fail-fast）
pip install -r requirements.txt
docker-compose up -d          # PostgreSQL
# 套用資料庫遷移（含評價 Walrus 欄位 003）：
psql "$DATABASE_URL" -f migrations/002_add_rating_reputation_system.sql
psql "$DATABASE_URL" -f migrations/003_add_rating_content_blob.sql
python -m app.main
```

### 3. Dashboard / Mobile
```bash
cd dashboard && npm install && npm run dev
cd mobile && flutter pub get && flutter run
```

> **機密管理**：切勿把真實私鑰/金鑰提交或落地 `.env`；生產請用 secret manager 注入。`config.py` 在非 DEBUG 模式缺機密會拒絕啟動。

## 測試

```bash
cd contracts && sui move test    # 合約安全測試 13/13 PASS
cd backend && pytest             # 後端（需 pytest + 測試 DB）
cd mobile && flutter test        # 行動端
```

合約安全測試（`contracts/tests/security_tests.move`）涵蓋：託管授權、Agent cap 額度/撤銷/動作白名單/時效、評價綁行程、reputation 提權防護、DID 位址綁定、PTB 複合結算。

## 功能說明

### 乘客端 / 司機端（Flutter）
註冊登入（錢包）、地點搜尋、費用預估、叫車、託管支付、行程追蹤、評價、身分驗證（ZKP）。

### 管理後台（Dashboard）
管理員登入、數據統計、用戶/車輛/行程管理、退款審核（`get_current_admin` 保護）。

## 文檔

- **[生產級加固路線圖](docs/PRODUCTION_HARDENING_ROADMAP.md)** — 問題清單、優先序、進度、驗證方式（**必讀**）
- [安全威脅模型與 ZK 身份藍圖](docs/SECURITY_THREAT_MODEL.md)
- [故障排除速查](docs/TROUBLESHOOTING.md) / [使用者待辦](docs/USER_ACTION_ITEMS.md)
- 合約部署：`scripts/ops/deploy_and_init.sh`（一鍵發布並擷取 object ID）
- API 文檔：`http://localhost:8000/docs`

## 安全性

- 資金移動、狀態變更的 Move 函式**皆有存取控管**（Capability 物件或 sender/witness 斷言）。
- 鏈上呼叫失敗**明確報錯**，不以假交易 hash 冒充成功。
- ZKP 驗證 fail-closed（缺密鑰即拒絕，無可偽造的模擬模式）。
- CORS 白名單、JWT 認證、機密 fail-fast。

## 授權

目前尚未加入授權條款（repo 內無 LICENSE 檔）。要開源再補一份 LICENSE 並於此註明。

---

**注意**：部分整合仍在進行（Agent 代發交易的 per-user cap 發現、行動端本地產證），詳見路線圖。
