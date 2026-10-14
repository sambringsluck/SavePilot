import AppKit
import AVFoundation
import Foundation
import ImageIO
import NaturalLanguage
import PDFKit
import QuickLookThumbnailing
@preconcurrency import Vision

struct ImageIntelligenceResult {
    let text: String
    let labels: [String]
    let barcodes: [String]
    let faceCount: Int
    let metadata: [String: String]
}

enum AdvancedExtractors {
    static func analyzeImage(at url: URL) async -> ImageIntelligenceResult? {
        await Task.detached(priority: .userInitiated) {
            guard let image = NSImage(contentsOf: url),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return nil }
            return analyze(cgImage: cgImage, sourceURL: url)
        }.value
    }

    static func analyzeQuickLookPreview(at url: URL) async -> ImageIntelligenceResult? {
        await withCheckedContinuation { continuation in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 1600, height: 1600),
                scale: 2,
                representationTypes: [.thumbnail, .lowQualityThumbnail]
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                guard let representation else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: analyze(cgImage: representation.cgImage, sourceURL: url))
            }
        }
    }

    static func extractPDF(at url: URL) async -> (text: String, signals: [String])? {
        guard let document = PDFDocument(url: url) else { return nil }
        var parts: [String] = []
        var scannedPages = 0
        let limit = min(document.pageCount, 15)

        for index in 0..<limit {
            guard let page = document.page(at: index) else { continue }
            if let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                parts.append(text)
            } else if scannedPages < 5 {
                let thumbnail = page.thumbnail(of: NSSize(width: 1600, height: 2200), for: .mediaBox)
                if let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil),
                   let result = await Task.detached(priority: .userInitiated, operation: {
                       analyze(cgImage: cgImage, sourceURL: nil)
                   }).value,
                   !result.text.isEmpty {
                    parts.append(result.text)
                    scannedPages += 1
                }
            }
        }
        guard !parts.isEmpty else { return nil }
        var signals = ["PDF", "\(document.pageCount)页"]
        if scannedPages > 0 { signals.append("扫描件OCR:\(scannedPages)页") }
        return (parts.joined(separator: "\n"), signals)
    }

    static func extractOfficeText(at url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        let patterns: [String]
        switch ext {
        case "docx": patterns = ["word/document.xml", "word/header*.xml", "word/footer*.xml"]
        case "pptx": patterns = ["ppt/slides/slide*.xml", "ppt/notesSlides/notesSlide*.xml"]
        case "xlsx": patterns = ["xl/sharedStrings.xml", "xl/worksheets/sheet*.xml"]
        case "pages": patterns = ["index.xml"]
        default: return nil
        }

        var combined = ""
        for pattern in patterns {
            if let xml = run("/usr/bin/unzip", arguments: ["-p", url.path, pattern]), !xml.isEmpty {
                combined += " " + xml
            }
        }
        guard !combined.isEmpty else { return nil }
        return cleanXML(combined)
    }

    static func archiveListing(at url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        let output: String?
        switch ext {
        case "zip": output = run("/usr/bin/unzip", arguments: ["-Z1", url.path])
        case "tar", "gz", "tgz": output = run("/usr/bin/tar", arguments: ["-tf", url.path])
        default: output = nil
        }
        guard let output, !output.isEmpty else { return nil }
        return String(output.prefix(20_000))
    }

    static func mediaMetadata(at url: URL) async -> (text: String, metadata: [String: String])? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let commonMetadata = try await asset.load(.commonMetadata)
            var metadata: [String: String] = [:]
            if duration.isNumeric {
                metadata["时长"] = String(format: "%.1f秒", CMTimeGetSeconds(duration))
            }
            for item in commonMetadata.prefix(30) {
                guard let key = item.commonKey?.rawValue,
                      let value = try? await item.load(.stringValue),
                      !value.isEmpty
                else { continue }
                metadata[key] = value
            }
            let text = metadata.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            return (text, metadata)
        } catch {
            return nil
        }
    }

    static func linguisticInsights(for text: String) -> (language: String?, entities: [String]) {
        guard !text.isEmpty else { return (nil, []) }
        let sample = String(text.prefix(8_000))
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let language = recognizer.dominantLanguage?.rawValue

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = sample
        var entities: [String] = []
        let range = sample.startIndex..<sample.endIndex
        tagger.enumerateTags(
            in: range,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, tokenRange in
            if tag == .personalName || tag == .organizationName || tag == .placeName {
                let entity = String(sample[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !entity.isEmpty, !entities.contains(entity), entities.count < 20 {
                    entities.append(entity)
                }
            }
            return true
        }
        return (language, entities)
    }

    private static func analyze(cgImage: CGImage, sourceURL: URL?) -> ImageIntelligenceResult? {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.automaticallyDetectsLanguage = true
        textRequest.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

        let classifyRequest = VNClassifyImageRequest()
        let barcodeRequest = VNDetectBarcodesRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)
        do {
            try handler.perform([textRequest, classifyRequest, barcodeRequest, faceRequest])
        } catch {
            return nil
        }

        let text = textRequest.results?
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n") ?? ""
        let labels = classifyRequest.results?
            .filter { $0.confidence >= 0.12 }
            .prefix(8)
            .map { "\($0.identifier) \(Int($0.confidence * 100))%" } ?? []
        let barcodeValues: [String] = barcodeRequest.results?.compactMap(\.payloadStringValue) ?? []
        let barcodes = Array(barcodeValues.prefix(10))
        var metadata: [String: String] = [
            "像素": "\(cgImage.width)×\(cgImage.height)"
        ]
        if let sourceURL,
           let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let orientation = properties[kCGImagePropertyOrientation] {
                metadata["方向"] = "\(orientation)"
            }
            if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
               let model = tiff[kCGImagePropertyTIFFModel] {
                metadata["设备"] = "\(model)"
            }
        }
        return ImageIntelligenceResult(
            text: text,
            labels: labels,
            barcodes: barcodes,
            faceCount: faceRequest.results?.count ?? 0,
            metadata: metadata
        )
    }

    private static func run(_ executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func cleanXML(_ xml: String) -> String {
        xml.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
