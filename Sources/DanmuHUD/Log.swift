import Foundation

/// 双击启动的 app 看不到终端输出，调试信息写文件最省事。
/// 日志在 /tmp/danmuhud.log
enum Log {
    private static let path = "/tmp/danmuhud.log"

    static func write(_ message: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
