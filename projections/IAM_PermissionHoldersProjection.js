// 反查 projection：把每一個 PrivilegeGranted / PrivilegeRevoked 事件
// link 到所有受影響的 per-permission stream：IAM_GetPermissionHolders-<rawValue>。
//
// 串流名稱必須與 read side 一致：GetPermissionHoldersPresenter 的
// categoryRule = .fromClass(withPrefix: "IAM_") 依 projector 類名產生 `IAM_GetPermissionHolders-`。
// GetPermissionHoldersPresenter 讀取這些 stream 重建當前持有者清單。
// 部署指令（由操作者手動執行）：
//   bash scripts/projection.sh（或直接在 KurrentDB UI 新增 Continuous Projection）
fromStreams(["$ce-IAMEmployeeAccess"])
.when({
    $init: function(){
        return {}
    },
    PrivilegeGranted: handleEvent,
    PrivilegeRevoked: handleEvent,
});

function handleEvent(state, event) {
    if (!event.isJson) { return; }
    var permissions = event.body["permissions"];
    if (!permissions || !Array.isArray(permissions)) { return; }
    for (var i = 0; i < permissions.length; i++) {
        linkTo("IAM_GetPermissionHolders-" + permissions[i], event);
    }
}
