// IAMPermissionCatalog — 全 context 權限的聚合 catalog（PermissionCatalogPlugin 在 swift build 時
// 從本 target 內所有 *permissions.yaml 產出 PermissionCatalog.swift）。
//
// 用途：未來 role 的 permission 設計 + 可視化授權 UI 的權限選單（universe）。
// 本檔引用 generated 符號當煙霧測試——編譯通過即證明 plugin 在 build 內實際產出且可用。
//
// ⚠️ yaml 來源與 drift：各 context 的 yaml 目前是「手動複製的快照」（與該 context repo 的 SSOT
// byte-identical，例如 OpportunityContext/Sources/OCServer/OpportunityContext.permissions.yaml）——
// 上游改動不會自動同步；正式同步機制留待部署期定案。驗 drift：直接 diff 兩份檔案。
// 注意：IAM 自身沒有 catalog（grant/revoke 為 admin-only，不走 context-permission 把關），
// 所以本 target 只放「其他 context」的 yaml。
public enum IAMPermissionCatalogSmoke {
    public static func check() {
        precondition(!PermissionCatalog.all.isEmpty, "catalog should not be empty")
        precondition(PermissionCatalog.contexts.contains("OpportunityContext"), "missing OpportunityContext")
        precondition(!PermissionCatalog.allRawValues.isEmpty, "universe should not be empty")
    }
}
