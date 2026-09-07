import Foundation
import KurrentDB
import DDDKit
import EmployeeAccessAggregate
import IAMContextShared

// 一次性遷移腳本：把既有 EmployeeAccess 的 firm 從名稱轉為統編。
//
// 依據 spec `docs/tasks/2026-09-03-firm-format-and-scope-check.md` Step 1-2：
//   - 對每個 firm 非統編的 EmployeeAccess，發 transferDepartment 指令把 firm 改為統編。
//   - 不重跑員工匯入（會覆蓋管理員手動調整過的權限與部門）。
//   - 冪等：已是統編者跳過。
//   - 無法對應的 firm 值：中止該筆、不猜測，列入摘要供人工處理。
//
// ⚠️ 本腳本只提供程式碼，不會被任何 CI/build 流程自動執行。實際跑（本機／55／正式）由人決定時機：
//     swift run MigrateFirmFormat                 // 對 localhost:2113 的 KurrentDB 執行
//     KDB_HOST=<host> KDB_PORT=<port> swift run MigrateFirmFormat   // 對指定環境執行（尚未支援，見下方 TODO）
//
// 目前只支援連線到 localhost 的 KurrentDB（.localhost() settings，同 IAMContextServer 本機開發設定）。
// 若要對 55 / 正式環境執行，需先確認連線設定與帳密（TODO，交由執行者在跑之前補上，並先在本機/55 驗證過）。

// MARK: - 所別名稱 → 統編對照表（spec §1；含已知變體）

/// key：IAM 現有的 firm 名稱值；value：對應的統編。
/// 只收錄 spec 列出的六個所別 + 已知變體（55 環境實測：台北市所／台北所 皆為台北所）。
/// 遇到不在此表、且不是任何統編值本身的 firm 值 → 視為「無法對應」，中止該筆、列入摘要，絕不猜測。
let firmNameToTaxId: [String: String] = [
    "總所": "01020314",
    "台北所": "88183980",
    "台北市所": "88183980", // 已知變體（55 環境實測）
    "桃園所": "41171816",
    "台中所": "47575385",
    "彰化所": "82576039",
    "嘉義所": "47779732",
]

/// 統編值本身的集合：已經是統編的 EmployeeAccess 視為「已遷移」，冪等跳過。
let knownTaxIds: Set<String> = Set(firmNameToTaxId.values)

// MARK: - 摘要

struct MigrationSummary {
    var processed: Int = 0   // 實際發出 transferDepartment、改成統編
    var skipped: Int = 0     // 已是統編，或 firm 為 nil/空字串（無需遷移）
    var unmappable: [(employeeAccessId: String, firmValue: String)] = []  // 無法對應，中止該筆

    func printReport() {
        print("=== 所別格式遷移摘要 ===")
        print("處理 \(processed) 筆、跳過 \(skipped) 筆、無法對應 \(unmappable.count) 筆")
        if !unmappable.isEmpty {
            print("--- 無法對應清單（需人工確認）---")
            for entry in unmappable {
                print("  employeeAccessId=\(entry.employeeAccessId) firm=\"\(entry.firmValue)\"")
            }
        }
    }
}

// MARK: - Step 1：枚舉所有 EmployeeAccess 的 employeeAccessId

/// 讀 `$ce-IAMEmployeeAccess` 分類串流（category projection），解出每個事件的「原始」stream 名稱
/// （形如 `IAMEmployeeAccess-<id>`），去重取得所有曾經存在過的 employeeAccessId。
/// 之後用 repository.find(byId:) 取得每個聚合的「目前」狀態（含 soft-delete 與最新 firm 值）。
func enumerateEmployeeAccessIds(kdbClient: KurrentDBClient) async throws -> [String] {
    let categoryStreamName = "$ce-\(EmployeeAccess.category)"  // "$ce-IAMEmployeeAccess"
    let streamPrefix = "\(EmployeeAccess.category)-"           // "IAMEmployeeAccess-"

    let responses = try await kdbClient.streams(specified: categoryStreamName).read { options in
        options.resolveLinks = true
        options.direction = .forward
        options.revision = .start
        options.limit = .max
    }

    var seen = Set<String>()
    var orderedIds: [String] = []
    for try await response in responses {
        guard case let .event(readEvent) = response else { continue }
        let originalStreamName = readEvent.record.streamIdentifier.name
        guard originalStreamName.hasPrefix(streamPrefix) else { continue }
        let employeeAccessId = String(originalStreamName.dropFirst(streamPrefix.count))
        guard !seen.contains(employeeAccessId) else { continue }
        seen.insert(employeeAccessId)
        orderedIds.append(employeeAccessId)
    }
    return orderedIds
}

