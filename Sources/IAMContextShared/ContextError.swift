import Foundation

package struct ContextError<ErrorType: Error & Equatable>: Error, Equatable, CustomDebugStringConvertible {
    package let error: ErrorType
    let source: Source
    let message: String
    let timestamp: Date

    package init(error: ErrorType, in source: Source, message: String, timestamp: Date = .now) {
        self.error = error
        self.source = source
        self.message = message
        self.timestamp = timestamp
    }

    package var debugDescription: String {
        return "[\(timestamp)]`\(error)` happened \(source), message: \(message)."
    }
}

extension ContextError {
    package enum Source: CustomStringConvertible {
        case notType(function: String)
        case `actor`(AnyObject.Type, function: String)
        case `class`(AnyObject.Type, function: String)
        case `struct`(Any.Type, function: String)
        case `enum`(Any.Type, function: String)
        case custom(String, function: String)

        package var description: String{
            return switch self {
            case let .notType(function):
                "at \(function)"
            case let .actor(name, function):
                "at \(function) in \(name)(is a actor)"
            case let .class(name, function):
                "at \(function) in \(name)(is a class)"
            case let .struct(name, function):
                "at \(function) in \(name)(is a struct)"
            case let .enum(name, function):
                "at \(function) in \(name)(is a enum)"
            case let .custom(name, function):
                "at \(function) in \(name)"
            }
        }
    }
}

extension ContextError {
    package static func == (lhs: ContextError<ErrorType>, rhs: ContextError<ErrorType>) -> Bool {
        return lhs.error == rhs.error
    }
}
