import Testing
import EmployeeAccessAggregate

private func entry(_ commit: UInt64, _ event: TimelineEvent, prepare: UInt64? = nil) -> TimelineEntry {
    TimelineEntry(position: LogPosition(commit: commit, prepare: prepare ?? commit), event: event)
}

private func replay(_ entries: [TimelineEntry]) -> Set<String> {
    PermissionTimeline.replay(entries)
}

@Test func created_event_adds_initial_permissions_and_initial_roles() {
    let entries = [
        entry(1, .roleCreated(roleId: "r")),
        entry(2, .rolePermissionsAdded(roleId: "r", permissions: ["p"])),
        entry(3, .profileCreated(permissions: ["q"], roles: ["r"])),
    ]

    #expect(replay(entries) == Set(["p", "q"]))
}

// 同一個 userId 建檔兩次（重新匯入）：後一次建檔重設起點，先前的直接授權與持有角色都不再有效；
// 第二次建檔之後的授權照常加入。對應 1.4.0 presenter 覆寫 permissions 的行為。
@Test func second_profile_created_resets_permissions_and_held_roles() {
    let entries = [
        entry(1, .rolePermissionsAdded(roleId: "r", permissions: ["fromRole"])),
        entry(2, .profileCreated(permissions: ["old1"], roles: ["r"])),
        entry(3, .privilegeGranted(permissions: ["old2"])),
        entry(4, .profileCreated(permissions: ["new1"], roles: [])),
        entry(5, .privilegeGranted(permissions: ["new2"])),
        entry(6, .rolePermissionsAdded(roleId: "r", permissions: ["laterFromRole"])),
    ]

    #expect(replay(entries) == Set(["new1", "new2"]))
}

@Test func privilege_granted_adds_and_revoked_removes_regardless_of_source() {
    let entries = [
        entry(1, .rolePermissionsAdded(roleId: "r", permissions: ["p"])),
        entry(2, .profileCreated(permissions: [], roles: ["r"])),
        entry(3, .privilegeGranted(permissions: ["q"])),
        entry(4, .privilegeRevoked(permissions: ["p", "q"])),
    ]

    #expect(replay(entries) == Set())
}

@Test func roles_assigned_adds_role_content_as_of_assignment_time() {
    let entries = [
        entry(1, .rolePermissionsAdded(roleId: "r", permissions: ["p"])),
        entry(2, .profileCreated(permissions: [], roles: [])),
        entry(3, .rolesAssigned(roleIds: ["r"])),
        entry(4, .rolePermissionsAdded(roleId: "r", permissions: ["q"])),
    ]

    #expect(replay(entries) == Set(["p", "q"]))
}

@Test func roles_revoked_keeps_permissions_supplied_by_other_held_roles() {
    let entries = [
        entry(1, .rolePermissionsAdded(roleId: "a", permissions: ["p", "q"])),
        entry(2, .rolePermissionsAdded(roleId: "b", permissions: ["p"])),
        entry(3, .profileCreated(permissions: [], roles: ["a", "b"])),
        entry(4, .rolesRevoked(roleIds: ["a"])),
    ]

    #expect(replay(entries) == Set(["p"]))
}

@Test func role_permission_added_to_held_role_adds_to_effective() {
    let entries = [
        entry(1, .profileCreated(permissions: [], roles: ["r"])),
        entry(2, .rolePermissionsAdded(roleId: "r", permissions: ["p"])),
    ]

    #expect(replay(entries) == Set(["p"]))
}

@Test func role_permission_removed_from_held_role_keeps_overlap_with_other_role() {
    let entries = [
        entry(1, .rolePermissionsAdded(roleId: "a", permissions: ["p", "q"])),
        entry(2, .rolePermissionsAdded(roleId: "b", permissions: ["p"])),
        entry(3, .profileCreated(permissions: [], roles: ["a", "b"])),
        entry(4, .rolePermissionsRemoved(roleId: "a", permissions: ["p", "q"])),
    ]

    #expect(replay(entries) == Set(["p"]))
}

@Test func role_deleted_behaves_like_role_revoked_and_keeps_overlap() {
    let entries = [
        entry(1, .rolePermissionsAdded(roleId: "a", permissions: ["p", "q"])),
        entry(2, .rolePermissionsAdded(roleId: "b", permissions: ["p"])),
        entry(3, .profileCreated(permissions: [], roles: ["a", "b"])),
        entry(4, .roleDeleted(roleId: "a")),
    ]

    #expect(replay(entries) == Set(["p"]))
}

