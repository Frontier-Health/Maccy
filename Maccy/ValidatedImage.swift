import AppKit
import ImageIO
import UniformTypeIdentifiers

// The only place Maccy decodes a copied image (tools/check-rich-text-importers.py
// rejects every other image decoder in app code).
//
// Copied image data comes from any app or web page. A container such as TIFF,
// GIF, APNG, HEIC or ICO can hold several images, and AppKit's
// `NSImage(data:)` exposes all of them, so checking only the first one bounds
// nothing. Here:
// - `inspect` reads the header of every image in the source with ImageIO,
//   without decoding any of them, and accepts the source only if it has at
//   most `maximumImageCount` images, each at most `maximumImagePixels`
//   pixels, together at most `maximumTotalPixels`.
// - At capture, a container with more than one image is made unambiguous
//   (`canonicalForm`): the largest image (the first of equal ones: the
//   full-size page of a multi-resolution TIFF, the first frame of an APNG or
//   HEIC sequence) is re-encoded alone, by ImageIO, as a file of the same
//   type, and only that is stored. A single-image file is stored byte for
//   byte. Every later consumer (preview, thumbnail, text recognition, Get,
//   copy-back) then sees the same picture another app sees. GIF, the common
//   animated format, is not a storable type.
// - Decoding produces one image, from index 0, the image other apps show
//   (`NSBitmapImageRep(data:)` and most consumers take the first), scaled so
//   its longest side is at most what the consumer needs (`Purpose`). For a
//   new copy that is the only image. An item stored before canonicalisation
//   may still hold several; the preview says so (`Inspection.imageCount`).
//   The original container is never handed to another decoder.
// Decoding is synchronous; callers on the main actor use the `async`
// variants, which decode on `queue`.
nonisolated enum ValidatedImage {
  // What the decoded image is for, which bounds its size.
  enum Purpose: Sendable {
    // A row in the history list.
    case thumbnail
    // The preview panel: at most a large screen.
    case preview
    // Text recognition and export: full size, within the pixel limit.
    case fullSize

    var maximumLongestSide: Int? {
      switch self {
      case .thumbnail: 1_024
      case .preview: 4_096
      case .fullSize: nil
      }
    }
  }

  // What `inspect` found: the image that will be decoded and its size.
  struct Inspection: Equatable, Sendable {
    let imageCount: Int
    // The image decoded: always the first.
    let index: Int
    // The largest image, the first of equal ones: what canonicalisation keeps.
    let largestIndex: Int
    let width: Int
    let height: Int
    let totalPixels: Int
    // The chosen image's size in points, from its resolution (72 dpi if none).
    let pointWidth: Double
    let pointHeight: Double
  }

  // Why a source is refused. Holds no content.
  enum Rejection: Error, Equatable, Sendable {
    case unreadable
    case tooManyImages(Int)
    case imageTooLarge(index: Int, pixels: Int)
    case totalTooLarge(pixels: Int)
  }

  // 256 frames is an animated GIF or APNG of about ten seconds at 25 fps.
  static let defaultMaximumImageCount = 256

  #if DEBUG
  nonisolated(unsafe) static var maximumImageCountForTesting: Int?
  // Counts every successful decode, so tests can check a path decodes nothing.
  nonisolated(unsafe) static var decodesForTesting = 0
  nonisolated(unsafe) static var canonicalizationsForTesting = 0
  #endif

  static var maximumImageCount: Int {
    #if DEBUG
    if let maximumImageCountForTesting { return maximumImageCountForTesting }
    #endif
    return defaultMaximumImageCount
  }

  // Per image: `ContentLimits.maximumImagePixels`.
  static var maximumImagePixels: Int { ContentLimits.maximumImagePixels }

  // Across every image in one source: twice the per-image limit.
  static var maximumTotalPixels: Int { ContentLimits.maximumImagePixels * 2 }

  private static let queue = DispatchQueue(label: AppIdentity.bundleIdentifier + ".imageDecoding",
                                           qos: .userInitiated, attributes: .concurrent)

  private static var noCache: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }

  // Checks every image in `data` without decoding any.
  static func inspect(_ data: Data) -> Result<Inspection, Rejection> {
    guard let source = CGImageSourceCreateWithData(data as CFData, noCache) else {
      return .failure(.unreadable)
    }
    return inspect(source)
  }

  private static func inspect(_ source: CGImageSource) -> Result<Inspection, Rejection> {
    let count = CGImageSourceGetCount(source)
    guard count > 0 else {
      return .failure(.unreadable)
    }
    guard count <= maximumImageCount else {
      return .failure(.tooManyImages(count))
    }

    var total = 0
    var first: (width: Int, height: Int, pointWidth: Double, pointHeight: Double)?
    var largest: (index: Int, pixels: Int)?
    for index in 0..<count {
      guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, noCache) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0, height > 0 else {
        return .failure(.unreadable)
      }
      let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
      guard !overflow, pixels <= maximumImagePixels else {
        return .failure(.imageTooLarge(index: index, pixels: overflow ? Int.max : pixels))
      }
      total += pixels
      guard total <= maximumTotalPixels else {
        return .failure(.totalTooLarge(pixels: total))
      }
      if first == nil {
        let dpiWidth = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let dpiHeight = (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? 72
        first = (width, height,
                 Double(width) * 72 / (dpiWidth > 0 ? dpiWidth : 72),
                 Double(height) * 72 / (dpiHeight > 0 ? dpiHeight : 72))
      }
      if largest.map({ $0.pixels < pixels }) ?? true {
        largest = (index, pixels)
      }
    }

    guard let first, let largest else {
      return .failure(.unreadable)
    }
    return .success(Inspection(imageCount: count, index: 0, largestIndex: largest.index,
                               width: first.width, height: first.height, totalPixels: total,
                               pointWidth: first.pointWidth, pointHeight: first.pointHeight))
  }

  // What capture stores for one image representation (see `canonicalForm`).
  enum Canonical: Equatable, Sendable {
    // One image (or not an image ImageIO reads): stored byte for byte.
    case unchanged
    // Several images: only this single-image file of the same type.
    case replaced(Data)
    // Several images that couldn't be re-encoded within the limits: the
    // representation is not stored.
    case refused
  }

  // Whether `data` holds more than one image, from its header alone.
  static func hasSeveralImages(_ data: Data) -> Bool {
    guard let source = CGImageSourceCreateWithData(data as CFData, noCache) else {
      return false
    }
    return CGImageSourceGetCount(source) > 1
  }

  // The unambiguous form of `data` for storage: a single image is kept as
  // is; of several, the largest is re-encoded alone as a file of the same
  // type, within the pixel and byte limits. Synchronous; capture calls
  // `canonicalize`, which runs it on `queue`.
  static func canonicalForm(_ data: Data) -> Canonical {
    guard let source = CGImageSourceCreateWithData(data as CFData, noCache),
          CGImageSourceGetCount(source) > 1 else {
      return .unchanged
    }
    guard case .success(let inspection) = inspect(source),
          let type = CGImageSourceGetType(source) else {
      return .refused
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type, 1, nil) else {
      return .refused
    }
    CGImageDestinationAddImageFromSource(destination, source, inspection.largestIndex, nil)
    guard CGImageDestinationFinalize(destination) else {
      return .refused
    }
    let result = output as Data
    guard result.count <= ContentLimits.maximumRepresentationBytes,
          let check = CGImageSourceCreateWithData(result as CFData, noCache),
          CGImageSourceGetCount(check) == 1 else {
      return .refused
    }
    #if DEBUG
    canonicalizationsForTesting += 1
    #endif
    return .replaced(result)
  }

  // `canonicalForm(_:)` off the caller's thread.
  static func canonicalize(_ data: Data) async -> Canonical {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: canonicalForm(data))
      }
    }
  }

  // Whether `data` passes `inspect`.
  static func isAcceptable(_ data: Data) -> Bool {
    if case .success = inspect(data) {
      return true
    }
    return false
  }

  // The pixel size of the image that would be decoded, or nil if refused.
  static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
    guard case .success(let inspection) = inspect(data) else {
      return nil
    }
    return (inspection.width, inspection.height)
  }

  // Decodes the one validated image, scaled for `purpose`. Synchronous.
  static func cgImage(from data: Data, for purpose: Purpose) -> CGImage? {
    decodeImage(from: data, for: purpose)?.image
  }

  private static func decodeImage(from data: Data, for purpose: Purpose) -> (image: CGImage, inspection: Inspection)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, noCache),
          case .success(let inspection) = inspect(source) else {
      return nil
    }

    let longestSide = max(inspection.width, inspection.height)
    let target = min(longestSide, purpose.maximumLongestSide ?? longestSide)
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: target,
      kCGImageSourceShouldCacheImmediately: true
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, inspection.index, options as CFDictionary) else {
      return nil
    }
    #if DEBUG
    decodesForTesting += 1
    #endif
    return (image, inspection)
  }

  // The validated image re-encoded as PNG, at full size. Synchronous.
  static func pngData(from data: Data) -> Data? {
    guard let image = cgImage(from: data, for: .fullSize) else {
      return nil
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      output as CFMutableData, UTType.png.identifier as CFString, 1, nil
    ) else {
      return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      return nil
    }
    return output as Data
  }

  // `cgImage(from:for:)` off the caller's thread.
  static func decode(_ data: Data, for purpose: Purpose) async -> DecodedImage? {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: decodeImage(from: data, for: purpose).map {
          DecodedImage(cgImage: $0.image,
                       pointSize: NSSize(width: $0.inspection.pointWidth, height: $0.inspection.pointHeight))
        })
      }
    }
  }

  // `pngData(from:)` off the caller's thread.
  static func encodePNG(_ data: Data) async -> Data? {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: pngData(from: data))
      }
    }
  }
}

// A decoded image handed from the decoding queue to the main actor. A
// `CGImage` is immutable once created.
nonisolated struct DecodedImage: @unchecked Sendable {
  let cgImage: CGImage
  // The original image's size in points; the decoded bitmap may be smaller.
  let pointSize: NSSize

  @MainActor
  var nsImage: NSImage { NSImage(cgImage: cgImage, size: pointSize) }
}
