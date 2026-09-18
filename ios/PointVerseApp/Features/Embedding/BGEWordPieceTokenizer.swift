import Foundation

struct BGEWordPieceTokenizer: Sendable {
    private let vocabulary: [String: Int32]
    private let unknownID: Int32
    let clsID: Int32
    let separatorID: Int32
    let paddingID: Int32

    init(vocabularyURL: URL) throws {
        let contents = try String(contentsOf: vocabularyURL, encoding: .utf8)
        vocabulary = Dictionary(uniqueKeysWithValues: contents.split(whereSeparator: \.isNewline)
            .enumerated().map { (String($0.element), Int32($0.offset)) })
        guard let unknownID = vocabulary["[UNK]"], let clsID = vocabulary["[CLS]"],
              let separatorID = vocabulary["[SEP]"], let paddingID = vocabulary["[PAD]"] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.unknownID = unknownID
        self.clsID = clsID
        self.separatorID = separatorID
        self.paddingID = paddingID
    }

    func encode(_ text: String, maxLength: Int) -> (ids: [Int32], mask: [Int32]) {
        var tokens = basicTokens(text).flatMap(wordPieces)
        tokens = Array(tokens.prefix(max(0, maxLength - 2)))
        var ids = [clsID] + tokens + [separatorID]
        var mask = Array(repeating: Int32(1), count: ids.count)
        if ids.count < maxLength {
            ids.append(contentsOf: repeatElement(paddingID, count: maxLength - ids.count))
            mask.append(contentsOf: repeatElement(0, count: maxLength - mask.count))
        }
        return (ids, mask)
    }

    private func basicTokens(_ text: String) -> [String] {
        var result: [String] = []
        var buffer = ""
        func flush() { if !buffer.isEmpty { result.append(buffer.lowercased()); buffer = "" } }
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { flush(); continue }
            let isCJK = (0x4E00...0x9FFF).contains(scalar.value)
            if isCJK || CharacterSet.punctuationCharacters.contains(scalar) {
                flush(); result.append(String(scalar)); continue
            }
            buffer.unicodeScalars.append(scalar)
        }
        flush()
        return result
    }

    private func wordPieces(_ token: String) -> [Int32] {
        if let id = vocabulary[token] { return [id] }
        let characters = Array(token)
        var result: [Int32] = [], start = 0
        while start < characters.count {
            var end = characters.count
            var match: Int32?
            while start < end {
                let raw = String(characters[start..<end])
                let candidate = start == 0 ? raw : "##" + raw
                if let id = vocabulary[candidate] { match = id; break }
                end -= 1
            }
            guard let match else { return [unknownID] }
            result.append(match); start = end
        }
        return result
    }
}