@Test func events_of_roles_not_held_only_update_role_content() {
    let beforeAssignment = [
        entry(1, .profileCreated(permissions: [], roles: [])),
        entry(2, .rolePermissionsAdded(roleId: "r", permissions: ["p"])),
    ]
    let afterAssignment = beforeAssignment + [
        entry(3, .rolesAssigned(roleIds: ["r"])),
    ]

    #expect(replay(beforeAssignment) == Set())
    #expect(replay(afterAssignment) == Set(["p"]))
}

@Test func direct_grant_is_not_preserved_when_role_that_also_has_it_is_revoked_removed_or_deleted() {
    let roleRevoked = [
        entry(1, .rolePermissionsAdded(roleId: "r", permissions: ["p"])),
        entry(2, .profileCreated(permissions: [], roles: ["r"])),
        entry(3, .privilegeGranted(permissions: ["p"])),
        entry(4, .rolesRevoked(roleIds: ["r"])),
    ]
    let roleRemoved = [
        entry(1, .rolePermissionsAdded(roleId: "r", permissions: ["p"])),
        entry(2, .profileCreated(permissions: [], roles: ["r"])),
        entry(3, .privilegeGranted(permissions: ["p"])),
        entry(4, .rolePermissionsRemoved(roleId: "r", permissions: ["p"])),
    ]
    let roleDeleted = [
        entry(1, .rolePermissionsAdded(roleId: "r", permissions: ["p"])),
        entry(2, .profileCreated(permissions: [], roles: ["r"])),
        entry(3, .privilegeGranted(permissions: ["p"])),
        entry(4, .roleDeleted(roleId: "r")),
    ]

    #expect(replay(roleRevoked) == Set())
    #expect(replay(roleRemoved) == Set())
    #expect(replay(roleDeleted) == Set())
}

@Test func latest_event_wins_after_individual_revoke_direct_grant_reassign_and_role_readd() {
    #expect(replay([
        entry(1, .rolePermissionsAdded(roleId: "r", permissions: ["p"])),
        entry(2, .profileCreated(permissions: [], roles: ["r"])),
        entry(3, .privilegeRevoked(permissions: ["p"])),
        entry(4, .privilegeGranted(permissions: ["p"])),
    ]) == Set(["p"]))

    #expect(replay([
        entry(1, .rolePermissionsAdded(roleId: "r", permissions: ["p"])),
        entry(2, .profileCreated(permissions: [], roles: ["r"])),
        entry(3, .privilegeRevoked(permissions: ["p"])),
        entry(4, .rolesRevoked(roleIds: ["r"])),
        entry(5, .rolesAssigned(roleIds: ["r"])),
    ]) == Set(["p"]))

    #expect(replay([
        entry(1, .profileCreated(permissions: [], roles: ["r"])),
        entry(2, .rolePermissionsAdded(roleId: "r", permissions: ["p"])),
        entry(3, .privilegeRevoked(permissions: ["p"])),
        entry(4, .rolePermissionsRemoved(roleId: "r", permissions: ["p"])),
        entry(5, .rolePermissionsAdded(roleId: "r", permissions: ["p"])),
    ]) == Set(["p"]))

    #expect(replay([
        entry(1, .profileCreated(permissions: ["p"], roles: ["r"])),
        entry(2, .privilegeRevoked(permissions: ["p"])),
        entry(3, .rolePermissionsAdded(roleId: "r", permissions: ["p"])),
    ]) == Set(["p"]))

    #expect(replay([
        entry(1, .rolePermissionsAdded(roleId: "r", permissions: ["p"])),
        entry(2, .profileCreated(permissions: [], roles: ["r"])),
        entry(3, .privilegeGranted(permissions: ["p"])),
        entry(4, .roleDeleted(roleId: "r")),
        entry(5, .privilegeGranted(permissions: ["p"])),
    ]) == Set(["p"]))
}

