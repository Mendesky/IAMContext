---
useCase: EmployeeAccess.assignRoles
useCaseSpecId: 02c13342-44eb-4b9c-9b8d-c69b8c08695b
aggregate: EmployeeAccess
sourceBundle: /Users/abnertsai/Downloads/Cosmogony IAMContext bundle.json
order: 4
status: ready
created: 2026-06-02
runbook:
  - run /usecase assignRoles
  - run /api assignRoles
  - run swift test
---

# assignRoles

## 1. Goal
指派 EmployeeAccess 角色，發出 `rolesAssigned` event。

## 2. Bundle Reference (auto-extracted)

**Input**:
- `employeeAccessId: String`
- `userId: String`
- `roles: Array[String]`

**Emits**: `rolesAssigned`

**Payload**:
- `employeeAccessId: String`
- `userId: String`
- `roles: Array[String]`

**Traceability**:
- `useCaseSpecId`: `02c13342-44eb-4b9c-9b8d-c69b8c08695b`
- `aggregateSpecId`: `e6838b7b-e62b-43eb-93f3-435006f8a661`

## 3. Invariants & Business Rules

> Aggregate-wide invariants — `ensureInvariant()` runs **all** checks after **every** mutation.

### checkUserId
- **Error code**: `userIdNotExist`
- **Title**: 確認 User ID 存在
- **Rules**: when `always`: `userId !== nil`；when `always`: `userId !== null`

### checkPermissions
- **Error code**: `permissionNotMatch`
- **Title**: 確認使用者身上的權限符合部門、職稱
- **Rules**: when `always`: `userPermissions ⊇ baseline(department, jobTitle)`

### employeeMustActive
- **Error code**: `employeeNotActive`
- **Title**: 員工必須在職
- **Rules**: when `always`: `status == activate`

**Preconditions (from bundle)**: roles not already in user.roles

## 4. High-level Goal
TODO

## 5. Error Cases

> §5 是 aggregate-wide 全集（每個 write UC 都可能 throw 任一 invariant）。非 create UC 額外含 `aggregateNotFound`（走 `repository.find`）。

| 條件 | Domain Error | HTTP |
|------|--------------|------|
| 確認 User ID 存在 | `ContextError<EmployeeAccessError>.userIdNotExist` | 422 unprocessableContent |
| 確認使用者身上的權限符合部門、職稱 | `ContextError<EmployeeAccessError>.permissionNotMatch` | 422 unprocessableContent |
| 員工必須在職 | `ContextError<EmployeeAccessError>.employeeNotActive` | 422 unprocessableContent |
| aggregate 不存在 | `DDDError.aggregateNotFound` | 404 notFound |

## 6. Test Scenarios (Gherkin)
```gherkin
Feature: assignRoles
  Scenario Outline: 成功指派角色
    Given an Active EmployeeAccess profile "<employeeAccessId>" for userId "<userId>" with roles [<existing>]
    When operator "op-admin" calls assignRoles with employeeAccessId "<employeeAccessId>", userId "<userId>", roles [<assign>]
    Then emits rolesAssigned with userId "<userId>", roles [<assign>]
    And the profile roles include [<assign>]
    Examples:
      | employeeAccessId | userId  | existing    | assign        |
      | ea-001           | u-alice | "developer" | "reviewer"    |
      | ea-002           | u-bob   | "developer" | "release-mgr" |

  @error
  Scenario: 目標 profile 不存在 → aggregateNotFound
    Given no EmployeeAccess profile "ea-404" exists
    When operator "op-admin" calls assignRoles with employeeAccessId "ea-404", userId "u-ghost", roles ["developer"]
    Then throws DDDError.aggregateNotFound

  @error
  Scenario: 員工已離職 → employeeNotActive
    Given an EmployeeAccess profile "ea-005" for userId "u-dan" with status "Resigned"
    When operator "op-admin" calls assignRoles with employeeAccessId "ea-005", userId "u-dan", roles ["developer"]
    Then throws ContextError<EmployeeAccessError>.employeeNotActive
```

> Note: roles 與 `permissionNotMatch`（只管 permissions）正交 → 不可能由角色指派觸發，故省略該 @error scenario。

## 7. Cross-aggregate Effects
- `rolesAssigned` 被 ReadModel `GetPermissions` 訂閱（同 aggregate EmployeeAccess，read-side projection）。

## 8. Implementation Notes
TODO
