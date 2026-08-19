# Handoff：IAM debug mode——全權限模式（2026-08-18）

## 背景

前端將**移除 `permissionGating` feature flag**：所有環境一律打權限 API、照結果渲染
（單一路徑，權限真相只在後端）。開發/測試環境要「任何帳號全功能」，改由
**IAM 開 debug mode 直接回全權限**承擔（取代前端 bypass）。

## 需求

新增環境變數開關（名稱建議 `IAM_DEBUG_FULL_PERMISSIONS=1`，預設 off）。開啟時：

1. **正查全放行**：`getPermissions(userId)`（HTTP，前端渲染用）**不查該使用者**，
   直接回 catalog 裡**全部已登錄的 rawValue**（整個 permission universe）。
2. **gRPC 同步放行**：`PermissionsService`（OC／Middleware 後端執法用的 gRPC）
   同一開關、同一行為——否則會變成「UI 全開、操作 403」。若兩者共用同一查詢路徑，
   一處改雙面生效。
3. **反查不受影響（重要）**：`getPermissionHolders(rawValue)`（權限 → 持有者清單）
   **維持真實授權資料**。前端「指定分配人員」候選下拉靠它，debug 若也回全員，
   下拉會變成全公司名單。

## 安全防呆（debug 絕不能上正式）

- 預設 off；只吃環境變數，不做 runtime API 切換。
- 啟動 log 大字警示（例：`⚠️ IAM DEBUG MODE: ALL PERMISSIONS GRANTED TO EVERYONE`）。
- 建議 debug 回應帶識別（如 response header `X-IAM-Debug: 1`），部署檢查一眼可辨。
- 注意 IAM 是共用服務：debug 一開，**所有打這顆 IAM 的 context 全放行**。

## 驗收條件

1. debug on：任意 userId 的 `getPermissions` 回全部 rawValue（含未對該 user 授權者、
   含 AllocateFor* 等持有者標記類）。
2. debug on：gRPC 執法查詢同樣全放行（以一個原本 403 的 endpoint 實測變 200）。
3. debug on：`getPermissionHolders` 回值與 debug off 完全一致。
4. debug off：三者行為與現行版本 byte-identical。
5. 啟動 log 含警示字樣。

## 配套（僅供對齊，非本 handoff 範圍）

- OC 需對稱的 per-case debug（另份 handoff：`OpportunityContext/docs/handoff/oc-debug-full-case-permissions-2026-08-18.md`）——
  per-case 權限由 OC 從協作角色推導，IAM debug 蓋不到。
- 前端在兩份後端 debug 就緒後移除 `permissionGating`（保留 `devPermissionBypass` 供單元/e2e 測試）。
