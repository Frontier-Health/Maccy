import Darwin
import Foundation

// The file a Universal Clipboard image copy points to.
//
// A copy marked `com.apple.is-remote-clipboard` with a `.jpeg` file URL is
// shown as that file's image. Any app can write that marker and any file URL,
// so the file is read only when:
// - the URL is a `file:` URL whose path, with `.` and `..` resolved, is inside
//   a directory where macOS stages Universal Clipboard files for the current
//   user (checked without touching the file system, so a path elsewhere, such
//   as on a network or slow volume, is never even looked up);
// - that staging directory itself is a real directory, not a symlink, owned
//   by the current user;
// - the file, opened without following a final symlink, really is inside that
//   directory as written (`F_GETPATH` on the open file), so neither the
//   directory nor anything below it can be a symlink to elsewhere;
// - it is a regular file (not a directory, device, FIFO or socket) on a local
//   volume (`MNT_LOCAL`), owned by the current user, with no other hard link,
//   and no larger than `maximumBytes`.
// The read happens off the main thread, on `queue`, and stops early when
// cancelled.
//
// Threat boundary: a malicious clipboard URL (any app can write one) cannot
// make Maccy read anything outside the current user's staging directories. A
// local process that can already write into those directories (it runs as the
// user) is outside this boundary: it could place any image there itself.
//
// macOS doesn't document where it stages these files. Two locations are known:
// `~/Library/Group Containers/group.com.apple.coreservices.useractivityd/
// shared-pasteboard/items/<UUID>/` (current macOS) and
// `$TMPDIR/com.apple.useractivityd/shared-pasteboard/items/` (macOS 12), where
// `$TMPDIR` is the per-user `/var/folders/<x>/<y>/T/`. Both are allowed, for
// the current user only: the home directory comes from the password database
// and the temporary directory from `confstr(_CS_DARWIN_USER_TEMP_DIR)` (inside
// the app sandbox `$TMPDIR` and `NSTemporaryDirectory()` name the container's
// own temporary directory, so the per-user `/var/folders/<x>/<y>/` prefix is
// taken from it).
nonisolated enum UniversalClipboardFile {
  enum Rejection: String, Error, Sendable {
    case notFileURL
    case outsideAllowedLocation
    case unreadable
    case notRegularFile
    case notLocalVolume
    case tooLarge
    case allowedDirectoryNotTrusted
    case notOwnedByUser
    case hardLinked
    case cancelled
  }

  // Set from any thread to stop a read in progress.
  nonisolated final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
      lock.withLock { cancelled = true }
    }
  }

  // The same limit as one representation of a copy.
  static var defaultMaximumBytes: Int { ContentLimits.maximumRepresentationBytes }

  #if DEBUG
  nonisolated(unsafe) static var allowedDirectoriesForTesting: [String]?
  nonisolated(unsafe) static var maximumBytesForTesting: Int?
  // Called on every read with whether it ran on the main thread.
  nonisolated(unsafe) static var readObserverForTesting: (@Sendable (_ onMainThread: Bool) -> Void)?
  #endif

  static var maximumBytes: Int {
    #if DEBUG
    if let maximumBytesForTesting { return maximumBytesForTesting }
    #endif
    return defaultMaximumBytes
  }

  private static let queue = DispatchQueue(label: AppIdentity.bundleIdentifier + ".universalClipboardFile",
                                           qos: .utility)

  // Where macOS stages Universal Clipboard files for the current user, each
  // ending in "/".
  static var allowedDirectories: [String] {
    #if DEBUG
    if let allowedDirectoriesForTesting { return allowedDirectoriesForTesting.map(withTrailingSlash) }
    #endif
    var directories: [String] = []
    // The real home directory, not the sandbox container.
    if let home = getpwuid(getuid())?.pointee.pw_dir {
      directories.append(withTrailingSlash(String(cString: home)) +
        "Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/items/")
    }
    if let temporary = userTemporaryDirectory {
      directories.append(temporary + "com.apple.useractivityd/shared-pasteboard/items/")
    }
    return directories
  }

  // The current user's `/var/folders/<x>/<y>/T/`, from
  // `confstr(_CS_DARWIN_USER_TEMP_DIR)`, which names it or a directory inside
  // it.
  static var userTemporaryDirectory: String? {
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
    guard length > 0 else {
      return nil
    }
    var buffer = [CChar](repeating: 0, count: length)
    guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 else {
      return nil
    }
    return userTemporaryRoot(of: string(buffer))
  }

  // The `/var/folders/<x>/<y>/T/` that `path` is or is inside, spelled with
  // `/private`; nil for any other path.
  static func userTemporaryRoot(of path: String) -> String? {
    var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    if components.first == "private" {
      components.removeFirst()
    }
    guard components.count >= 5, components[0] == "var", components[1] == "folders",
          components[4] == "T" else {
      return nil
    }
    return "/private/" + components.prefix(5).joined(separator: "/") + "/"
  }

  // Whether `url` names a file strictly inside an allowed directory. Pure
  // string work: nothing on disk is touched.
  static func isInAllowedLocation(_ url: URL) -> Bool {
    guard url.isFileURL else {
      return false
    }
    let path = url.standardizedFileURL.path
    guard !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
      return false
    }
    return isInside(path, anyOf: allowedDirectories.flatMap(aliases))
  }

  // Reads the file, applying every check above. Call off the main thread.
  static func read(_ url: URL, cancellation: Cancellation? = nil) throws(Rejection) -> Data {
    #if DEBUG
    readObserverForTesting?(Thread.isMainThread)
    #endif
    guard url.isFileURL else { throw .notFileURL }
    guard isInAllowedLocation(url) else { throw .outsideAllowedLocation }

    // The staging directory the URL names, as written: not a symlink, and
    // owned by the current user.
    let path = url.standardizedFileURL.path
    guard let directory = allowedDirectories.first(where: { isInside(path, anyOf: aliases($0)) }) else {
      throw .outsideAllowedLocation
    }
    // Without the trailing "/", which would make lstat follow a symlink.
    var directoryStatus = stat()
    guard lstat(String(directory.dropLast()), &directoryStatus) == 0 else { throw .unreadable }
    guard (directoryStatus.st_mode & S_IFMT) == S_IFDIR, directoryStatus.st_uid == getuid() else {
      throw .allowedDirectoryNotTrusted
    }

    // O_NOFOLLOW: a symlink as the last component fails to open. O_NONBLOCK:
    // opening a FIFO doesn't wait for a writer.
    let descriptor = open(url.standardizedFileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw errno == ELOOP ? .notRegularFile : .unreadable
    }
    defer { close(descriptor) }

    // Where the opened file really is, every symlink resolved: still inside
    // the staging directory as written (only `/var` and `/private/var` are
    // the same), so no component on the way can lead elsewhere.
    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &pathBuffer) != -1 else { throw .unreadable }
    guard isInside(Self.string(pathBuffer), anyOf: aliases(directory)) else {
      throw .outsideAllowedLocation
    }

    var status = stat()
    guard fstat(descriptor, &status) == 0 else { throw .unreadable }
    try check(status)

    var volume = statfs()
    guard fstatfs(descriptor, &volume) == 0 else { throw .unreadable }
    guard (volume.f_flags & UInt32(MNT_LOCAL)) != 0 else { throw .notLocalVolume }

    let limit = maximumBytes
    guard status.st_size <= off_t(limit) else { throw .tooLarge }

    // Read at most one byte more than the limit, in case the file grew.
    var data = Data()
    let chunkSize = 64 * 1_024
    var chunk = [UInt8](repeating: 0, count: chunkSize)
    while data.count <= limit {
      if cancellation?.isCancelled == true { throw .cancelled }
      let count = Darwin.read(descriptor, &chunk, chunkSize)
      if count < 0 {
        if errno == EINTR { continue }
        throw .unreadable
      }
      if count == 0 { break }
      data.append(contentsOf: chunk[0..<count])
    }
    guard data.count <= limit else { throw .tooLarge }
    return data
  }

  // The checks on the opened file's status: a regular file owned by the
  // current user, with no other hard link (another name for it could be
  // anywhere on the volume).
  static func check(_ status: stat, userID: uid_t = getuid()) throws(Rejection) {
    guard (status.st_mode & S_IFMT) == S_IFREG else { throw .notRegularFile }
    guard status.st_uid == userID else { throw .notOwnedByUser }
    guard status.st_nlink <= 1 else { throw .hardLinked }
  }

  // `read(_:)` on a background queue; nil when any check fails or the read
  // was cancelled.
  static func load(_ url: URL, cancellation: Cancellation? = nil) async -> Data? {
    await withCheckedContinuation { continuation in
      queue.async {
        guard cancellation?.isCancelled != true else {
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(returning: try? read(url, cancellation: cancellation))
      }
    }
  }

  private static func string(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  private static func withTrailingSlash(_ path: String) -> String {
    path.hasSuffix("/") ? path : path + "/"
  }

  // `/var`, `/tmp` and `/etc` are symlinks into `/private`, and a URL can use
  // either spelling.
  private static func aliases(_ directory: String) -> [String] {
    for prefix in ["/var/", "/tmp/", "/etc/"] where directory.hasPrefix(prefix) {
      return [directory, "/private" + directory]
    }
    if directory.hasPrefix("/private/") {
      return [directory, String(directory.dropFirst("/private".count))]
    }
    return [directory]
  }

  // Whether `path` names something below one of `directories` (not the
  // directory itself), comparing whole components.
  private static func isInside(_ path: String, anyOf directories: [String]) -> Bool {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    return directories.contains { directory in
      let prefix = directory.split(separator: "/", omittingEmptySubsequences: true)
      guard path.hasPrefix("/"), components.count > prefix.count else {
        return false
      }
      return zip(prefix, components).allSatisfy { $0 == $1 }
    }
  }
}
