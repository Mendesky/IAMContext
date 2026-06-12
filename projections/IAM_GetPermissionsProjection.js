fromStreams(["$ce-IAMEmployeeAccess"])
.when({
    $init: function(){
        return {}
    },
    PrivilegeGranted: handleEvent,
    PrivilegeRevoked: handleEvent,
    RolesAssigned: handleEvent,
    RolesRevoked: handleEvent,
    UserPromoted: handleEvent,
    DepartmentTransferred: handleEvent,
    UserAccessProfileCreated: handleEvent,
});

function handleEvent(state, event) {
    if (event.isJson) {
        linkTo("IAM_GetPermissions-" + event.body["userId"], event);
    }
}
