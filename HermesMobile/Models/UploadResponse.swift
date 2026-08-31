import Foundation
import ImageIO

struct UploadResponse: Codable {
    let filename: String?
    let path: String?
    let size: Int?
    let mime: String?
    let isImage: Bool?
    let error: String?
}

struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let path: String
    let mime: String
    let size: Int?
    let isImage: Bool
    let thumbnailData: Data?
}

enum ImagePreviewDownsampler {
    static let attachmentMaxPixelSize = 512
    static let filePreviewMaxPixelSize = 2_048

    static func previewData(from data: Data, maxPixelSize: Int) -> Data? {
        guard maxPixelSize > 0 else { return data }

        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }

        if let size = pixelSize(for: source),
           max(size.width, size.height) <= maxPixelSize {
            return data
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.82
        ]
        CGImageDestinationAddImage(destination, thumbnail, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return output as Data
    }

    static func previewDataAsync(from data: Data, maxPixelSize: Int) async -> Data? {
        guard !Task.isCancelled else { return nil }

        return await withTaskGroup(of: Data?.self) { group in
            group.addTask(priority: .userInitiated) {
                guard !Task.isCancelled else { return nil }
                return previewData(from: data, maxPixelSize: maxPixelSize)
            }

            guard let generatedPreviewData = await group.next() else {
                return nil
            }
            group.cancelAll()
            guard !Task.isCancelled else { return nil }
            return generatedPreviewData
        }
    }

    private static func pixelSize(for source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = intValue(properties[kCGImagePropertyPixelWidth]),
              let height = intValue(properties[kCGImagePropertyPixelHeight])
        else {
            return nil
        }

        return (width, height)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }

        return value as? Int
    }
}

extension PendingAttachment {
    static let maximumUploadBytes = 20 * 1_024 * 1_024
    static let maximumUploadSizeDescription = "20 MB"

    static func uploadTooLargeMessage(filename: String) -> String {
        "\(filename) is too large. Attachments must be \(maximumUploadSizeDescription) or smaller."
    }

    var chatReference: String {
        if isImage {
            return path.isEmpty ? name : path
        }

        return path.isEmpty ? name : path
    }

    func toJSONValue() -> JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name),
            "path": .string(path),
            "mime": .string(mime)
        ]
        if let size {
            object["size"] = .number(Double(size))
        }
        object["is_image"] = .bool(isImage)
        return .object(object)
    }

    static func chatMessageText(draft: String, attachments: [PendingAttachment]) -> String {
        let references = attachments
            .map(\.chatReference)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !references.isEmpty else {
            return draft
        }

        return "\(draft)\n\n[Attached files: \(references.joined(separator: ", "))]"
    }
}

/// Generates collision-resistant `.m4a` names for recorded voice notes. The
/// 8-char suffix mirrors the attachment coordinator's uniquing so two quick notes
/// don't clash on upload, and the `.m4a` extension makes the inline player treat
/// the clip as audio even when the server reports a generic MIME type.
///
/// Lives in `Models/` rather than next to `ComposerVoiceNoteRecorder.swift` in
/// `Features/Chat/` because it is a shared attachment-naming *contract*, not
/// composer-specific UI logic: both `HermesMobile` and `HermesWatch` compile
/// `Models/*.swift` (see `HermesWatch/README.md` "Shared file manifest"), but
/// `Features/` is iOS-only. The watch's voice-note recorder must produce the
/// exact same `voice-note-<8hex>.m4a` filename shape as the iOS composer,
/// because that shape — not the MIME type — is what the inline audio player
/// keys off of to render a clip as a playable voice note instead of a generic
/// file attachment.
enum VoiceNoteFilename {
    static func generate(uuid: UUID = UUID()) -> String {
        let suffix = uuid.uuidString.prefix(8).lowercased()
        return "voice-note-\(suffix).m4a"
    }

    static func isVoiceNote(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.hasPrefix("voice-note-") && lower.hasSuffix(".m4a")
    }
}
