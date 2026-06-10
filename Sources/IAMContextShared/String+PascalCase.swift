import Foundation


extension String {

    package var pascalCase: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
