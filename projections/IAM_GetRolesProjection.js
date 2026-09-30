// 全角色清單 projection：把每一個 Role 事件 link 到固定 stream：IAM_GetRoles-all。
//
// 串流名稱必須與 read side 一致：GetRolesPresenter 的
// categoryRule = .fromClass(withPrefix: "IAM_") 依 projector 類名產生 `IAM_GetRoles-`。
// GetRolesPresenter 讀取 `IAM_GetRoles-all` stream 重建全角色清單。
// 部署指令（由操作者手動執行）：
//   bash scripts/projection.sh（或直接在 KurrentDB UI 新增 Continuous Projection）
fromStreams(["$ce-IAMRole"])
.when({
    $init: function(){ return {} },
    RoleCreated: link,
    RoleRenamed: link,
    RoleDescriptionUpdated: link,
    RolePermissionsAdded: link,
    RolePermissionsRemoved: link,
    RoleDeleted: link,
});
function link(state, event) {
    if (!event.isJson) { return; }
    linkTo("IAM_GetRoles-all", event);
}
