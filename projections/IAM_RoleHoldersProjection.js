// 反查 projection：把每一個 RolesAssigned / RolesRevoked 事件
// link 到所有受影響的 per-role stream：IAM_GetRoleHolders-<roleId>。
//
// 串流名稱必須與 read side 一致：GetRoleHoldersPresenter 的
// categoryRule = .fromClass(withPrefix: "IAM_") 依 projector 類名產生 `IAM_GetRoleHolders-`。
// GetRoleHoldersPresenter 讀取這些 stream 重建當前持有者清單。
// 部署指令（由操作者手動執行）：
//   bash scripts/projection.sh（或直接在 KurrentDB UI 新增 Continuous Projection）
fromStreams(["$ce-IAMEmployeeAccess"])
.when({
    $init: function(){ return {} },
    RolesAssigned: handleEvent,
    RolesRevoked: handleEvent,
});
function handleEvent(state, event) {
    if (!event.isJson) { return; }
    var roles = event.body["roles"];
    for (var i = 0; i < roles.length; i++) {
        linkTo("IAM_GetRoleHolders-" + roles[i], event);
    }
}
