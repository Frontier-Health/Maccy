import AppKit
import Defaults
import ImageIO
import Logging
import SwiftData

// Size limits for copied content, which comes from any app or web page.
//
// - One representation (one type of one copy) may be at most
//   `maximumRepresentationBytes`, and one copy at most `maximumCopyBytes` in
//   total. A full-screen screenshot of an 8K display (7680×4320) is about
//   127 MiB as uncompressed TIFF and about 170 MiB with its PNG, so both fit.
//   A copy over either limit is not recorded at all (it stays on the system
//   clipboard): dropping only the oversized representation would store a copy
//   whose formatted and plain versions no longer match what was copied.
//   NSPasteboard has no way to learn a representation's size without
//   transferring it, so each one is checked as soon as it is read, and
//   nothing more is read once a limit is passed.
// - An image is decoded (for the list, the preview, accessibility or text
//   recognition) only if its header says it has at most `maximumImagePixels`
//   pixels, so a small file that expands to gigabytes is never decoded.
nonisolated enum ContentLimits {
  static let defaultMaximumRepresentationBytes = 128 * 1_024 * 1_024
  static let defaultMaximumCopyBytes = 192 * 1_024 * 1_024
  // 100 megapixels, about 400 MB once decoded: five full-screen screenshots
  // of a 6K display.
  static let defaultMaximumImagePixels = 100_000_000

  #if DEBUG
  nonisolated(unsafe) static var maximumRepresentationBytesForTesting: Int?
  nonisolated(unsafe) static var maximumCopyBytesForTesting: Int?
  nonisolated(unsafe) static var maximumImagePixelsForTesting: Int?
  #endif

  static var maximumRepresentationBytes: Int {
    #if DEBUG
    if let maximumRepresentationBytesForTesting { return maximumRepresentationBytesForTesting }
    #endif
    return defaultMaximumRepresentationBytes
  }

  static var maximumCopyBytes: Int {
    #if DEBUG
    if let maximumCopyBytesForTesting { return maximumCopyBytesForTesting }
    #endif
    return defaultMaximumCopyBytes
  }

  static var maximumImagePixels: Int {
    #if DEBUG
    if let maximumImagePixelsForTesting { return maximumImagePixelsForTesting }
    #endif
    return defaultMaximumImagePixels
  }

  // Why a copy was not recorded. Holds only type names and sizes, never content.
  enum Violation: Equatable, CustomStringConvertible {
    case representation(String, bytes: Int)
    case copy(bytes: Int)

    var description: String {
      switch self {
      case .representation(let type, let bytes):
        return "representation \(type) is \(bytes) bytes, limit \(ContentLimits.maximumRepresentationBytes)"
      case .copy(let bytes):
        return "copy is over \(bytes) bytes, limit \(ContentLimits.maximumCopyBytes)"
      }
    }
  }

  // Adds up a copy's representations as they are read.
  struct Tally {
    private(set) var bytes = 0

    // nil while within the limits.
    mutating func add(_ type: NSPasteboard.PasteboardType, bytes count: Int) -> Violation? {
      guard count <= ContentLimits.maximumRepresentationBytes else {
        return .representation(type.rawValue, bytes: count)
      }
      bytes += count
      guard bytes <= ContentLimits.maximumCopyBytes else {
        return .copy(bytes: bytes)
      }
      return nil
    }
  }

  // The pixel size an image's header declares, without decoding it.
  static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          CGImageSourceGetCount(source) > 0,
          let properties = CGImageSourceCopyPropertiesAtIndex(
            source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
          ) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
          width > 0, height > 0 else {
      return nil
    }
    return (width, height)
  }

  // Whether the image may be decoded: its header declares a size within
  // `maximumImagePixels`. Unreadable headers are not decoded either.
  static func imageMayBeDecoded(_ data: Data) -> Bool {
    guard let size = pixelSize(of: data) else {
      return false
    }
    return Double(size.width) * Double(size.height) <= Double(maximumImagePixels)
  }
}

// Whether Maccy recognises text in copied images to title them
// ("ocrEnabled", a Boolean, default true). A configuration profile can force
// it. A value of the wrong type (a string, a number other than 0 or 1, a
// list…) turns recognition off: it may be an administrator's "off" written
// wrongly, and recognising text is the less private choice.
//
// While it is off no image is passed to Vision: an image's title is empty
// (the list shows its thumbnail), and titles recognised earlier are not shown
// and are erased from history (`History.applyOCRSetting()`). Turning it back
// on doesn't recognise text in images already in history; new copies are
// recognised again.
nonisolated struct OCRSetting: Equatable, Sendable {
  static let preferenceKey = "ocrEnabled"

  enum State: Equatable, Sendable {
    case on
    case off
    case invalid
  }

  let state: State
  let isForced: Bool

  var isEnabled: Bool { state == .on }

  static func effective(in defaults: UserDefaults) -> OCRSetting {
    OCRSetting(state: state(of: defaults.object(forKey: preferenceKey)),
               isForced: defaults.objectIsForced(forKey: preferenceKey))
  }

  static func state(of value: Any?) -> State {
    guard let value else {
      return .on
    }
    // A property-list Boolean or an integer 0/1 (as profiles sometimes write).
    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return number.boolValue ? .on : .off
      }
      switch number.doubleValue {
      case 1: return .on
      case 0: return .off
      default: return .invalid
      }
    }
    return .invalid
  }

  #if DEBUG
  nonisolated(unsafe) static var preferencesForTesting: UserDefaults?
  #endif

  static var preferences: UserDefaults {
    #if DEBUG
    if let preferencesForTesting { return preferencesForTesting }
    #endif
    return Defaults.Keys.ocrEnabled.suite
  }

  static var current: OCRSetting { effective(in: preferences) }
}

extension History {
  // While text recognition is off, erases titles recognised in images from
  // history. Runs at launch and whenever the effective value changes.
  // Returns how many titles were erased.
  @MainActor
  @discardableResult
  func applyOCRSetting() -> Int {
    guard !OCRSetting.current.isEnabled else {
      return 0
    }

    let logger = Logger(label: AppIdentity.bundleIdentifier)
    let context = Storage.shared.context
    guard let stored = try? context.fetch(FetchDescriptor<HistoryItem>()) else {
      return 0
    }
    let erased = stored.filter { $0.eraseRecognizedTitle() }
    guard !erased.isEmpty else {
      return 0
    }
    do {
      try Storage.shared.save()
      logger.info("Text recognition is off: erased \(erased.count) recognised titles")
    } catch {
      // They are still not shown; the next launch or change tries again.
      logger.error("Failed to erase recognised titles (\(Notifier.redacted(error)))")
    }
    return erased.count
  }
}
