import Foundation

/// Calls `onChange` shortly after files are added, removed, or renamed in a folder.
@MainActor
final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject
    private var pending: Task<Void, Never>?

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // macOS writes a screenshot as a hidden temp file and renames it, so wait for the burst to settle.
                self?.pending?.cancel()
                self?.pending = Task {
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !Task.isCancelled else { return }
                    onChange()
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
