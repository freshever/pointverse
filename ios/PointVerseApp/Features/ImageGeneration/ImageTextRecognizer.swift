import Foundation
import PointVerseKit
import UIKit
import Vision

actor ImageTextRecognizer {
    func recognize(data: Data, language: String) throws -> String {
        guard let cgImage = UIImage(data: data)?.cgImage else {
            throw PointVerseError.invalidModelOutput
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = recognitionLanguages(for: language)
        try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request])

        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recognitionLanguages(for language: String) -> [String] {
        switch language {
        case "zh-Hant": ["zh-Hant", "en-US"]
        case "en": ["en-US", "zh-Hans"]
        case "ja": ["ja-JP", "en-US"]
        default: ["zh-Hans", "en-US"]
        }
    }
}
