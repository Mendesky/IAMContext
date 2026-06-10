import Foundation


extension String {

    package var isBlank: Bool {
        return trimmingCharacters(in: CharacterSet.whitespacesNewlinesAndFullWidthSpace).isEmpty
    }
}


extension CharacterSet {
    package static let whitespacesNewlinesAndFullWidthSpace: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "\u{3000}") // full-width space (CJK)
        return set
    }()
}
