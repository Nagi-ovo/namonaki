import AppKit

/// Downloads and caches avatars and emote images.
///
/// The network boundary matches the bundled page's CSP: only Bilibili image hosts are
/// requested. The session is ephemeral and cookie-free — watching danmaku needs no login.
@MainActor
final class RemoteImageLoader {
    static let shared = RemoteImageLoader()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let session: URLSession

    private init() {
        cache.countLimit = 400
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .returnCacheDataElseLoad
        // Memory only; nothing about a stream is written to disk.
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 0)
        session = URLSession(configuration: config)
    }

    /// Already-resident images, so a row can size itself without flashing a placeholder first.
    func cached(_ urlString: String) -> NSImage? {
        cache.object(forKey: urlString as NSString)
    }

    /// Concurrent requests for the same URL share one download.
    func load(_ urlString: String, completion: @escaping (NSImage) -> Void) {
        if let image = cached(urlString) {
            completion(image)
            return
        }
        guard let url = URL(string: urlString), Self.allows(url) else { return }

        let task = inFlight[urlString] ?? {
            let task = Task<NSImage?, Never> { [session] in
                guard let (data, response) = try? await session.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = NSImage(data: data) else { return nil }
                return image
            }
            inFlight[urlString] = task
            return task
        }()

        Task { [weak self] in
            let image = await task.value
            guard let self else { return }
            self.inFlight[urlString] = nil
            guard let image else { return }
            self.cache.setObject(image, forKey: urlString as NSString)
            completion(image)
        }
    }

    /// Bilibili image hosts only. Incoming URLs are already upgraded to HTTPS by the
    /// event mapper; this is the second line of defence.
    static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return ["hdslb.com", "bilibili.com", "bilivideo.com"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }
}
