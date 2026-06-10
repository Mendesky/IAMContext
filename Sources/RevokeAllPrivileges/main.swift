//
//  RevokeAllPrivileges — one-shot correction that strips the placeholder permissions
//  granted by the initial EnrollStaffs import.
//
//  For each staff it invokes the RevokePrivilege use-case (the same application service
//  the HTTP `revokePrivilege` endpoint wraps), revoking `EmployeeAccess.allPermissions` —
//  i.e. exactly the set createUserAccessProfile handed out. Each call emits a
//  `PrivilegeRevoked` event, leaving the profile with an empty permission set. The grant
//  → revoke history is preserved on the stream (auditable), unlike a reset + reimport.
//
//  Required environment variables:
//    STAFF_DATA  — path to the staff JSON file (array of Staff objects)
//  Optional:
//    ESDB_URL    — KurrentDB connection string
//                  (default mirrors IAMContextServer: kurrent://admin:changeit@localhost:2113?tls=false)
//
//  Audit operator is each staff's own userId, matching EnrollStaffs.
//
//  NOT idempotent: RevokePrivilege rejects revoking a permission the user no longer holds
//  (permissionNotExist), so a second run will fail per-staff once permissions are empty.
//

import DDDKit
import EmployeeAccessAggregate
import Foundation
import IAMContextShared
import KurrentDB

/// Mirror of one entry in all_staffs.json. Only `id` and `userId` are used here.
struct Staff: Decodable {
    let id: String
    let name: String
    let firm: String
    let department: String
    let jobTitle: String
    let mail: String
    let isCpa: Bool
    let no: String
    let userId: String
}

func stderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let env = ProcessInfo.processInfo.environment

let esdbURL = env["ESDB_URL"] ?? "kurrent://admin:changeit@localhost:2113?tls=false"
let settings: ClientSettings = try esdbURL.parse()
let kdbClient = KurrentDBClient(settings: settings)

guard let staffDataPath = env["STAFF_DATA"], !staffDataPath.isEmpty else {
    stderr("error: STAFF_DATA env var (path to staff JSON) is required")
    exit(1)
}

let rawJSON = try Data(contentsOf: URL(fileURLWithPath: staffDataPath))
let staffs = try JSONDecoder().decode([Staff].self, from: rawJSON)

let repository = EmployeeAccessRepository(
    coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper())
)
let service = RevokePrivilegeApplicationService(repository: repository)

// Revoke exactly what createUserAccessProfile granted (the full placeholder set).
let permissionsToRevoke = Array(EmployeeAccess.allPermissions)

print("revoking \(permissionsToRevoke.count) permission(s) from \(staffs.count) staff(s) → \(esdbURL)")

var succeeded = 0
var failed = 0
for staff in staffs {
    do {
        let output = try await service.execute(input: .init(
            employeeAccessId: staff.id,
            userId: staff.userId,
            permissions: permissionsToRevoke,
            operatorId: staff.userId
        ))
        succeeded += 1
        print("✅ \(staff.no) \(staff.name) → \(output.employeeAccessId) permissions cleared")
    } catch {
        failed += 1
        stderr("❌ \(staff.no) \(staff.name): \(error)")
    }
}

print("done — \(succeeded) succeeded, \(failed) failed, \(staffs.count) total")
if failed > 0 { exit(2) }
