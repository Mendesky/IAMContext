---
useCase: EmployeeAccess.revokePrivilege
useCaseSpecId: 0f6c159f-ef0c-4469-ad35-8fa4e43767e4
aggregate: EmployeeAccess
sourceBundle: /Users/abnertsai/Downloads/Cosmogony IAMContext bundle.json
order: 3
status: ready
created: 2026-06-02
runbook:
  - run /usecase revokePrivilege
  - run /api revokePrivilege
  - run swift test
---

# revokePrivilege

## 1. Goal
撤銷 EmployeeAccess 權限，發出 `privilegeRevoked` event。

## 2. Bundle Reference (auto-extracted)

**Input**:
- `employeeAccessId: String`
- `userId: String`
- `permissions: Array[String]`

**Emits**: `privilegeRevoked`

**Payload**:
- `employeeAccessId: String`
- `userId: String`
- `permissions: Array[String]`

**Traceability**:
- `useCaseSpecId`: `0f6c159f-ef0c-4469-ad35-8fa4e43767e4`
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

**Preconditions (from bundle)**: permissions all exist in user.permissions

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
Feature: revokePrivilege
  Scenario Outline: 成功撤銷非 baseline 權限
    Given an Active EmployeeAccess profile "<employeeAccessId>" for userId "<userId>" in "Engineering" as "Senior Engineer" with permissions ["repo:read","repo:write",<extra>]
    When operator "op-admin" calls revokePrivilege with employeeAccessId "<employeeAccessId>", userId "<userId>", permissions [<extra>]
    Then emits privilegeRevoked with userId "<userId>", permissions [<extra>]
    And the profile permissions still ⊇ baseline("Engineering","Senior Engineer")
    Examples:
      | employeeAccessId | userId  | extra       |
      | ea-001           | u-alice | "ci:deploy" |
      | ea-002           | u-bob   | "wiki:edit" |

  @error
  Scenario: 撤銷掉 baseline 必需權限 → permissionNotMatch
    Given an Active EmployeeAccess profile "ea-001" for userId "u-alice" in "Engineering" as "Senior Engineer" with permissions ["repo:read","repo:write"]
    When operator "op-admin" calls revokePrivilege with employeeAccessId "ea-001", userId "u-alice", permissions ["repo:write"]
    Then throws ContextError<EmployeeAccessError>.permissionNotMatch

  @error
  Scenario: 目標 profile 不存在 → aggregateNotFound
    Given no EmployeeAccess profile "ea-404" exists
    When operator "op-admin" calls revokePrivilege with employeeAccessId "ea-404", userId "u-ghost", permissions ["repo:read"]
    Then throws DDDError.aggregateNotFound

  @error
  Scenario: 員工已離職 → employeeNotActive
    Given an EmployeeAccess profile "ea-005" for userId "u-dan" with status "Resigned"
    When operator "op-admin" calls revokePrivilege with employeeAccessId "ea-005", userId "u-dan", permissions ["repo:read"]
    Then throws ContextError<EmployeeAccessError>.employeeNotActive
```

## 7. Cross-aggregate Effects
- `privilegeRevoked` 被 ReadModel `GetPermissions` 訂閱（同 aggregate EmployeeAccess，read-side projection）。

## 8. Implementation Notes
TODO
