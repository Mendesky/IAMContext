import Foundation
import KurrentDB

// 整合測試用 KurrentDB client 工廠。
//
// 預設行為與現行寫死的 `.localhost()` 完全相同（連本機 2113）；但可用環境變數
// `ESDB_TEST_URL` 覆寫連線字串——CI self-hosted runner 上 127.0.0.1:2113 常被同機
// 其他程序佔用，測試端注入不同 host/port 即可避開衝突，不必再靠 workflow 層的
// concurrency 序列化整套測試。字串解析沿用 `IAMContextServer.swift` 的慣例：
// 用 `KurrentDB` 提供的 `String.parse() throws -> ClientSettings`。
//
// 保持非 throws：呼叫端有的是 stored property 預設值（無法 try），有的在
// `async throws` 測試函式裡——統一成非 throws 工廠，兩種呼叫端都能直接用同一行。
// `ESDB_TEST_URL` 若設了但解析失敗，視為測試環境設定錯誤，直接 fatalError 讓 CI
// 明顯失敗，而不是悄悄退回本機 2113 掩蓋問題。
func makeTestKurrentDBClient() -> KurrentDBClient {
    guard let urlString = ProcessInfo.processInfo.environment["ESDB_TEST_URL"] else {
        return KurrentDBClient(settings: .localhost())
    }
    do {
        let settings: ClientSettings = try urlString.parse()
        return KurrentDBClient(settings: settings)
    } catch {
        fatalError("ESDB_TEST_URL 設定但無法解析為 ClientSettings: \"\(urlString)\" — \(error)")
    }
}
