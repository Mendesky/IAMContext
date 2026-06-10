//
//  EnrollStaffs — one-shot staff data importer.
//
//  Reads a staff JSON file (array of `Staff`) and enrolls each person into IAM by
//  invoking the CreateUserAccessProfile use-case, which emits a `UserAccessProfileCreated`
//  domain event per staff into KurrentDB.
//
//  This lives INSIDE the IAMContext package on purpose: the application service and
//  repository it drives are `package`-level, so they are unreachable from another
//  Swift package. Same-package membership is what makes the direct call legal.
//
//  Required environment variables:
//    STAFF_DATA  — path to the staff JSON file (array of Staff objects)
//  Optional:
//    ESDB_URL    — KurrentDB connection string
//                  (default mirrors IAMContextServer: kurrent://admin:changeit@localhost:2113?tls=false)
//
//  The audit operator is each staff's own userId: for this initial backfill the "first
//  operator" of a profile is treated as the person themselves (per product decision).
//
//  NOTE: each enrolled staff is created with status .Active and *all* permissions —
//  this is IAMContext's current placeholder for new-hire access (see EmployeeAccess
//  convenience init). Re-running against an already-enrolled id will fail on append.
//

import DDDKit
import EmployeeAccessAggregate
import Foundation
import IAMContextShared
import KurrentDB

/// Mirror of one entry in all_staffs.json. Only `id`, `userId`, `department`, and
/// `jobTitle` are consumed by enrollment; the rest are decoded for logging/clarity.
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

// KurrentDB connection — same convention & default as IAMContextServer.
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
let service = CreateUserAccessProfileApplicationService(repository: repository)

print("enrolling \(staffs.count) staff(s) from \(staffDataPath) → \(esdbURL)")

var succeeded = 0
var failed = 0
for staff in staffs {
    do {
        let output = try await service.execute(input: .init(
            employeeAccessId: staff.id,
            userId: staff.userId,
            department: staff.department,
            jobTitle: staff.jobTitle,
            operatorId: staff.userId  // first operator of a profile == the person themselves
        ))
        succeeded += 1
        print("✅ \(staff.no) \(staff.name) → employeeAccessId=\(output.employeeAccessId)")
    } catch {
        failed += 1
        stderr("❌ \(staff.no) \(staff.name): \(error)")
    }
}

print("done — \(succeeded) succeeded, \(failed) failed, \(staffs.count) total")
if failed > 0 { exit(2) }