@Test func entries_are_ordered_by_commit_then_prepare_not_by_input_order() {
    let entries = [
        entry(1, .privilegeRevoked(permissions: ["p"]), prepare: 3),
        entry(1, .privilegeGranted(permissions: ["p"]), prepare: 2),
        entry(1, .profileCreated(permissions: [], roles: []), prepare: 1),
    ]

    #expect(replay(entries) == Set())
}

@Test func simultaneous_revoke_of_overlapping_roles_removes_shared_permission() {
    let entries = [
        entry(1, .rolePermissionsAdded(roleId: "a", permissions: ["p"])),
        entry(2, .rolePermissionsAdded(roleId: "b", permissions: ["p"])),
        entry(3, .profileCreated(permissions: [], roles: ["a", "b"])),
        entry(4, .rolesRevoked(roleIds: ["a", "b"])),
    ]

    #expect(replay(entries) == Set())
}

@Test func deleted_role_content_is_empty_afterwards_and_reassign_or_revoke_is_noop() {
    let entries = [
        entry(1, .rolePermissionsAdded(roleId: "r", permissions: ["p"])),
        entry(2, .profileCreated(permissions: [], roles: ["r"])),
        entry(3, .roleDeleted(roleId: "r")),
        entry(4, .rolesAssigned(roleIds: ["r"])),
        entry(5, .rolesRevoked(roleIds: ["r"])),
    ]

    #expect(replay(entries) == Set())
}

@Test func unknown_role_contributes_nothing() {
    let entries = [
        entry(1, .profileCreated(permissions: [], roles: ["legacy-role"])),
        entry(2, .rolesAssigned(roleIds: ["other-unknown"])),
    ]

    #expect(replay(entries) == Set())
}

@Test func equal_positions_fall_back_to_input_order_for_synthetic_history() {
    let grantThenRevoke = [
        entry(0, .profileCreated(permissions: [], roles: []), prepare: 0),
        entry(0, .privilegeGranted(permissions: ["p"]), prepare: 0),
        entry(0, .privilegeRevoked(permissions: ["p"]), prepare: 0),
    ]
    let revokeThenGrant = [
        entry(0, .profileCreated(permissions: [], roles: []), prepare: 0),
        entry(0, .privilegeRevoked(permissions: ["p"]), prepare: 0),
        entry(0, .privilegeGranted(permissions: ["p"]), prepare: 0),
    ]

    #expect(replay(grantThenRevoke) == Set())
    #expect(replay(revokeThenGrant) == Set(["p"]))
}

@Test func mentioned_role_ids_collects_initial_assigned_and_revoked_roles() {
    let entries = [
        entry(1, .profileCreated(permissions: [], roles: ["a"])),
        entry(2, .privilegeGranted(permissions: ["p"])),
        entry(3, .rolesAssigned(roleIds: ["b"])),
        entry(4, .rolesRevoked(roleIds: ["c"])),
        entry(5, .roleCreated(roleId: "d")),
        entry(6, .rolePermissionsAdded(roleId: "e", permissions: ["q"])),
        entry(7, .rolePermissionsRemoved(roleId: "f", permissions: ["r"])),
        entry(8, .roleDeleted(roleId: "g")),
    ]

    #expect(PermissionTimeline.mentionedRoleIds(in: entries) == Set(["a", "b", "c"]))
}

@Test func roles_revoked_for_roles_not_held_is_noop() {
    let entries = [
        entry(1, .profileCreated(permissions: ["p"], roles: [])),
        entry(2, .rolePermissionsAdded(roleId: "r", permissions: ["p"])),
        entry(3, .rolesRevoked(roleIds: ["r"])),
    ]

    #expect(replay(entries) == Set(["p"]))
}

@Test func duplicate_employee_entries_do_not_change_result() {
    let roleEntries = [
        entry(1, .rolePermissionsAdded(roleId: "r", permissions: ["p", "q"])),
    ]
    let employeeEntries = [
        entry(2, .profileCreated(permissions: ["direct"], roles: [])),
        entry(3, .rolesAssigned(roleIds: ["r"])),
        entry(4, .privilegeRevoked(permissions: ["p"])),
        entry(5, .rolesRevoked(roleIds: ["r"])),
    ]
    let once = roleEntries + employeeEntries
    let duplicated = roleEntries + employeeEntries + employeeEntries

    #expect(replay(once) == Set(["direct"]))
    #expect(replay(duplicated) == Set(["direct"]))
}
