import AppKit
import SnapKit
import UniformTypeIdentifiers

final class WLocMacDebugLogWindowController: NSWindowController {
    private let logController = WLocMacDebugLogViewController()

    init() {
        let window = NSWindow(contentViewController: logController)
        window.title = "\(AppWLocConfig.displayName) 调试日志"
        window.styleMask.insert(.resizable)
        window.setContentSize(NSSize(width: 900, height: 620))
        window.minSize = NSSize(width: 640, height: 420)
        window.setFrameAutosaveName("WLoc8.com.debugLogWindow")
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    /// 重复打开时复用窗口，并读取刚刚写入的日志。
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        logController.reloadLog()
        window?.makeKeyAndOrderFront(sender)
    }

    /// 诊断信息异步写完后更新内容，不改变当前窗口焦点。
    func reloadLog() {
        logController.reloadLog()
    }
}

private final class WLocMacDebugLogViewController: NSViewController {
    private let textView = NSTextView()
    private let statusLabel = NSTextField.wlocLabel("")

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let actions: [(String, Selector)] = [
            ("刷新", #selector(reloadLog)),
            ("复制全部", #selector(copyLog)),
            ("导出日志…", #selector(exportLog)),
            ("清空", #selector(clearLog))
        ]
        let toolbar = NSStackView(views: actions.map { NSButton(title: $0.0, target: self, action: $0.1) })
        toolbar.spacing = 8
        let hint = NSTextField(wrappingLabelWithString: "遇到问题时先清空日志，再重现锁定过程并导出日志反馈。日志包含定位坐标和网络请求内容。")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.isSelectable = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byCharWrapping
        scroll.documentView = textView

        [toolbar, hint, scroll, statusLabel].forEach { view.addSubview($0) }
        toolbar.snp.makeConstraints { make in
            make.top.leading.equalToSuperview().inset(16)
        }
        hint.snp.makeConstraints { make in
            make.top.equalTo(toolbar.snp.bottom).offset(10)
            make.leading.trailing.equalToSuperview().inset(16)
        }
        scroll.snp.makeConstraints { make in
            make.top.equalTo(hint.snp.bottom).offset(12)
            make.leading.trailing.equalToSuperview().inset(16)
            make.bottom.equalTo(statusLabel.snp.top).offset(-10)
        }
        statusLabel.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview().inset(16)
        }
    }

    /// 窗口只加载末尾两 MiB，完整内容仍可复制和导出。
    @objc func reloadLog() {
        AppWLocUtils.readDebugLog(maximumBytes: 2 * 1024 * 1024) { [weak self] content in
            guard let self else { return }
            self.textView.string = content
            self.textView.scrollToEndOfDocument(nil)
            self.statusLabel.stringValue = "\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)) 已刷新 · \(AppWLocUtils.debugLogURL?.path ?? "")"
        }
    }

    /// 从文件读取完整内容，复制结果不受窗口显示长度影响。
    @objc private func copyLog() {
        AppWLocUtils.readDebugLog { [weak self] content in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content, forType: .string)
            self?.statusLabel.stringValue = "已复制完整日志"
        }
    }

    /// 使用系统保存面板导出当前完整日志，失败时保留窗口内容。
    @objc private func exportLog() {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "log") ?? .plainText]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "WLoc-debug-\(formatter.string(from: Date())).log"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            AppWLocUtils.exportDebugLog(to: destination) { error in
                guard let self else { return }
                if let error {
                    let alert = NSAlert(error: error)
                    alert.beginSheetModal(for: window)
                } else {
                    self.statusLabel.stringValue = "已导出：\(destination.path)"
                }
            }
        }
    }

    /// 清空后重新写入环境，用户直接重现问题即可反馈。
    @objc private func clearLog() {
        AppWLocUtils.clearDebugLog { [weak self] in
            AppWLocUtils.logMacEnvironment(reason: "清空日志后重新记录")
            self?.reloadLog()
        }
    }
}
