import Foundation
import UIKit

/// One image attached to a chat for vision input (photo or screenshot).
/// The data is always JPEG (see VisionImagePrep) so every provider gets
/// the same `image/jpeg` shape, whichever vision format it uses.
struct ChatImageAttachment: Identifiable, Hashable {
    var id: UUID = UUID()
    var fileName: String
    var jpegData: Data

    var charEstimate: Int { jpegData.count / 4 }
}

/// Prepares raw image data (PNG/JPEG from the photo picker) for vision
/// input: decodes it, downsizes so the longest side is at most
/// `maxDimension` points, and re-encodes as JPEG. Returns nil when the
/// data is not a readable image. Downscaling keeps requests small and
/// fast — a full-resolution iPhone photo would otherwise be several MB
/// of base64 in every chat request.
enum VisionImagePrep {
    static let maxImagesPerChat = 4
    static let maxDimension: CGFloat = 1024
    static let jpegQuality: CGFloat = 0.8

    static func prepare(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let targetSize = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: jpegQuality)
    }
}
