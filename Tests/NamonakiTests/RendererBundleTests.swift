import Foundation
import Testing

struct RendererBundleTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The bundle checked in under `Resources/Renderer` is what ships inside the app, so
    /// it has to be a real build of `web/` — not a stale copy, and never with source maps.
    @Test func vendorsNativeRelayRendererWithoutSourceMaps() throws {
        let renderer = projectRoot.appendingPathComponent("Resources/Renderer", isDirectory: true)
        #expect(FileManager.default.fileExists(
            atPath: renderer.appendingPathComponent("index.html").path
        ))

        let files = try FileManager.default.subpathsOfDirectory(atPath: renderer.path)
            .map { renderer.appendingPathComponent($0) }
        #expect(!files.contains(where: { $0.pathExtension == "map" }))

        func contents(ofExtension ext: String) -> String {
            files
                .filter { $0.pathExtension == ext }
                .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                .joined(separator: "\n")
        }

        let scripts = contents(ofExtension: "js")
        #expect(scripts.contains("Namonaki relay message parse failed"))
        #expect(scripts.contains("/events?token="))
        #expect(contents(ofExtension: "css").contains("--nmk-font-size"))
    }

    @Test func webViewDoesNotAllowArbitraryCleartextLoads() throws {
        let plistURL = projectRoot.appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let ats = try #require(plist["NSAppTransportSecurity"] as? [String: Any])

        #expect(ats["NSAllowsLocalNetworking"] as? Bool == true)
        #expect(ats["NSAllowsArbitraryLoadsInWebContent"] == nil)
    }
}
