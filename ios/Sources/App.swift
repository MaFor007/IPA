import UIKit
import AVFoundation
import MediaPlayer

// MARK: - 全局日志
final class Log {
    private static let lock = NSLock()
    private static var storage: [String] = []

    static var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    static func add(_ s: String) {
        let t = DateFormatter()
        t.dateFormat = "HH:mm:ss"
        let line = "[\(t.string(from: Date()))] \(s)"
        lock.lock()
        storage.append(line)
        if storage.count > 200 { storage.removeFirst(storage.count - 200) }
        lock.unlock()
        print(line)
    }
}

// MARK: - App 入口
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = BridgeViewController()
        w.makeKeyAndVisible()
        self.window = w

        KeepAlive.shared.start()
        HTTPServer.shared.start()
        return true
    }
}

// MARK: - 后台保活（静音音频循环；前台小窗模式下也保留，双保险）
final class KeepAlive {
    static let shared = KeepAlive()
    private var player: AVAudioPlayer?

    func start() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default,
                                    options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            Log.add("音频会话设置失败 \(error)")
        }
        guard let data = KeepAlive.silentWav() else { return }
        do {
            let p = try AVAudioPlayer(data: data)
            p.numberOfLoops = -1
            p.volume = 0
            p.prepareToPlay()
            p.play()
            player = p
            Log.add("后台保活已启动")
        } catch {
            Log.add("保活音频失败 \(error)")
        }
    }

    private static func silentWav() -> Data? {
        let sampleRate: UInt32 = 8000
        let dataSize: UInt32 = sampleRate * 2      // 1 秒 16bit 单声道
        var d = Data()
        func le32(_ v: UInt32) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        }
        func le16(_ v: UInt16) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        }
        d.append(contentsOf: Array("RIFF".utf8))
        le32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        le32(16); le16(1); le16(1)
        le32(sampleRate)
        le32(sampleRate * 2); le16(2); le16(16)
        d.append(contentsOf: Array("data".utf8))
        le32(dataSize)
        d.append(Data(repeating: 0, count: Int(dataSize)))
        return d
    }
}

// MARK: - 音量控制（MPVolumeView 滑块）
final class VolumeControl {
    static let shared = VolumeControl()
    private let mp = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 100, height: 40))

    func attach(to view: UIView) {
        if mp.superview == nil {
            mp.alpha = 0.01
            view.addSubview(mp)
        }
    }

    func set(_ v: Float) -> Bool {
        for sub in mp.subviews {
            if let slider = sub as? UISlider {
                slider.value = min(max(v, 0), 1)
                slider.sendActions(for: .touchUpInside)
                return true
            }
        }
        return false
    }
}

// MARK: - 触摸穿透根视图
// 收起模式下：只有小胶囊区域接收触摸，其余区域 hitTest 返回 nil。
// 电脑端 IOHIDEvent 注入走系统事件层，不受本视图影响；
// 但 App 必须保持前台（挂起后注入会被系统静默丢弃——实测结论）。
final class PassthroughView: UIView {
    // 命中区域（本视图坐标系）；为 nil 时整屏可交互（展开模式）
    var hotspot: CGRect?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let h = hotspot {
            return h.contains(point) ? super.hitTest(point, with: event) : nil
        }
        return super.hitTest(point, with: event)
    }
}

// MARK: - 界面（小胶囊 + 可展开面板）
final class BridgeViewController: UIViewController {
    private let statusLabel = UILabel()
    private let logView = UITextView()

    // 小胶囊（收起模式）
    private let pill = UIView()
    private let pillDot = UIView()
    private let pillLabel = UILabel()

    // 展开模式控件
    private let panel = UIView()
    private let titleLabel = UILabel()
    private let collapseButton = UIButton(type: .system)
    private let hideButton = UIButton(type: .system)

    private var timer: Timer?
    private var hideTimer: Timer?
    private var expanded = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let root = PassthroughView()
        root.frame = view.bounds
        root.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view = root

