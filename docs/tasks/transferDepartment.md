---
useCase: EmployeeAccess.transferDepartment
useCaseSpecId: a14fd17a-d9f3-4d4d-a45f-8c9f7f5c2ce2
aggregate: EmployeeAccess
sourceBundle: /Users/abnertsai/Downloads/Cosmogony IAMContext bundle.json
order: 7
status: ready
created: 2026-06-02
runbook:
  - run /usecase transferDepartment
  - run /api transferDepartment
  - run swift test
---

# transferDepartment

## 1. Goal
轉調 EmployeeAccess 部門，發出 `departmentTransferred` event。

## 2. Bundle Reference (auto-extracted)

**Input**:
- `employeeAccessId: String`
- `userId: String`
- `newDepartment: String`
- `newJobTitle: String`

**Emits**: `departmentTransferred`

**Payload**:
- `employeeAccessId: String`
- `userId: String`
- `newDepartment: String`
- `newJobTitle: String`

**Traceability**:
- `useCaseSpecId`: `a14fd17a-d9f3-4d4d-a45f-8c9f7f5c2ce2`
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

**Preconditions (from bundle)**: (newDepartment, newJobTitle) != (current department, jobTitle)

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
Feature: transferDepartment
  Scenario Outline: 成功部門轉調（既有權限涵蓋新部門/職稱 baseline）
    Given an Active EmployeeAccess profile "<employeeAccessId>" for userId "<userId>" in "Engineering" as "Senior Engineer" with permissions ["repo:read","repo:write","ledger:read"]
    When operator "op-admin" calls transferDepartment with employeeAccessId "<employeeAccessId>", userId "<userId>", newDepartment "<newDepartment>", newJobTitle "<newJobTitle>"
    Then emits departmentTransferred with userId "<userId>", newDepartment "<newDepartment>", newJobTitle "<newJobTitle>"
    Examples:
      | employeeAccessId | userId  | newDepartment | newJobTitle |
      | ea-001           | u-alice | Finance       | Accountant  |

  @error
  Scenario: 轉調後權限不足新 baseline → permissionNotMatch
    Given an Active EmployeeAccess profile "ea-002" for userId "u-bob" in "Engineering" as "Senior Engineer" with permissions ["repo:read","repo:write"]
    When operator "op-admin" calls transferDepartment with employeeAccessId "ea-002", userId "u-bob", newDepartment "Finance", newJobTitle "Accountant"
    Then throws ContextError<EmployeeAccessError>.permissionNotMatch

  @error
  Scenario: 目標 profile 不存在 → aggregateNotFound
    Given no EmployeeAccess profile "ea-404" exists
    When operator "op-admin" calls transferDepartment with employeeAccessId "ea-404", userId "u-ghost", newDepartment "Finance", newJobTitle "Accountant"
    Then throws DDDError.aggregateNotFound

  @error
  Scenario: 員工已離職 → employeeNotActive
    Given an EmployeeAccess profile "ea-005" for userId "u-dan" with status "Resigned"
    When operator "op-admin" calls transferDepartment with employeeAccessId "ea-005", userId "u-dan", newDepartment "Finance", newJobTitle "Accountant"
    Then throws ContextError<EmployeeAccessError>.employeeNotActive
```

## 7. Cross-aggregate Effects
- `departmentTransferred` 被 ReadModel `GetPermissions` 訂閱（同 aggregate EmployeeAccess，read-side projection）。

## 8. Implementation Notes
TODO
