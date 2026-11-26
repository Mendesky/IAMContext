import Foundation
import IAMContextShared

package enum RoleError: Error, Equatable {
    case roleNameRequired
    case roleNameDuplicated
    case roleNameUnchanged
    case descriptionUnchanged
    case permissionsUnchanged
    case invalidPermission
    // Added 2026-11-26（權限帶範圍，docs/discussions/2026-11-25-scoped-permission-grant.md D13）：角色不能帶範圍，所以不能放範圍化的權限。
    case scopedPermissionNotAllowed
}

extension ContextError where ErrorType == RoleError {
    static func roleNameRequired(function: String = #function, message: String = "") -> Self {
        .init(error: .roleNameRequired, in: .class(Role.self, function: function), message: message)
    }
    static func roleNameDuplicated(function: String = #function, message: String = "") -> Self {
        .init(error: .roleNameDuplicated, in: .class(Role.self, function: function), message: message)
    }
    static func roleNameUnchanged(function: String = #function, message: String = "") -> Self {
        .init(error: .roleNameUnchanged, in: .class(Role.self, function: function), message: message)
    }
    static func descriptionUnchanged(function: String = #function, message: String = "") -> Self {
        .init(error: .descriptionUnchanged, in: .class(Role.self, function: function), message: message)
    }
    static func permissionsUnchanged(function: String = #function, message: String = "") -> Self {
        .init(error: .permissionsUnchanged, in: .class(Role.self, function: function), message: message)
    }
    static func invalidPermission(function: String = #function, message: String = "") -> Self {
        .init(error: .invalidPermission, in: .class(Role.self, function: function), message: message)
    }
    static func scopedPermissionNotAllowed(function: String = #function, message: String = "") -> Self {
        .init(error: .scopedPermissionNotAllowed, in: .class(Role.self, function: function), message: message)
    }
}
