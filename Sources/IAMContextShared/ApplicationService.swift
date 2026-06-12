/// Application service protocol bridging API transport and domain. Write-model and read-model adapters both conform.
package protocol ApplicationService {
    associatedtype Input
    associatedtype Output

    func execute(input: Input) async throws -> Output
}
