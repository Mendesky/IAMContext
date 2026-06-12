import Foundation

package enum EmployeeStatusDto: String, Codable {
    case Active
    case Resigned
}

extension EmployeeStatus {
    package init(from dto: EmployeeStatusDto) {
        switch dto {
        case .Active: self = .Active
        case .Resigned: self = .Resigned
        }
    }
}

extension EmployeeStatusDto {
    package init(from domain: EmployeeStatus) {
        switch domain {
        case .Active: self = .Active
        case .Resigned: self = .Resigned
        }
    }
}
