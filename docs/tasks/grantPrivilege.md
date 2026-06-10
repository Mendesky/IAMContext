---
useCase: EmployeeAccess.grantPrivilege
useCaseSpecId: 55657110-16a7-4495-9b35-938f26f86dc1
aggregate: EmployeeAccess
sourceBundle: /Users/abnertsai/Downloads/Cosmogony IAMContext bundle.json
order: 2
status: ready
created: 2026-06-02
runbook:
  - run /usecase grantPrivilege
  - run /api grantPrivilege
  - run swift test
---

# grantPrivilege

## 1. Goal
授予 EmployeeAccess 權限，發出 `privilegeGranted` event。

## 2. Bundle Reference (auto-extracted)

**Input**:
- `employeeAccessId: String`
- `userId: String`
- `permissions: Array[String]`

**Emits**: `privilegeGranted`

**Payload**:
- `employeeAccessId: String`
- `userId: String`
- `permissions: Array[String]`

**Traceability**:
- `useCaseSpecId`: `55657110-16a7-4495-9b35-938f26f86dc1`
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

**Preconditions (from bundle)**: permissions not already in user.permissions

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
Feature: grantPrivilege
  Scenario Outline: 成功授予權限
    Given an Active EmployeeAccess profile "<employeeAccessId>" for userId "<userId>" in "Engineering" as "Senior Engineer" with permissions [<existing>]
    When operator "op-admin" calls grantPrivilege with employeeAccessId "<employeeAccessId>", userId "<userId>", permissions [<grant>]
    Then emits privilegeGranted with userId "<userId>", permissions [<grant>]
    And the profile permissions include [<grant>]
    Examples:
      | employeeAccessId | userId  | existing                 | grant       |
      | ea-001           | u-alice | "repo:read","repo:write" | "ci:deploy" |
      | ea-002           | u-bob   | "repo:read","repo:write" | "wiki:edit" |

  @error
  Scenario: 目標 profile 不存在 → aggregateNotFound
    Given no EmployeeAccess profile "ea-404" exists
    When operator "op-admin" calls grantPrivilege with employeeAccessId "ea-404", userId "u-ghost", permissions ["repo:read"]
    Then throws DDDError.aggregateNotFound

  @error
  Scenario: 員工已離職 → employeeNotActive
    Given an EmployeeAccess profile "ea-005" for userId "u-dan" with status "Resigned"
    When operator "op-admin" calls grantPrivilege with employeeAccessId "ea-005", userId "u-dan", permissions ["repo:read"]
    Then throws ContextError<EmployeeAccessError>.employeeNotActive
```

> Note: 授予只會擴增 permissions → 不可能違反 `permissionNotMatch`（superset 守恆），故省略該 @error scenario。

## 7. Cross-aggregate Effects
- `privilegeGranted` 被 ReadModel `GetPermissions` 訂閱（同 aggregate EmployeeAccess，read-side projection）。

## 8. Implementation Notes
TODO
