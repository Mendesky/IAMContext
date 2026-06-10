import DDDKit
import IAMContextShared
extension EmployeeAccess {
    package func when(event: EmployeeAccessDeleted) throws {
        self.metadata.delete()
    }
}
