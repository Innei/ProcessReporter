import Foundation

private enum HarnessFailure: Error, CustomStringConvertible {
    case unexpectedValue(caseName: String, actual: String?)

    var description: String {
        switch self {
        case .unexpectedValue(let caseName, let actual):
            let renderedValue = actual.map { "'\($0)'" } ?? "nil"
            return "\(caseName) produced \(renderedValue)"
        }
    }
}

@main
private struct DiscordTransportContractHarness {
    static func main() throws {
        try expectText("遥", equals: nil, caseName: "single CJK activity character")
        try expectText("X", equals: nil, caseName: "single ASCII activity character")
        try expectText("🎵", equals: nil, caseName: "single emoji activity character")
        try expectText("遥远", equals: "遥远", caseName: "two CJK activity characters")
        try expectText("🎵🎵", equals: "🎵🎵", caseName: "two emoji activity characters")

        let oversizedText = String(repeating: "遥", count: 43)
        let boundedText = DiscordTransportContract.text(oversizedText)
        guard boundedText?.count == 42, boundedText?.utf8.count == 126 else {
            throw HarnessFailure.unexpectedValue(
                caseName: "UTF-8-safe activity truncation",
                actual: boundedText
            )
        }

        let singleCharacterAsset = DiscordTransportContract.assetIdentifier("x")
        guard singleCharacterAsset == "x" else {
            throw HarnessFailure.unexpectedValue(
                caseName: "single-character asset identifier",
                actual: singleCharacterAsset
            )
        }

        print("Discord transport contract behavior passed")
    }

    private static func expectText(
        _ input: String?,
        equals expected: String?,
        caseName: String
    ) throws {
        let actual = DiscordTransportContract.text(input)
        guard actual == expected else {
            throw HarnessFailure.unexpectedValue(caseName: caseName, actual: actual)
        }
    }
}
