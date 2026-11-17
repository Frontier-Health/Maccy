import Cocoa

class About {
  static let repositoryURL = "https://github.com/Frontier-Health/Maccy"

  private let familyCredits = NSAttributedString(
    string: "Special thank you to Tonia, Anna & Guy! ❤️",
    attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor]
  )

  // Upstream credits are kept as text. The upstream author's personal links are not carried over.
  private let kossCredits = NSAttributedString(
    string: "Kudos to Sasha Koss for help! 🏂",
    attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor]
  )

  // One link only: the fork has no public website or support channel.
  private var links: NSMutableAttributedString {
    let string = NSMutableAttributedString(string: "Source code",
                                           attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor])
    string.addAttribute(.link, value: Self.repositoryURL, range: NSRange(location: 0, length: string.length))
    return string
  }

  var credits: NSMutableAttributedString {
    let credits = NSMutableAttributedString(string: "",
                                            attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor])
    credits.append(links)
    credits.append(NSAttributedString(string: "\n\n"))
    credits.append(kossCredits)
    credits.append(NSAttributedString(string: "\n"))
    credits.append(familyCredits)
    credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))
    return credits
  }

  @objc
  func openAbout(_ sender: NSMenuItem?) {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [NSApplication.AboutPanelOptionKey.credits: credits])
  }
}
