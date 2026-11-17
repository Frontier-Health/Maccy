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

      let warnings = item.textWarnings
      if let pastedText = warnings.pastedText {
        PastedTextView(text: pastedText)
          .padding(.top, 6)
      }

      if let note = Self.pastedTextNote(warnings.pastedTextIsNotFileNames) {
        warning(note)
      }

      if let note = Self.invisibleCharactersNote(warnings.hasInvisibleCharacters) {
        warning(note)
      }

      if let note = Self.formattedTextNote(item.formattedTextComparison) {
        if Self.formattedTextNoteIsWarning(item.formattedTextComparison) {
          warning(note)
        } else {
          // Expected on most styled web and Office copies, so a compact,
          // low-key tag with the sentence as help text, not a warning.
          Text(Self.formattedTagLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(.secondary.opacity(0.5), lineWidth: 1))
            .help(note)
            .accessibilityLabel(Text(note))
            .padding(.top, 6)
        }
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

      if item.hasImage, let size = item.item.imagePixelSize {
        HStack(spacing: 3) {
          Text("Dimensions", tableName: "PreviewItemView")
          Text("\(Int(size.width))×\(Int(size.height))")
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

  @ViewBuilder
  private func warning(_ note: String) -> some View {
    Label {
      Text(note)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    }
    .padding(.top, 6)
  }

  // The tag shown for `.renderingNotChecked`; its help text is the note.
  static var formattedTagLabel: String {
    NSLocalizedString("FormattedTag", tableName: "PreviewItemView", value: "Formatted", comment: "")
  }

  // English only; other locales fall back to it.
  static var pastedTextLabel: String {
    NSLocalizedString("PastesAsText", tableName: "PreviewItemView", value: "Pastes as text:", comment: "")
  }

  static func pastedTextNote(_ isNotFileNames: Bool) -> String? {
    guard isNotFileNames else {
      return nil
    }
    return NSLocalizedString(
      "PastedTextIsNotFileNames",
      tableName: "PreviewItemView",
      value: "Pasting into a text field or terminal, or pasting without formatting, inserts the text above, " +
        "not the files or image shown.",
      comment: ""
    )
  }

  static func invisibleCharactersNote(_ hasInvisibleCharacters: Bool) -> String? {
    guard hasInvisibleCharacters else {
      return nil
    }
    return NSLocalizedString(
      "InvisibleCharacters",
      tableName: "PreviewItemView",
      value: "This text contains invisible or direction-changing characters. They are pasted too.",
      comment: ""
    )
  }

  // Whether the note is a warning (the formatted text differs, or couldn't
  // be read) rather than the neutral note.
  static func formattedTextNoteIsWarning(_ comparison: FormattedTextComparison) -> Bool {
    comparison == .differs || comparison == .notChecked
  }

  // Never says the formatted and plain versions are the same.
  static func formattedTextNote(_ comparison: FormattedTextComparison) -> String? {
    switch comparison {
    case .notApplicable, .noTextDifference:
      return nil
    case .renderingNotChecked:
      return NSLocalizedString(
        "FormattedTextNotCompared",
        tableName: "PreviewItemView",
        value: "Formatted paste was not checked against this text.",
        comment: ""
      )
    case .differs:
      return NSLocalizedString(
        "FormattedTextDiffers",
        tableName: "PreviewItemView",
        value: "The formatted version contains different text from what is shown. " +
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

// The plain text a text destination receives from an item shown as files or
// an image, labelled, in full or with the truncation note.
struct PastedTextView: View {
  private static let largeTextThreshold = 1_000

  let text: SizedString

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(PreviewItemView.pastedTextLabel)
        .font(.body.bold())
      if text.byteCount >= Self.largeTextThreshold {
        LargeTextView(text: text.string)
          .frame(minHeight: 60, maxHeight: 200)
      } else {
        Text(text.string)
          .font(.body.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let note = PreviewItemView.truncationNote(text.isTruncated) {
        Label {
          Text(note)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "scissors")
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}
