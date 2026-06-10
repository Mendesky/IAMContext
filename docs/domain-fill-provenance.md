# /domain-fill provenance log

Each entry records: `file : hole-kind : method | 人 dictate 原文 | 填入 Swift`.
Reviewer 用途：核實「填入的 Swift 源於人口述的意圖」（admissibility，非自證語意正確）。

---

## EmployeeAccess.swift : ensureInvariant : ensureInvariant()  — FILLED (partial)

**人 dictate 原文**：
- (a) 「針對 a 來說的話，不只是 nil，連空字串的部分也需要擋」
- (b) 「Department 跟 Job Title 都會有各自的 Permission，它本身的 Permission 要都被這兩個包含才可以算通過。也就是說，User Permission 可以比 Department 還有 Job Title 的 Permission 還要多，但是一定要包含這兩個所擁有的所有 Permissions」→ 人選 **held**（baseline 來源未定）
- (c) 「C 的部分就是如你所猜測的一樣」（status == .Active）

**填入 Swift**：
```swift
// (a)
guard let userId, !userId.isEmpty else {
    throw ContextError<EmployeeAccessError>.userIdNotExist(function: #function, message: "userId must be present and non-empty")
}
// (c)
guard status == .Active else {
    throw ContextError<EmployeeAccessError>.employeeNotActive(function: #function, message: "employee status must be Active")
}
// (b) held → #error 保留（baseline source undefined）
```

---

## EmployeeAccess+GrantPrivilege.swift : command-precondition : grantPrivilege()  — HELD (captured, blocked)

**人 dictate 原文**：「當 permission 存在時，請回傳 error 表示該權限已存在於該用戶。」
**確認語意**：要授予的 permissions 中任一個已存在於 self.permissions → throw「該權限已存在」。

**held 原因（blocker）**：EmployeeAccessError 無對應 case。人決定**新增 `permissionAlreadyExists`**（改 EmployeeAccessError.swift + errors.md，domain-fill 範疇外）。
**待辦**：(1) 加 `permissionAlreadyExists` error code；(2) 回填本 guard：
```swift
// 預定填入（待 error code 就緒）：
guard !permissions.contains(where: { (self.permissions ?? []).contains($0) }) else {
    throw ContextError<EmployeeAccessError>.permissionAlreadyExists(function: #function, message: "permission already granted to user")
}
let event = PrivilegeGranted(id: UUID(), employeeAccessId: self.id, userId: userId, permissions: permissions, occurred: .now)
try self.apply(event: event)
```
（上述為擷取意圖的暫存草稿，非已寫入；#error 仍在檔案中。）

---

## EmployeeAccess+GrantPrivilege.swift : when-reducer : when(event: PrivilegeGranted)  — FILLED

**人 dictate 原文**：「聯集加入（nil 視為空）」
**填入 Swift**：
```swift
self.permissions = (self.permissions ?? []).union(event.permissions)
```

---

## EmployeeAccess+RevokePrivilege.swift : command-precondition : revokePrivilege()  — HELD (captured, blocked)

**人 dictate 原文**：「沒有的話會回傳 permission XXX is not exist.」
**確認語意**：要撤銷的 permissions 中任一個不存在於 self.permissions → throw「permission <X> does not exist」。

**held 原因（blocker）**：EmployeeAccessError 無對應 case。人決定**新增 `permissionNotExist`**。
**待辦**：(1) 加 `permissionNotExist`；(2) 回填本 guard：
```swift
// 預定填入（待 error code 就緒）：
if let missing = permissions.first(where: { !(self.permissions ?? []).contains($0) }) {
    throw ContextError<EmployeeAccessError>.permissionNotExist(function: #function, message: "permission \(missing) does not exist for user")
}
let event = PrivilegeRevoked(id: UUID(), employeeAccessId: self.id, userId: userId, permissions: permissions, occurred: .now)
try self.apply(event: event)
```

---

## EmployeeAccess+RevokePrivilege.swift : when-reducer : when(event: PrivilegeRevoked)  — FILLED

**人 dictate 原文**：「差集移除（nil 視為空）」
**填入 Swift**：
```swift
self.permissions = (self.permissions ?? []).subtracting(event.permissions)
```

---

## EmployeeAccess+AssignRoles.swift : command-precondition : assignRoles()  — HELD (captured, blocked)

**人 dictate 原文**：「同 grant：throw roleAlreadyExists」（與 grantPrivilege 對稱）
**確認語意**：要指派的 roles 中任一個已存在於 self.roles → throw「該角色已存在」。
**held 原因（blocker）**：需新增 `roleAlreadyExists`。
**待辦**：(1) 加 `roleAlreadyExists`；(2) 回填本 guard：
```swift
guard !roles.contains(where: { (self.roles ?? []).contains($0) }) else {
    throw ContextError<EmployeeAccessError>.roleAlreadyExists(function: #function, message: "role already assigned to user")
}
let event = RolesAssigned(id: UUID(), employeeAccessId: self.id, userId: userId, roles: roles, occurred: .now)
try self.apply(event: event)
```

---

## EmployeeAccess+AssignRoles.swift : when-reducer : when(event: RolesAssigned)  — FILLED

