---
useCase: EmployeeAccess.revokeRoles
useCaseSpecId: 82221cb6-b1b8-4baf-8b15-43c0debf08a7
aggregate: EmployeeAccess
sourceBundle: /Users/abnertsai/Downloads/Cosmogony IAMContext bundle.json
order: 5
status: ready
created: 2026-06-02
runbook:
  - run /usecase revokeRoles
  - run /api revokeRoles
  - run swift test
---

# revokeRoles

## 1. Goal
撤銷 EmployeeAccess 角色，發出 `rolesRevoked` event。

## 2. Bundle Reference (auto-extracted)

**Input**:
- `employeeAccessId: String`
- `userId: String`
- `roles: Array[String]`

**Emits**: `rolesRevoked`

**Payload**:
- `employeeAccessId: String`
- `userId: String`
- `roles: Array[String]`

**Traceability**:
- `useCaseSpecId`: `82221cb6-b1b8-4baf-8b15-43c0debf08a7`
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

**Preconditions (from bundle)**: roles all exist in user.roles

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
Feature: revokeRoles
  Scenario Outline: 成功撤銷角色
    Given an Active EmployeeAccess profile "<employeeAccessId>" for userId "<userId>" with roles ["developer",<extra>]
    When operator "op-admin" calls revokeRoles with employeeAccessId "<employeeAccessId>", userId "<userId>", roles [<extra>]
    Then emits rolesRevoked with userId "<userId>", roles [<extra>]
    Examples:
      | employeeAccessId | userId  | extra         |
      | ea-001           | u-alice | "reviewer"    |
      | ea-002           | u-bob   | "release-mgr" |

  @error
  Scenario: 目標 profile 不存在 → aggregateNotFound
    Given no EmployeeAccess profile "ea-404" exists
    When operator "op-admin" calls revokeRoles with employeeAccessId "ea-404", userId "u-ghost", roles ["developer"]
    Then throws DDDError.aggregateNotFound

  @error
  Scenario: 員工已離職 → employeeNotActive
    Given an EmployeeAccess profile "ea-005" for userId "u-dan" with status "Resigned"
    When operator "op-admin" calls revokeRoles with employeeAccessId "ea-005", userId "u-dan", roles ["developer"]
    Then throws ContextError<EmployeeAccessError>.employeeNotActive
```

> Note: roles 與 `permissionNotMatch`（只管 permissions）正交 → 不可能由角色撤銷觸發，故省略該 @error scenario。

## 7. Cross-aggregate Effects
- `rolesRevoked` 被 ReadModel `GetPermissions` 訂閱（同 aggregate EmployeeAccess，read-side projection）。

## 8. Implementation Notes
TODO
