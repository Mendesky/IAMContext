---
topic: IAM 側共編（grouping collaboration）：投影儲存、三支冪等寫入 API、role→permission mapping、查詢 API
date: 2026-06-11
participants: user（決策者）, Claude（本 session）
status: superseded
provenance: 決策形成於 per-case 角色（owner/editor/viewer）規劃討論的 IAM 分支；OC 側對應 spec 見 OpportunityContext/docs/tasks/2026-06-11-case-role-enforcement-*.md 與其 discussion。
superseded: 2026-06-11 user 與夥伴討論定案——role→permission 控管回到 OC，user 對 grouping 的有效權限由 OC 自己的 read model 吐出（OC 本地 collaborators × OC 本地 mapping ∩ 既有 gRPC 全域權限）；IAM 不持有共編投影、不提供查詢 API。執法為兩段 middleware（IAM 全域 + OC 本地），即 E1/E2 原設計。I1/I2 spec 隨之作廢（registry 已標 superseded）。
---

# 議題定義

## 目標

前端流程需要「**user 在某個 grouping 上實際可用的權限**」這個合併後的答案（全域權限 ∩ 角色展開），由 IAM 集中回答。為此 IAM 需要四件事：(1) 持有各 grouping 的協作者角色（**OC 資料的投影，非正本**）；(2) 三支冪等寫入 API 供 OC 的 listener 餵資料；(3) 記載 OC 定義的 role→permission mapping；(4) 對外的查詢 API。

## 範圍

**討論內**：IAM 側全部（新 aggregate、gRPC 服務、mapping 記載、HTTP 查詢端點）。
**討論外**：OC 側 listener（OC 的 task）；mapping 內容的定義（OC 的 task，IAM 只記載）；執法 provider 切換（E1 本地版先行，未來再議）；IAM HTTP 的 auth（隨 operatorId 體系迭代，已 deferred）。

## 約束

- **所有權**：collaborator 角色的正本（SSOT）永遠在 OC 的 `QuotingCaseGrouping`；IAM 持有的是**投影**——只接受 OC listener 的寫入，不提供任何人工/前端修改入口。
- **不掛在 `EmployeeAccess` 上**：獨立 aggregate（避免身分聚合無限長大、每次 OC 共編變動變成身分事件）。
- 跨 context 呼叫走 **gRPC**（家規：比照 AccountContext→IdentityContext、OC→IAM PermissionsService）。
- 寫入 API 必須**冪等**（listener 是 at-least-once 投遞；重送、重放都不可出錯）。

# 決策紀錄

1. **(user, agreed)** 查詢需求成立：`(userId, groupingId) → 該 grouping 的有效權限`，由 IAM 回答（前端單一來源）。
2. **(user, agreed)** 角色資料進 IAM 的方式：**OC 在共編變動時呼叫 IAM 的寫入 API**——經討論修正為「由 OC 的事件 listener 呼叫」（at-least-once + checkpoint，回放即 backfill），**不是在 use case 內同步雙寫**（partial-failure 會靜默分歧）。
3. **(user, agreed)** 寫入 API 三支：新增共編／編輯共編／移除共編；加上建立 grouping 時的 owner 註冊（走「新增共編（role=owner）」同一支——對這組系統對系統 API，owner 是合法輸入，與 OC 對外的 addCollaborators 禁 owner 不同）。
4. **(user, agreed)** role→permission mapping：**OC 定義、IAM 記載**（OC 的 153 條權限哪些屬 grouping-scoped、各需要什麼最低角色——值可從 OC 的 E1 規則分類機械導出）。deploy 節奏資料，以檔案交付、隨 IAM 部署載入；不做動態管理 API。
5. **(session, agreed)** IAM 側儲存形狀：新 aggregate **`GroupingCollaboration`**（aggregateRootId = quotingCaseGroupingId），事件溯源（家規），idempotent guard（已在目標狀態 → no-op 成功）。查詢直接 `repository.find(byId:)` 讀 aggregate（強一致、stream 短、免 JS projection 部署）。
6. **(session, agreed)** 查詢 API 走 **HTTP REST**（消費者是前端；IAM 既有 REST 慣例）；未來執法 provider 若切到 IAM 再加 gRPC RPC（彼時另案）。
7. **(session, agreed)** 非協作者／查無 grouping → **200 + 空 permissions、無 role**（前端友善；非錯誤情境）。
8. **(背景)** 執法（OC middleware）暫不消費本鏈路——E1 本地版先行；本鏈路先服務前端呈現（容忍 listener 秒級延遲）。

# 開放問題

- IAM HTTP 端點目前無 auth middleware（與既有 `GET /employee-access/permissions/{userId}` 同等曝露）——查詢 API 的 userId 是自由路徑參數，知道他人 userId 者可查其權限清單。隨 operatorId 體系迭代一併處理（user 已決策 deferred）。
- 未來多 context 的 per-resource 角色（不只 OC grouping）是否泛化 aggregate 形狀——目前 YAGNI，保持具體。
