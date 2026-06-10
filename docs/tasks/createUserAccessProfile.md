---
useCase: EmployeeAccess.createUserAccessProfile
useCaseSpecId: d6cb9bc9-d92a-4e46-9d9f-23b0b1d1115f
aggregate: EmployeeAccess
sourceBundle: /Users/abnertsai/Downloads/Cosmogony IAMContext bundle.json
order: 1
status: ready
created: 2026-06-02
runbook:
  - run /usecase createUserAccessProfile
  - run /api createUserAccessProfile
  - run swift test
---

# createUserAccessProfile

## 1. Goal
建立 EmployeeAccess（使用者存取設定檔），發出 `userAccessProfileCreated` event。

## 2. Bundle Reference (auto-extracted)

**Input**:
- `employeeAccessId: String`
- `userId: String`
- `department: String`
- `jobTitle: String`

**Emits**: `userAccessProfileCreated`

**Payload**:
- `employeeAccessId: String`
- `userId: String`
- `department: String`
- `jobTitle: String`
- `permissions: Set[String]`
- `roles: Set[String]`
- `status: EmployeeStatus`

**Traceability**:
- `useCaseSpecId`: `d6cb9bc9-d92a-4e46-9d9f-23b0b1d1115f`
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

**Preconditions (from bundle)**: _(none)_

## 4. High-level Goal
TODO

## 5. Error Cases

> §5 是 aggregate-wide 全集（每個 write UC 都可能 throw 任一 invariant）。**create UC 不含 `aggregateNotFound`**（aggregate 由 `UUID()` 新生）。

| 條件 | Domain Error | HTTP |
|------|--------------|------|
| 確認 User ID 存在 | `ContextError<EmployeeAccessError>.userIdNotExist` | 422 unprocessableContent |
| 確認使用者身上的權限符合部門、職稱 | `ContextError<EmployeeAccessError>.permissionNotMatch` | 422 unprocessableContent |
| 員工必須在職 | `ContextError<EmployeeAccessError>.employeeNotActive` | 422 unprocessableContent |

## 6. Test Scenarios (Gherkin)
```gherkin
Feature: createUserAccessProfile
  Scenario Outline: 成功建立 UserAccessProfile
    Given operator "<operator>" is authenticated
    And no EmployeeAccess profile exists for userId "<userId>"
    When operator "<operator>" calls createUserAccessProfile with employeeAccessId "<employeeAccessId>", userId "<userId>", department "<department>", jobTitle "<jobTitle>"
    Then emits userAccessProfileCreated with userId "<userId>", department "<department>", jobTitle "<jobTitle>", status "Active"
    And permissions equal baseline(<department>, <jobTitle>)
    Examples:
      | operator | employeeAccessId | userId  | department  | jobTitle        |
      | op-admin | ea-001           | u-alice | Engineering | Engineer        |
      | op-admin | ea-002           | u-bob   | Engineering | Senior Engineer |
      | op-admin | ea-003           | u-cara  | Finance     | Accountant      |

  @error
  Scenario: userId 為空 → userIdNotExist
    Given operator "op-admin" is authenticated
    When operator "op-admin" calls createUserAccessProfile with employeeAccessId "ea-004", userId "", department "Engineering", jobTitle "Engineer"
    Then throws ContextError<EmployeeAccessError>.userIdNotExist
```

> Note: `permissionNotMatch` / `employeeNotActive` 在 create 時 satisfied-by-construction（status=Active、permissions=baseline）→ 無對應 @error scenario。

## 7. Cross-aggregate Effects
- `userAccessProfileCreated` 被 ReadModel `GetPermissions` 訂閱（同 aggregate EmployeeAccess，read-side projection）。

## 8. Implementation Notes
TODO
