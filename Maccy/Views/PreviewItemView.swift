import AppKit
import KeyboardShortcuts
import SwiftUI

struct PreviewItemView: View {
  private static let largeTextThreshold = 1_000

  var item: HistoryItemDecorator

  @ViewBuilder
  func previewImage(content: () -> some View) -> some View {
    content()
      .aspectRatio(contentMode: .fit)
      .clipShape(.rect(cornerRadius: 5))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if item.hasImage {
        AsyncView<NSImage?, _, _>(id: item.id) {
          return await item.asyncGetPreviewImage()
        } content: { image in
          if let image = image {
            previewImage {
              Image(nsImage: image)
                .resizable()
            }
          } else {
            previewImage {
              ZStack {
                Color.gray.opacity(0.3)
                  .frame(
                    idealWidth: HistoryItemDecorator.previewImageSize.width,
                    idealHeight: HistoryItemDecorator.previewImageSize.height
                  )
                Image(systemName: "photo.badge.exclamationmark")
                  .symbolRenderingMode(.multicolor)
                  .frame(alignment: .center)
              }
            }
          }
        } placeholder: {
          previewImage {
            ZStack {
              Color.gray.opacity(0.3)
                .frame(
                  idealWidth: HistoryItemDecorator.previewImageSize.width,
                  idealHeight: HistoryItemDecorator.previewImageSize.height
                )
              ProgressView()
                .frame(alignment: .center)
            }
          }
        }
      } else {
        if item.previewText.byteCount >= Self.largeTextThreshold {
          LargeTextView(text: item.previewText.string)
            .id("textpreview-\(item.id)")
        } else {
          ScrollView {
            Text(item.previewText.string)
              .font(.body)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxWidth: .infinity)
        }
      }

      if !item.hasImage, let note = Self.truncationNote(item.previewIsTruncated) {
        Label {
          Text(note)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "scissors")
            .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
      }

      if let note = Self.formattedTextNote(item.formattedTextComparison) {
        Label {
          Text(note)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
        .padding(.top, 6)
      }

      Spacer(minLength: 0)

      Divider()
        .padding(.bottom)

      if let application = item.application {
        HStack(spacing: 3) {
          Text("Application", tableName: "PreviewItemView")
          AppImageView(
            appImage: item.applicationImage,
            size: NSSize(width: 11, height: 11)
          )
          Text(application)
        }
      }

      if item.hasImage, let image = item.item.image {
        HStack(spacing: 3) {
          Text("Dimensions", tableName: "PreviewItemView")
          Text("\(Int(image.pixelSize.width))×\(Int(image.pixelSize.height))")
        }
      }

      if item.hasImage, let size = item.imageSize {
        HStack(spacing: 3) {
          Text("Size", tableName: "PreviewItemView")
          Text(size)
        }
      }

      HStack(spacing: 3) {
        Text("FirstCopyTime", tableName: "PreviewItemView")
        Text(item.item.firstCopiedAt, style: .date)
        Text(item.item.firstCopiedAt, style: .time)
      }

      HStack(spacing: 3) {
        Text("LastCopyTime", tableName: "PreviewItemView")
        Text(item.item.lastCopiedAt, style: .date)
        Text(item.item.lastCopiedAt, style: .time)
      }

      HStack(spacing: 3) {
        Text("NumberOfCopies", tableName: "PreviewItemView")
        Text(String(item.item.numberOfCopies))
      }
    }
    .controlSize(.small)
  }

  // English only; other locales fall back to it.
  static func truncationNote(_ isTruncated: Bool) -> String? {
    guard isTruncated else {
      return nil
    }
    return NSLocalizedString(
      "PreviewTruncated",
      tableName: "PreviewItemView",
      value: "Preview truncated: this copy is longer than what is shown. Pasting inserts all of it.",
      comment: ""
    )
  }

  static func formattedTextNote(_ comparison: FormattedTextComparison) -> String? {
    switch comparison {
    case .notApplicable, .same:
      return nil
    case .differs:
      return NSLocalizedString(
        "FormattedTextDiffers",
        tableName: "PreviewItemView",
        value: "The formatted version of this copy contains different text from what is shown. " +
          "Pasting with formatting may insert text that is not shown here; paste without formatting " +
          "to insert exactly this text.",
        comment: ""
      )
    case .notChecked:
      return NSLocalizedString(
        "FormattedTextNotChecked",
        tableName: "PreviewItemView",
        value: "The formatted version of this copy is too large to compare with the text shown. " +
          "Paste without formatting to insert exactly this text.",
        comment: ""
      )
    }
  }
}