        // ---- 小胶囊 ----
        pill.backgroundColor = UIColor(white: 0, alpha: 0.45)
        pill.layer.cornerRadius = 16
        pill.layer.borderWidth = 1
        pill.layer.borderColor = UIColor(white: 1, alpha: 0.25).cgColor
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.isUserInteractionEnabled = true
        pill.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(pillTapped)))
        view.addSubview(pill)

        pillDot.backgroundColor = UIColor(red: 0.2, green: 0.9, blue: 0.45, alpha: 1)
        pillDot.layer.cornerRadius = 4
        pillDot.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(pillDot)

        pillLabel.text = "Bridge"
        pillLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        pillLabel.textColor = .white
        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(pillLabel)

        // ---- 展开面板 ----
        panel.backgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.isHidden = true
        view.addSubview(panel)

        let grad = CAGradientLayer()
        grad.frame = UIScreen.main.bounds
        grad.colors = [UIColor(red: 0.11, green: 0.14, blue: 0.22, alpha: 1).cgColor,
                       UIColor(red: 0.04, green: 0.06, blue: 0.09, alpha: 1).cgColor]
        grad.startPoint = CGPoint(x: 0, y: 0)
        grad.endPoint = CGPoint(x: 1, y: 1)
        panel.layer.insertSublayer(grad, at: 0)

        titleLabel.text = "iPhone Bridge"
        titleLabel.font = UIFont.systemFont(ofSize: 30, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(titleLabel)

        statusLabel.numberOfLines = 0
        statusLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = UIColor(red: 0.55, green: 0.76, blue: 1.0, alpha: 1)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(statusLabel)

        logView.backgroundColor = UIColor(white: 1, alpha: 0.04)
        logView.layer.cornerRadius = 14
        logView.textColor = UIColor(white: 0.7, alpha: 1)
        logView.font = UIFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        logView.isEditable = false
        logView.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(logView)

        collapseButton.setTitle("收起为小圆点（继续在电脑端操作）", for: .normal)
        collapseButton.setTitleColor(.white, for: .normal)
        collapseButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        collapseButton.backgroundColor = UIColor(red: 0.16, green: 0.36, blue: 0.85, alpha: 1)
        collapseButton.layer.cornerRadius = 12
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        collapseButton.addTarget(self, action: #selector(collapseTapped), for: .touchUpInside)
        panel.addSubview(collapseButton)

        hideButton.setTitle("隐藏到后台（推荐：后台继续注入）", for: .normal)
        hideButton.setTitleColor(.white, for: .normal)
        hideButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        hideButton.backgroundColor = UIColor(red: 0.16, green: 0.55, blue: 0.35, alpha: 1)
        hideButton.layer.cornerRadius = 12
        hideButton.translatesAutoresizingMaskIntoConstraints = false
        hideButton.addTarget(self, action: #selector(hideTapped), for: .touchUpInside)
        panel.addSubview(hideButton)

        NSLayoutConstraint.activate([
            // 胶囊：左上角安全区内
            pill.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            pill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            pill.widthAnchor.constraint(equalToConstant: 96),
            pill.heightAnchor.constraint(equalToConstant: 32),
            pillDot.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            pillDot.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            pillDot.widthAnchor.constraint(equalToConstant: 8),
            pillDot.heightAnchor.constraint(equalToConstant: 8),
            pillLabel.leadingAnchor.constraint(equalTo: pillDot.trailingAnchor, constant: 8),
            pillLabel.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            // 展开面板铺满
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 24),
            titleLabel.topAnchor.constraint(equalTo: panel.safeAreaLayoutGuide.topAnchor, constant: 34),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -24),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            logView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            logView.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -24),
            logView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 18),
            logView.heightAnchor.constraint(equalToConstant: 240),
            collapseButton.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            collapseButton.topAnchor.constraint(equalTo: logView.bottomAnchor, constant: 24),
            collapseButton.widthAnchor.constraint(equalToConstant: 280),
            collapseButton.heightAnchor.constraint(equalToConstant: 46),
            hideButton.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            hideButton.topAnchor.constraint(equalTo: collapseButton.bottomAnchor, constant: 14),
            hideButton.widthAnchor.constraint(equalToConstant: 280),
            hideButton.heightAnchor.constraint(equalToConstant: 46)
        ])

        VolumeControl.shared.attach(to: panel)

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        setExpanded(false)
        Log.add("Bridge 已启动（小圆点模式，8 秒后自动回后台）")
        scheduleAutoHide(8)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    // MARK: 收起 / 展开
    private func setExpanded(_ e: Bool) {
        expanded = e
        panel.isHidden = !e
        pill.isHidden = e
        if let root = view as? PassthroughView {
            root.backgroundColor = .clear
            root.hotspot = e ? nil : pill.frame
        }
    }

    @objc private func appDidBecomeActive() {
        // 展开面板时不要自动隐藏；小圆点模式 8 秒后回后台
        if !expanded { scheduleAutoHide(8) }
    }

    private func scheduleAutoHide(_ seconds: Int) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
            guard let self = self, !self.expanded else { return }
            Log.add("自动隐藏到后台")
            self.hideToBackground()
        }
    }

    private func hideToBackground() {
        DispatchQueue.main.async {
            // 私有方法 suspend()（等同按 Home 回主屏）；不能 #selector（iOS SDK 无 NSXPCConnection）
            UIApplication.shared.perform(Selector(("suspend")))
        }
    }

    @objc private func pillTapped() {
        hideTimer?.invalidate()
        setExpanded(true)
    }

    @objc private func collapseTapped() {
        setExpanded(false)
        scheduleAutoHide(8)
    }

    @objc private func hideTapped() {
        hideTimer?.invalidate()
        Log.add("手动隐藏到后台")
        hideToBackground()
    }

    private func refresh() {
        let v = UIDevice.current
        let port = HTTPServer.shared.port
        statusLabel.text = """
        服务   \(HTTPServer.shared.running ? "运行中" : "未启动")  127.0.0.1:\(port)
        设备   \(v.name)  \(v.model)  iOS \(v.systemVersion)
        剪贴板 \(UIPasteboard.general.changeCount) 次变更
        模式   \(expanded ? "面板展开" : "小圆点（屏幕不被遮挡）")
        提示   保持本 App 在前台运行，勿上滑杀掉
        点击  电脑端点按由本 App 注入系统（前台时有效）
        """
        logView.text = Log.lines.suffix(40).joined(separator: "\n")
        if !logView.text.isEmpty {
            logView.scrollRangeToVisible(NSRange(location: logView.text.count - 1, length: 1))
        }
    }
}
