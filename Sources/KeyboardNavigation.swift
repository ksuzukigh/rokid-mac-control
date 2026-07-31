import Foundation

enum KeyboardFocusPolicy {
    /// Rokid Control自身が前面なら、終了済みの映像受信プロセスをイベントの
    /// 送信先としてmacOSが一時的に返しても、Rokid用キーを受け付ける。
    static func accepts(
        appIsActive: Bool,
        modalPresented: Bool,
        targetBelongsToRokidControl: Bool
    ) -> Bool {
        !modalPresented
            && (appIsActive || targetBelongsToRokidControl)
    }
}

enum LauncherActivityPolicy {
    static let launcherPackage = "com.rokid.os.sprite.launcher"

    static func isLauncherForeground(_ output: String) -> Bool {
        output
            .split(whereSeparator: \.isNewline)
            .contains { line in
                let value = line.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                let isCurrentActivity =
                    value.contains("topResumedActivity=")
                    || value.hasPrefix("mResumedActivity:")
                    || value.hasPrefix("ResumedActivity:")
                return isCurrentActivity
                    && value.contains("\(launcherPackage)/")
            }
    }
}

/// Rokidホーム画面の下段アイコン。
///
/// 矢印キーで移動する「選択リング」の対象ではない。`M` / `H` / `A` の
/// ショートカットが直接タップする座標としてだけ使う。
enum LauncherShortcut: Int, CaseIterable {
    case memo
    case home
    case applications

    var title: String {
        switch self {
        case .memo:
            return "メモ"
        case .home:
            return "Home"
        case .applications:
            return "アプリ一覧"
        }
    }

    func horizontalOffset(for screenWidth: Int) -> Int {
        (rawValue - LauncherShortcut.home.rawValue)
            * (screenWidth / 15)
    }

    /// Home画面の下段アイコン位置（Rokidの座標系、左上が原点）。
    func devicePoint(forScreenWidth width: Int, height: Int) -> CGPoint {
        CGPoint(
            x: CGFloat(width) / 2 + CGFloat(horizontalOffset(for: width)),
            y: CGFloat(height) / 2
        )
    }
}

/// `A`でアプリ一覧を開いてから続く、左右キーとEnterが有効な状態。
///
/// 当初は8秒で自動的に切る設計だったが、実機で試すと、アプリを開いて`Esc`で
/// 一覧へ戻ったときに矢印が死んでしまい使いものにならなかった。そのため
/// 時間切れと`Enter`・`Esc`による終了はやめ、`H`・`M`・マウス操作という
/// 「別のことを始めた」と分かる操作でだけ終える。
struct AppSelectionState {
    private(set) var isActive = false

    /// `A`でアプリ一覧を開いた直後に呼ぶ。
    mutating func begin() {
        isActive = true
    }

    /// 選択状態を終了する。終了前に有効だった場合だけ`true`を返す。
    @discardableResult
    mutating func end() -> Bool {
        let wasActive = isActive
        isActive = false
        return wasActive
    }
}

/// Mac画面へ常時表示する操作案内。
///
/// 通常時はRokidの下段アイコンと同じ順で並べる。アプリ一覧を選んでいる間だけ
/// 左右キーの案内へ切り替える。キー割り当て自体は変わらない。
enum NavigationGuide {
    static let standard = "M  メモ　　H  Home　　A  アプリ"
    static let appSelection = "← →  選択　　Enter  決定　　Esc  戻る"

    static func text(isSelectingApp: Bool) -> String {
        isSelectingApp ? appSelection : standard
    }
}
