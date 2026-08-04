import Foundation
import Testing

struct RendererBundleTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func vendorsNativeRelayRendererWithoutSourceMaps() throws {
        let renderer = projectRoot.appendingPathComponent("Resources/Renderer", isDirectory: true)
        #expect(FileManager.default.fileExists(
            atPath: renderer.appendingPathComponent("index.html").path
        ))

        let javascriptRoot = renderer.appendingPathComponent("js", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: javascriptRoot,
            includingPropertiesForKeys: nil
        )
        #expect(!files.contains(where: { $0.pathExtension == "map" }))

        let scripts = files
            .filter { $0.pathExtension == "js" }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        #expect(scripts.contains("Namonaki relay message parse failed"))
        #expect(scripts.contains("/events?token="))
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
