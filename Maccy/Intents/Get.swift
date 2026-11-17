import Foundation
import AppKit
import AppIntents

nonisolated struct GetItemContents: Sendable, Equatable {
  let text: String?
  let html: Data?
  let file: URL?
  let image: Data?
  let rtf: Data?
}

struct Get: AppIntent, CustomIntentMigratedAppIntent {
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  static let intentClassName = "GetIntent"

  static let title: LocalizedStringResource = "Get Item from Clipboard History"
  static let description = IntentDescription("""
  Gets an item from Maccy clipboard history.
  The returned item can be used to access its plain/rich/HTML text, image contents or file location.
  """)

  @Parameter(title: "Selected", default: true)
  var selected: Bool

  @Parameter(title: "Number", default: 1)
  var number: Int

  static var parameterSummary: some ParameterSummary {
    When(\.$selected, .equalTo, false) {
      Summary {
        \.$number
        \.$selected
      }
    } otherwise: {
      Summary {
        \.$selected
      }
    }
  }

  func perform() async throws -> some IntentResult & ReturnsValue<HistoryItemAppEntity> {
    try await MainActor.run { try HistoryIntentAccess.requireEnabled() }
    try await HistoryIntentAccess.waitUntilReady()
    let (contents, imageURL) = try await Self.read(selected: selected, number: number)

    let intentItem = HistoryItemAppEntity()
    intentItem.text = contents.text

    if let html = contents.html {
      intentItem.html = String(data: html, encoding: .utf8)
    }

    if let fileURL = contents.file {
      intentItem.file = fileURL
    }

    if let imageURL {
      intentItem.image = IntentFile(fileURL: imageURL, type: .png)
    }

    if let rtf = contents.rtf {
      intentItem.richText = String(data: rtf, encoding: .utf8)
    }

    return .result(value: intentItem)
  }

  @MainActor
  private static func read(selected: Bool, number: Int) async throws -> (GetItemContents, URL?) {
    try HistoryIntentAccess.requireEnabled()
    // History reflects the current storage policy and expiry before anything is read.
    AppState.shared.history.enforceStoragePolicy()
    AppState.shared.history.runExpiryIfDue()
    var item: HistoryItem?
    if selected {
      item = AppState.shared.navigator.selection.first?.item
    } else {
      item = try HistoryIntentAccess.item(number: number, in: AppState.shared.history.items).item
    }

    guard let item else {
      throw AppIntentError.notFound
    }

    return try await export(item)
  }

  #if DEBUG
  // Runs after the image is converted, before the checks that follow it, so
  // tests can change settings at that point.
  @MainActor static var afterImageConversionForTesting: (() -> Void)?
  #endif

  // What the intent hands out for `item`: its contents, and its image
  // converted to PNG and written to a file. The image is decoded only
  // through ValidatedImage (every image in the data within the limits, one
  // decoded), off the main actor. The intents switch and the storage policy
  // are checked again after that wait, and the contents are read under the
  // policy in effect then; the image is exported only if it is still the one
  // that may be read.
  @MainActor
  static func export(_ item: HistoryItem) async throws -> (GetItemContents, URL?) {
    // A Universal Clipboard image file is read off the main thread first.
    await item.loadImageIfNeeded()
    guard !item.isDeleted else {
      throw AppIntentError.notFound
    }

    let source = item.imageSource(readableBy: StoragePolicy.currentReadAllowList)
    // Stored images can be JPEG, HEIC or TIFF. The exported IntentFile promises PNG.
    var pngData: Data?
    if let image = Self.contents(of: item, readableBy: StoragePolicy.currentReadAllowList).image {
      pngData = await ValidatedImage.encodePNG(image)
    }
    #if DEBUG
    afterImageConversionForTesting?()
    #endif

    try HistoryIntentAccess.requireEnabled()
    AppState.shared.history.enforceStoragePolicy()
    guard !item.isDeleted else {
      throw AppIntentError.notFound
    }
    let allowList = StoragePolicy.currentReadAllowList
    let contents = Self.contents(of: item, readableBy: allowList)
    if contents.image == nil || item.imageSource(readableBy: allowList) != source {
      pngData = nil
    }
    let imageURL = try pngData.map { try IntentImageExports.write($0, for: item) }
    return (contents, imageURL)
  }

  // What the intent hands out: only representations of exactly the types that
  // may be read now, whatever an item stored under an earlier policy still
  // holds. An image comes only from an allowed image type, never from another
  // stored image format.
  @MainActor
  static func contents(of item: HistoryItem, readableBy allowList: StorageAllowList) -> GetItemContents {
    GetItemContents(
      text: item.text(readableBy: allowList),
      html: item.htmlData(readableBy: allowList),
      file: item.fileURLs(readableBy: allowList).first,
      image: item.imageData(readableBy: allowList),
      rtf: item.rtfData(readableBy: allowList)
    )
  }
}
