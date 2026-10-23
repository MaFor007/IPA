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

// MARK: - 隐藏到后台（私有 suspend，TrollStore 环境可用；保活音频维持后台运行）
func hideToBackground() {
    DispatchQueue.main.async {
        UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
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

// MARK: - 后台保活（静音音频循环）
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

// MARK: - 界面
final class BridgeViewController: UIViewController {
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let logView = UITextView()
    private let hideButton = UIButton(type: .system)
    private let countdownLabel = UILabel()
    private var timer: Timer?
    private var hideTimer: Timer?
    private var hideCountdown = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1)

        let grad = CAGradientLayer()
        grad.frame = view.bounds
        grad.colors = [UIColor(red: 0.11, green: 0.14, blue: 0.22, alpha: 1).cgColor,
                       UIColor(red: 0.04, green: 0.06, blue: 0.09, alpha: 1).cgColor]
        grad.startPoint = CGPoint(x: 0, y: 0)
        grad.endPoint = CGPoint(x: 1, y: 1)
        view.layer.insertSublayer(grad, at: 0)

        titleLabel.text = "iPhone Bridge"
        titleLabel.font = UIFont.systemFont(ofSize: 30, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        statusLabel.numberOfLines = 0
        statusLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = UIColor(red: 0.55, green: 0.76, blue: 1.0, alpha: 1)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        logView.backgroundColor = UIColor(white: 1, alpha: 0.04)
        logView.layer.cornerRadius = 14
        logView.textColor = UIColor(white: 0.7, alpha: 1)
        logView.font = UIFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        logView.isEditable = false
        logView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(logView)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 34),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            logView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            logView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            logView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 18),
            logView.heightAnchor.constraint(equalToConstant: 240)
        ])

        VolumeControl.shared.attach(to: view)

        // 隐藏按钮 + 倒计时提示
        hideButton.setTitle("隐藏到后台（回主屏）", for: .normal)
        hideButton.setTitleColor(.white, for: .normal)
        hideButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        hideButton.backgroundColor = UIColor(red: 0.16, green: 0.36, blue: 0.85, alpha: 1)
        hideButton.layer.cornerRadius = 12
        hideButton.translatesAutoresizingMaskIntoConstraints = false
        hideButton.addTarget(self, action: #selector(hideTapped), for: .touchUpInside)
        view.addSubview(hideButton)

        countdownLabel.font = UIFont.systemFont(ofSize: 12)
        countdownLabel.textColor = UIColor(white: 0.55, alpha: 1)
        countdownLabel.textAlignment = .center
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(countdownLabel)

        NSLayoutConstraint.activate([
            hideButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hideButton.topAnchor.constraint(equalTo: logView.bottomAnchor, constant: 24),
            hideButton.widthAnchor.constraint(equalToConstant: 220),
            hideButton.heightAnchor.constraint(equalToConstant: 46),
            countdownLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            countdownLabel.topAnchor.constraint(equalTo: hideButton.bottomAnchor, constant: 12)
        ])

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        // 每次激活 8 秒后自动隐藏到后台（电脑远程拉起后也自动回主屏，
        // 避免 Bridge 界面挡在屏幕前导致点击“没反应”）
        scheduleAutoHide(8)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func appDidBecomeActive() {
        scheduleAutoHide(8)
    }

    private func scheduleAutoHide(_ seconds: Int) {
        hideTimer?.invalidate()
        hideCountdown = seconds
        updateCountdown()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            self.hideCountdown -= 1
            self.updateCountdown()
            if self.hideCountdown <= 0 {
                t.invalidate()
                Log.add("自动隐藏到后台")
                hideToBackground()
            }
        }
    }

    private func updateCountdown() {
        countdownLabel.text = hideCountdown > 0 ? "\(hideCountdown) 秒后自动隐藏（后台继续服务）" : ""
    }

    @objc private func hideTapped() {
        Log.add("手动隐藏到后台")
        hideToBackground()
    }
    }

    private func refresh() {
        let v = UIDevice.current
        let port = HTTPServer.shared.port
        statusLabel.text = """
        服务   \(HTTPServer.shared.running ? "运行中" : "未启动")  127.0.0.1:\(port)
        设备   \(v.name)  \(v.model)  iOS \(v.systemVersion)
        剪贴板 \(UIPasteboard.general.changeCount) 次变更
        提示   保持本 App 在后台即可，勿上滑杀掉
        点击  电脑端点按由本 App 注入系统，无需回到本界面
        """
        logView.text = Log.lines.suffix(40).joined(separator: "\n")
        if !logView.text.isEmpty {
            logView.scrollRangeToVisible(NSRange(location: logView.text.count - 1, length: 1))
        }
    }
}
