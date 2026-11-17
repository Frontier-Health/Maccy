import AppKit
import Defaults
import ImageIO
import Logging
import SwiftData

// Size limits for copied content, which comes from any app or web page.
//
// - One representation (one type of one copy) may be at most
//   `maximumRepresentationBytes` (64 MiB), and one copy at most
//   `maximumCopyBytes` (96 MiB) in total. A full-screen capture of a 5K
//   Retina display (5120×2880) is 59.0 MB (56.3 MiB) as uncompressed 32-bit
//   TIFF, and macOS adds a PNG of a few MiB to 25 MiB; a MacBook Pro 16"
//   capture (3456×2234) is 30.9 MB as TIFF. Both fit. A 6K display capture
//   (6016×3384, 81.4 MB as TIFF) does not, and is left on the system
//   clipboard. With 999 items history can still hold about 94 GiB at these
//   limits; a total-history byte budget is a follow-up.
//   A copy over either limit is not recorded at all (it stays on the system
//   clipboard, and a notification with fixed text says a copy was too large
//   to save): dropping only the oversized representation would store a copy
//   whose formatted and plain versions no longer match what was copied.
//   NSPasteboard has no way to learn a representation's size without
//   transferring it, so each one is checked as soon as it is read, before
//   anything decodes it, and nothing more is read once a limit is passed
//   (see PasteboardCopyRead).
// - An image is decoded (for the list, the preview, accessibility, text
//   recognition or export) only through ValidatedImage, which checks every
//   image in the data against `maximumImagePixels` before decoding one.
nonisolated enum ContentLimits {
  static let defaultMaximumRepresentationBytes = 64 * 1_024 * 1_024
  static let defaultMaximumCopyBytes = 96 * 1_024 * 1_024
  // 100 megapixels, about 400 MB once decoded: five full-screen screenshots
  // of a 6K display.
  static let defaultMaximumImagePixels = 100_000_000
  // Metadata the watcher reads besides the stored content (the
  // org.nspasteboard.source marker): a bundle identifier or Maccy's own
  // marker, so 1 KiB is ample. Never more than one representation may be.
  static let defaultMaximumMarkerBytes = 1_024

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

  static var maximumMarkerBytes: Int {
    min(defaultMaximumMarkerBytes, maximumRepresentationBytes)
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
    case marker(String, bytes: Int)
    case copy(bytes: Int)

    var description: String {
      switch self {
      case .representation(let type, let bytes):
        return "representation \(type) is \(bytes) bytes, limit \(ContentLimits.maximumRepresentationBytes)"
      case .marker(let type, let bytes):
        return "marker \(type) is \(bytes) bytes, limit \(ContentLimits.maximumMarkerBytes)"
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
      return addToTotal(count)
    }

    // Metadata read besides the stored content has a small fixed limit.
    mutating func addMarker(_ type: NSPasteboard.PasteboardType, bytes count: Int) -> Violation? {
      guard count <= ContentLimits.maximumMarkerBytes else {
        return .marker(type.rawValue, bytes: count)
      }
      return addToTotal(count)
    }

    private mutating func addToTotal(_ count: Int) -> Violation? {
      bytes += count
      guard bytes <= ContentLimits.maximumCopyBytes else {
        return .copy(bytes: bytes)
      }
      return nil
    }
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
    // Nothing queued reaches Vision, and a running request is cancelled.
    HistoryItem.cancelAllTextRecognition()

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
