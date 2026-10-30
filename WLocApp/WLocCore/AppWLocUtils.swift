//
//  AppWLocUtils.swift
//  WLocApp-iOS
//
//  Copyright (c) 2026 WLoc8.com contributors.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

class AppWLocUtils {
    private static let debugLogQueue = DispatchQueue(label: "com.wloc8.debug-log")
    
    static func mainThread(_ block:(()-> Void)?){
        if Thread.isMainThread {
            block?()
            return
        }
        
        DispatchQueue.main.async(execute: {
            block?()
        })
    }
    
    static func mainThreadAfter(_ after:TimeInterval, _ block:(()-> Void)?){
        if Thread.isMainThread {
            if after > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(after * 1000)), execute: {
                    block?()
                })
            } else {
                block?()
            }
            return
        }
        
        if after > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(after * 1000)), execute: {
                block?()
            })
        } else {
            DispatchQueue.main.async(execute: {
                block?()
            })
        }
    }

    /// 同时写入控制台和文件，毫秒时间方便对照并发连接。
    static func debugLog(_ message: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
        let str = f.string(from: Date())
        
        let line = "[\(str)] \(message)\n"
        NSLog("%@", message)
        print("\(message)")

        debugLogQueue.async {
            appendDebugLogLine(line)
        }
    }

    /// 查看窗口可只读取末尾，导出时仍保留完整文件。
    static func readDebugLog(maximumBytes: Int? = nil, completion: @escaping (String) -> Void) {
        debugLogQueue.async {
            let content: String
            if let url = debugLogURL,
               let handle = try? FileHandle(forReadingFrom: url) {
                defer { handle.closeFile() }
                let size = handle.seekToEndOfFile()
                let offset = maximumBytes.map { size > UInt64($0) ? size - UInt64($0) : 0 } ?? 0
                handle.seek(toFileOffset: offset)
                var data = handle.readDataToEndOfFile()
                // 截取时跳过不完整的第一行，避免从 UTF-8 字符中间开始显示。
                if offset > 0, let newline = data.firstIndex(of: 10) {
                    data = Data(data.suffix(from: data.index(after: newline)))
                }
                let text = String(decoding: data, as: UTF8.self)
                content = (offset > 0 ? "（仅显示最近的日志，导出可保存完整内容）\n\n" : "")
                    + (text.isEmpty ? "暂无日志。" : text)
            } else {
                content = "暂无日志。"
            }
            DispatchQueue.main.async {
                completion(content)
            }
        }
    }

    /// 清空和写入走同一队列，完成后可立即刷新窗口。
    static func clearDebugLog(completion: (() -> Void)? = nil) {
        debugLogQueue.async {
            guard let url = debugLogURL else {
                DispatchQueue.main.async {
                    completion?()
                }
                return
            }

            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data().write(to: url, options: .atomic)
                appendDebugLogLine("调试日志已清空，开始重新记录。\n")
            } catch {
                NSLog("%@ debug log clear failed: %@", AppWLocConfig.displayName, error.localizedDescription)
            }

            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    #if os(macOS)
    /// 等待之前的写入完成，再复制完整日志供用户反馈。
    static func exportDebugLog(to destination: URL, completion: @escaping (Error?) -> Void) {
        debugLogQueue.async {
            var exportError: Error?
            do {
                guard let source = debugLogURL else { throw CocoaError(.fileNoSuchFile) }
                let data = try Data(contentsOf: source, options: .mappedIfSafe)
                try data.write(to: destination, options: .atomic)
            } catch {
                exportError = error
            }
            DispatchQueue.main.async { completion(exportError) }
        }
    }

    /// 启动和每次锁定都记录环境，清空后重现也能带上系统版本。
    static func logMacEnvironment(reason: String) {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        debugLog("""
        ===== \(reason) =====
        App：\(AppWLocConfig.displayName) \(AppWLocConfig.currentVersion) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "未知"))
        系统：\(ProcessInfo.processInfo.operatingSystemVersionString)，架构：\(architecture)，PID：\(ProcessInfo.processInfo.processIdentifier)
        Bundle：\(Bundle.main.bundleIdentifier ?? "未知")，路径：\(Bundle.main.bundlePath)
        日志：\(debugLogURL?.path ?? "不可用")
        """)
    }
    #endif

    /// 串行追加，避免不同连接的日志内容互相覆盖。
    private static func appendDebugLogLine(_ line: String) {
        guard let url = debugLogURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let data = line.data(using: .utf8) else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(data)
        } catch {
            NSLog("%@ debug log write failed: %@", AppWLocConfig.displayName, error.localizedDescription)
        }
    }

    static var debugLogURL: URL? {
        #if os(iOS)
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppWLocConfig.appGroupIdentifier
        ) {
            return container
                .appendingPathComponent("AppWLoc", isDirectory: true)
                .appendingPathComponent("wloc-debug.log", isDirectory: false)
        }
        #endif

        #if os(macOS)
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/WLoc8.com", isDirectory: true)
            .appendingPathComponent("wloc-debug.log", isDirectory: false)
        #else

        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AppWLoc", isDirectory: true)
            .appendingPathComponent("wloc-debug.log", isDirectory: false)
        #endif
    }
    
}
