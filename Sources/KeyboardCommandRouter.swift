import Foundation

/// キーボード操作の結果としてRokidへ送る命令。
enum RokidCommand: Equatable {
    /// `input keyevent <name>` を送る。
    case keyEvent(String)
    /// ウェイク→Home のあとに下段アイコンをタップする。
    case openShortcut(LauncherShortcut)
}

/// Rokidへ命令を届ける相手。実機ではADB、自動試験では模擬実装を差し込む。
protocol RokidCommandSink: AnyObject {
    func send(_ command: RokidCommand)
}

/// Macで押されたキーのうち、Rokid操作に関係するものだけを表す。
///
/// OSの仮想キーコードはここに持ち込まない。キーコードの読み取りは
/// `KeyboardController`、意味づけはこの層、という分担にする。
enum RokidKey: Equatable {
    case left
    case right
    case up
    case down
    case enter
    case escape
    case home
    case memo
    case applications
}

/// キー入力を「Rokidへの命令」と「画面の案内表示」へ振り分ける。
///
/// OSイベント監視から切り離してあるため、模擬の`RokidCommandSink`を
/// 差し込むだけで、キー操作の並びを自動試験できる。
final class KeyboardCommandRouter {
    private let sink: RokidCommandSink
    private var selection = AppSelectionState()

    /// 案内表示の切り替え通知。`true`はアプリ一覧を選んでいる間。
    var onSelectionChanged: ((Bool) -> Void)?

    init(sink: RokidCommandSink) {
        self.sink = sink
    }

    var isSelectingApp: Bool {
        selection.isActive
    }

    /// キー入力を処理する。Rokidへ命令を送ったときだけ`true`を返す。
    ///
    /// 戻り値は「ADBへ送ったか」であって「キーを横取りしたか」ではない。
    /// 横取りの判断は`KeyboardController`が行う。
    @discardableResult
    func handle(_ key: RokidKey) -> Bool {
        let wasSelecting = selection.isActive
        defer { publishSelectionChange(from: wasSelecting) }

        switch key {
        case .home:
            selection.end()
            sink.send(.openShortcut(.home))
            return true

        case .memo:
            selection.end()
            sink.send(.openShortcut(.memo))
            return true

        case .applications:
            sink.send(.openShortcut(.applications))
            selection.begin()
            return true

        case .left, .right, .up, .down:
            // アプリ一覧を開いてからだけ方向キーとして送る。それ以前は
            // Rokid側の選択状態と食い違うため、ADBへ送らない。
            guard selection.isActive else { return false }
            sink.send(.keyEvent(Self.androidKey(for: key)))
            return true

        case .enter:
            // Enterでは選択状態を終えない。アプリを開いてEscで一覧へ戻った
            // ときに、そのまま矢印で選び直せるようにするため。
            guard selection.isActive else { return false }
            sink.send(.keyEvent("KEYCODE_ENTER"))
            return true

        case .escape:
            // Escは選択状態の有無にかかわらず、常に一つ戻る。
            // 一覧へ戻る操作でもあるため、選択状態は終えない。
            sink.send(.keyEvent("KEYCODE_BACK"))
            return true
        }
    }

    /// マウス操作など、キー以外の理由で選択状態を終える。
    func endSelection() {
        let wasSelecting = selection.isActive
        selection.end()
        publishSelectionChange(from: wasSelecting)
    }

    private func publishSelectionChange(from wasSelecting: Bool) {
        guard selection.isActive != wasSelecting else { return }
        onSelectionChanged?(selection.isActive)
    }

    private static func androidKey(for key: RokidKey) -> String {
        switch key {
        case .left:
            return "KEYCODE_DPAD_LEFT"
        case .right:
            return "KEYCODE_DPAD_RIGHT"
        case .up:
            return "KEYCODE_DPAD_UP"
        case .down:
            return "KEYCODE_DPAD_DOWN"
        case .enter:
            return "KEYCODE_ENTER"
        case .escape:
            return "KEYCODE_BACK"
        case .home, .memo, .applications:
            return ""
        }
    }
}
