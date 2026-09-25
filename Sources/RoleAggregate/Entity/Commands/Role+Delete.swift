import DDDKit
import IAMContextShared

extension Role {
    package func when(event: RoleDeleted) throws {
        self.metadata.delete()
    }
}
