import EventSourcing
import IAMContextShared

package class PermissionsReadModel: ReadModel {
    package var id: String { employeeAccessId }
    // NOTE: bundle storedFields declared employeeAccessId defaultValue "" but scaffold omitted it →
    // init(userId:) left it uninitialized. Restored default to match bundle (read-side scaffold fix, out of /domain-fill scope).
    package var employeeAccessId: String = ""
    package var userId: String?
    package var permissions: Array<String>?

    package init(userId: String) {
        self.userId = userId
    }
}
