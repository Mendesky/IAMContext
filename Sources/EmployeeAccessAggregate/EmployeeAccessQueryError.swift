import Foundation
import IAMContextShared


package enum EmployeeAccessQueryError: Error, Equatable {
    case notFound
}

extension ContextError where ErrorType == EmployeeAccessQueryError {
    package static func notFound(in source: Source, message: String) -> Self {
        return .init(error: .notFound, in: source, message: message)
    }
}