**人 dictate 原文**：「聯集加入（nil 視為空）」
**填入 Swift**：
```swift
self.roles = (self.roles ?? []).union(event.roles)
```

---

## EmployeeAccess+RevokeRoles.swift : command-precondition : revokeRoles()  — HELD (captured, blocked)

**人 dictate 原文**：「同 revoke：throw roleNotExist」
**確認語意**：要撤銷的 roles 中任一不存在於 self.roles → throw「該角色不存在」。
**held 原因（blocker）**：需新增 `roleNotExist`。
**待辦**：(1) 加 `roleNotExist`；(2) 回填本 guard：
```swift
if let missing = roles.first(where: { !(self.roles ?? []).contains($0) }) {
    throw ContextError<EmployeeAccessError>.roleNotExist(function: #function, message: "role \(missing) does not exist for user")
}
let event = RolesRevoked(id: UUID(), employeeAccessId: self.id, userId: userId, roles: roles, occurred: .now)
try self.apply(event: event)
```

---

## EmployeeAccess+RevokeRoles.swift : when-reducer : when(event: RolesRevoked)  — FILLED

**人 dictate 原文**：「差集移除（nil 視為空）」
**填入 Swift**：
```swift
self.roles = (self.roles ?? []).subtracting(event.roles)
```

---

## EmployeeAccess+PromoteUser.swift : command-precondition : promoteUser()  — FILLED

**人 dictate 原文**：「只擋 status：throw employeeNotActive」
**填入 Swift**：
```swift
guard status == .Active else {
    throw ContextError<EmployeeAccessError>.employeeNotActive(function: #function, message: "employee status must be Active to promote")
}
let event = UserPromoted(id: UUID(), employeeAccessId: self.id, userId: userId, newJobTitle: newJobTitle, oldJobTitle: oldJobTitle, occurred: .now)
try self.apply(event: event)
```

---

## EmployeeAccess+PromoteUser.swift : when-reducer : when(event: UserPromoted)  — FILLED

**人 dictate 原文**：「self.jobTitle = event.newJobTitle」
**填入 Swift**：
```swift
self.jobTitle = event.newJobTitle
```

---

## EmployeeAccess+TransferDepartment.swift : command-precondition : transferDepartment()  — HELD (captured, blocked)

**人 dictate 原文**：「回傳 error，訊息為：職稱、部門沒有變化。」
**確認語意**：newDepartment == self.department && newJobTitle == self.jobTitle（完全沒變）→ throw「職稱、部門沒有變化」。
**held 原因（blocker）**：需新增 `departmentUnchanged`。
**待辦**：(1) 加 `departmentUnchanged`；(2) 回填本 guard：
```swift
guard !(newDepartment == self.department && newJobTitle == self.jobTitle) else {
    throw ContextError<EmployeeAccessError>.departmentUnchanged(function: #function, message: "職稱、部門沒有變化")
}
let event = DepartmentTransferred(id: UUID(), employeeAccessId: self.id, userId: userId, newDepartment: newDepartment, newJobTitle: newJobTitle, occurred: .now)
try self.apply(event: event)
```

---

## EmployeeAccess+TransferDepartment.swift : when-reducer : when(event: DepartmentTransferred)  — FILLED

**人 dictate 原文**：「department + jobTitle 都更新」
**填入 Swift**：
```swift
self.department = event.newDepartment
self.jobTitle = event.newJobTitle
```

---

## POST-ROUND RESOLUTION (human-authorized 2026-06-03)

新增 5 個 error code（`EmployeeAccessError.swift` + `errors.md`）並回填原本 held 的 5 個 command guard：
- grantPrivilege → `permissionAlreadyExists` — **FILLED**
- revokePrivilege → `permissionNotExist` — **FILLED**
- assignRoles → `roleAlreadyExists` — **FILLED**
- revokeRoles → `roleNotExist` — **FILLED**
- transferDepartment → `departmentUnchanged` — **FILLED**

仍 HELD（待業務輸入）：`ensureInvariant` (b) `permissionNotMatch` — baseline(department, jobTitle) 來源未定。

---

## PLACEHOLDER RESOLUTION (human-authorized 2026-06-03, 假資料測試)

- **allPermissions**：新增 placeholder 假 universe（12 個 fake 字串，待真正權限方案替換）。
- **ensureInvariant (b)**：人選「不強制」→ `required = []` → 一律通過（placeholder；之後改真正 baseline 對照表）。原 HELD 解除。
- **convenience init**：新人 `permissions = Self.allPermissions, roles = [], status = .Active`（placeholder；roles 未指定先空）。
- **event 簽名修正**：移除 5 個 command event 建構殘留的 `id: UUID()`（generated init 第一參數為 employeeAccessId，非 event id；grantPrivilege 由 user/linter 先修，其餘 5 個由本次對齊）。
- **scaffold 修正（domain-fill 範疇外，為了過 build）**：
  (1) 移除 `EmployeeAccess` 重複 `id`（`var id: String?`）；
  (2) `PermissionsReadModel.employeeAccessId` 補回 bundle 宣告的預設值 `""`；
  (3) `ApiComponents+EmployeeAccessApiError` 的 switch 對 5 個新 code 回 `nil`（待 /api 補 OpenAPI 映射 + HTTP status）。

**swift build：通過（exit 0）。**