// MARK: - Step 2：逐筆遷移

func migrateFirmFormat() async throws {
    let kdbClient = KurrentDBClient(settings: .localhost())
    let repository = EmployeeAccessRepository(
        coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper())
    )

    print("枚舉所有 EmployeeAccess ...")
    let employeeAccessIds = try await enumerateEmployeeAccessIds(kdbClient: kdbClient)
    print("共找到 \(employeeAccessIds.count) 個 employeeAccessId。開始逐筆檢查 firm 欄位 ...")

    var summary = MigrationSummary()

    for employeeAccessId in employeeAccessIds {
        guard let aggregate = try await repository.find(byId: employeeAccessId) else {
            // soft-deleted 或聚合已不存在：不在本次遷移範圍內，跳過。
            summary.skipped += 1
            continue
        }

        guard let currentFirm = aggregate.firm, !currentFirm.isEmpty else {
            // firm 為 nil 或空字串：理論上 firmRequired guard 應已擋掉新建檔案，
            // 但既有舊資料仍可能存在（例如 firmRequired guard 上線前建立的 profile）。
            // 不猜測、不補值，只記為跳過，交由人工另行處理。
            summary.skipped += 1
            continue
        }

        if knownTaxIds.contains(currentFirm) {
            // 已經是統編 → 冪等跳過。
            summary.skipped += 1
            continue
        }

        guard let userId = aggregate.userId, let department = aggregate.department, let jobTitle = aggregate.jobTitle else {
            // 理論上不應發生（這些欄位在 create 時皆必填），防禦性中止並列入無法對應清單。
            summary.unmappable.append((employeeAccessId: employeeAccessId, firmValue: currentFirm))
            continue
        }

        guard let taxId = firmNameToTaxId[currentFirm] else {
            // 不在對照表、也不是已知統編 → 無法對應，中止該筆，絕不猜測。
            summary.unmappable.append((employeeAccessId: employeeAccessId, firmValue: currentFirm))
            continue
        }

        do {
            // 事件溯源正規做法：發 transferDepartment，只改 firm（department/jobTitle 帶回原值，
            // 讓 EmployeeAccess+TransferDepartment.swift 的 firm-only 異動 guard 判定為「有變化」而放行）。
            // operatorId 使用固定字串標記此次操作來源，供事件稽核追蹤。
            _ = try await TransferDepartmentService(repository: repository).execute(input: .init(
                employeeAccessId: employeeAccessId,
                userId: userId,
                newDepartment: department,
                newJobTitle: jobTitle,
                operatorId: "system:migrate-firm-format-2026-09-03",
                newFirm: taxId
            ))
            summary.processed += 1
            print("已遷移 employeeAccessId=\(employeeAccessId): firm \"\(currentFirm)\" → \(taxId)")
        } catch {
            // 遷移中途失敗：已處理的筆數已落事件（不可逆但無害，只是 firm 改成統編）。
            // 本筆失敗列入無法對應清單，腳本冪等，可直接重跑。
            print("⚠️ employeeAccessId=\(employeeAccessId) 遷移失敗：\(error)")
            summary.unmappable.append((employeeAccessId: employeeAccessId, firmValue: currentFirm))
        }
    }

    summary.printReport()
}

try await migrateFirmFormat()
