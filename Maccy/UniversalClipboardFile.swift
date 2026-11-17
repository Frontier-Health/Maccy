import Darwin
import Foundation

// The file a Universal Clipboard image copy points to.
//
// A copy marked `com.apple.is-remote-clipboard` with a `.jpeg` file URL is
// shown as that file's image. Any app can write that marker and any file URL,
// so the file is read only when:
// - the URL is a `file:` URL whose path, with `.` and `..` resolved, is inside
//   a directory where macOS stages Universal Clipboard files (checked without
//   touching the file system, so a path elsewhere, such as on a network or
//   slow volume, is never even looked up);
// - the file, opened without following a final symlink, really is inside that
//   directory once every symlink is resolved (`F_GETPATH` on the open file);
// - it is a regular file (not a directory, device, FIFO or socket) on a local
//   volume (`MNT_LOCAL`), no larger than `maximumBytes`.
// The read happens off the main thread, on `queue`.
//
// macOS doesn't document where it stages these files. Two locations are known:
// `~/Library/Group Containers/group.com.apple.coreservices.useractivityd/
// shared-pasteboard/items/<UUID>/` (current macOS) and
// `$TMPDIR/com.apple.useractivityd/shared-pasteboard/items/` (macOS 12), where
// `$TMPDIR` is the per-user `/var/folders/<x>/<y>/T/`. Both are allowed. The
// second is matched as a pattern, because inside the app sandbox `$TMPDIR` is
// the container's own temporary directory.
nonisolated enum UniversalClipboardFile {
  enum Rejection: String, Error, Sendable {
    case notFileURL
    case outsideAllowedLocation
    case unreadable
    case notRegularFile
    case notLocalVolume
    case tooLarge
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

  // Where macOS stages Universal Clipboard files, each ending in "/". A `*`
  // component matches any one path component.
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
    directories.append("/private/var/folders/*/*/T/com.apple.useractivityd/shared-pasteboard/items/")
    return directories
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
  static func read(_ url: URL) throws(Rejection) -> Data {
    #if DEBUG
    readObserverForTesting?(Thread.isMainThread)
    #endif
    guard url.isFileURL else { throw .notFileURL }
    guard isInAllowedLocation(url) else { throw .outsideAllowedLocation }

    // O_NOFOLLOW: a symlink as the last component fails to open. O_NONBLOCK:
    // opening a FIFO doesn't wait for a writer.
    let descriptor = open(url.standardizedFileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw errno == ELOOP ? .notRegularFile : .unreadable
    }
    defer { close(descriptor) }

    // Where the opened file really is, every symlink resolved.
    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &pathBuffer) != -1 else { throw .unreadable }
    let realDirectories = allowedDirectories.map { realDirectory($0) ?? $0 }
    guard isInside(Self.string(pathBuffer), anyOf: realDirectories.flatMap(aliases)) else {
      throw .outsideAllowedLocation
    }

    var status = stat()
    guard fstat(descriptor, &status) == 0 else { throw .unreadable }
    guard (status.st_mode & S_IFMT) == S_IFREG else { throw .notRegularFile }

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

  // `read(_:)` on a background queue; nil when any check fails.
  static func load(_ url: URL) async -> Data? {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: try? read(url))
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

  // A directory with every symlink resolved; nil for a pattern or a
  // directory that doesn't exist.
  private static func realDirectory(_ directory: String) -> String? {
    guard !directory.split(separator: "/").contains("*"), let resolved = realpath(directory, nil) else {
      return nil
    }
    defer { free(resolved) }
    return withTrailingSlash(String(cString: resolved))
  }

  // Whether `path` names something below one of `directories` (not the
  // directory itself), comparing whole components.
  private static func isInside(_ path: String, anyOf directories: [String]) -> Bool {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    return directories.contains { directory in
      let pattern = directory.split(separator: "/", omittingEmptySubsequences: true)
      guard path.hasPrefix("/"), components.count > pattern.count else {
        return false
      }
      return zip(pattern, components).allSatisfy { $0 == "*" || $0 == $1 }
    }
  }
}
