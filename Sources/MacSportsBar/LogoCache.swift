import AppKit

/// Loads and caches team logo images (ESPN CDN PNGs) for the optional menu-bar team-logos
/// display. `image(for:)` returns the cached logo synchronously, or `nil` while it loads in
/// the background — invoking `onLoad` when a new image arrives so the menu bar can re-render.
@MainActor
final class LogoCache {
    private var cache: [URL: NSImage] = [:]
    private var inFlight: Set<URL> = []

    /// Called on the main actor whenever a new logo finishes loading.
    var onLoad: (() -> Void)?

    /// The cached logo, or `nil` — a miss kicks off a one-time background load.
    func image(for url: URL?) -> NSImage? {
        guard let url else { return nil }
        if let image = cache[url] { return image }
        load(url)
        return nil
    }

    private func load(_ url: URL) {
        guard !inFlight.contains(url) else { return }
        inFlight.insert(url)
        Task { [weak self] in
            let image = await Self.fetch(url)
            self?.store(image, for: url)
        }
    }

    private func store(_ image: NSImage?, for url: URL) {
        inFlight.remove(url)
        guard let image else { return }
        cache[url] = image
        onLoad?()
    }

    private nonisolated static func fetch(_ url: URL) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }
}
