import Foundation


extension ISO8601DateFormatter {
    package convenience init(timeZone: TimeZone) {
        self.init()
        self.timeZone = timeZone
        self.formatOptions = [.withFractionalSeconds, .withInternetDateTime]
    }
}

package struct Iso8601ParsingError: Error {
    package init() {}
}

extension Date {
    /// Parse ISO8601 string with fractional seconds + internet date time format.
    package init?(iso8601: String, timeZone: TimeZone = .gmt) {
        let dateFormatter = ISO8601DateFormatter(timeZone: timeZone)
        guard let value = dateFormatter.date(from: iso8601) else {
            return nil
        }
        self = value
    }

    /// Serialize to ISO8601 string with fractional seconds + internet date time format.
    package func iso8601String(timeZone: TimeZone = .gmt) -> String {
        let dateFormatter = ISO8601DateFormatter(timeZone: timeZone)
        return dateFormatter.string(from: self)
    }

    /// Parse optional ISO8601 string, throwing ``Iso8601ParsingError`` on malformed input.
    /// Returns `nil` when input is `nil`.
    package static func parseIso8601(
        _ string: String?,
        timeZone: TimeZone = .gmt
    ) throws -> Date? {
        guard let string else {
            return nil
        }
        guard let date = Date(iso8601: string, timeZone: timeZone) else {
            throw Iso8601ParsingError()
        }
        return date
    }

    /// Parse required ISO8601 string, throwing ``Iso8601ParsingError`` on malformed input.
    package static func parseIso8601(
        _ string: String,
        timeZone: TimeZone = .gmt
    ) throws -> Date {
        guard let date = Date(iso8601: string, timeZone: timeZone) else {
            throw Iso8601ParsingError()
        }
        return date
    }
}
