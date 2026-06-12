---
useCase: EmployeeAccess.promoteUser
useCaseSpecId: 1174adb8-418d-4c8f-a200-db124688138f
aggregate: EmployeeAccess
sourceBundle: /Users/abnertsai/Downloads/Cosmogony IAMContext bundle.json
order: 6
status: ready
created: 2026-06-02
runbook:
  - run /usecase promoteUser
  - run /api promoteUser
  - run swift test
---

# promoteUser

## 1. Goal
升遷 EmployeeAccess 使用者，發出 `userPromoted` event。

## 2. Bundle Reference (auto-extracted)

**Input**:
- `employeeAccessId: String`
- `userId: String`
- `newJobTitle: String`
- `oldJobTitle: String`

**Emits**: `userPromoted`

**Payload**:
- `employeeAccessId: String`
- `userId: String`
- `newJobTitle: String`
- `oldJobTitle: String`

**Traceability**:
- `useCaseSpecId`: `1174adb8-418d-4c8f-a200-db124688138f`
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

**Preconditions (from bundle)**: status == Active

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
Feature: promoteUser
  Scenario Outline: 成功升遷（既有權限已涵蓋新職稱 baseline）
    Given an Active EmployeeAccess profile "<employeeAccessId>" for userId "<userId>" in "Engineering" as "<oldJobTitle>" with permissions ["repo:read","repo:write","ci:deploy"]
    When operator "op-admin" calls promoteUser with employeeAccessId "<employeeAccessId>", userId "<userId>", newJobTitle "<newJobTitle>", oldJobTitle "<oldJobTitle>"
    Then emits userPromoted with userId "<userId>", newJobTitle "<newJobTitle>", oldJobTitle "<oldJobTitle>"
    Examples:
      | employeeAccessId | userId | oldJobTitle     | newJobTitle |
      | ea-002           | u-bob  | Senior Engineer | Tech Lead   |

  @error
  Scenario: 升遷後權限不足新職稱 baseline → permissionNotMatch
    Given an Active EmployeeAccess profile "ea-001" for userId "u-alice" in "Engineering" as "Senior Engineer" with permissions ["repo:read","repo:write"]
    When operator "op-admin" calls promoteUser with employeeAccessId "ea-001", userId "u-alice", newJobTitle "Tech Lead", oldJobTitle "Senior Engineer"
    Then throws ContextError<EmployeeAccessError>.permissionNotMatch

  @error
  Scenario: 目標 profile 不存在 → aggregateNotFound
    Given no EmployeeAccess profile "ea-404" exists
    When operator "op-admin" calls promoteUser with employeeAccessId "ea-404", userId "u-ghost", newJobTitle "Tech Lead", oldJobTitle "Senior Engineer"
    Then throws DDDError.aggregateNotFound

  @error
  Scenario: 員工已離職 → employeeNotActive
    Given an EmployeeAccess profile "ea-005" for userId "u-dan" with status "Resigned"
    When operator "op-admin" calls promoteUser with employeeAccessId "ea-005", userId "u-dan", newJobTitle "Tech Lead", oldJobTitle "Senior Engineer"
    Then throws ContextError<EmployeeAccessError>.employeeNotActive
```

## 7. Cross-aggregate Effects
- `userPromoted` 被 ReadModel `GetPermissions` 訂閱（同 aggregate EmployeeAccess，read-side projection）。

## 8. Implementation Notes
TODO
