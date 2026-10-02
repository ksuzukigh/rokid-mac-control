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
                    || value.hasPrefix("mFocusedApp=ActivityRecord{")
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

    /// 純正ランチャーの実際の下段領域を3分割して押す。
    func devicePoint(in indicator: CGRect) -> CGPoint {
        CGPoint(
            x: indicator.midX + CGFloat(rawValue - LauncherShortcut.home.rawValue)
                * indicator.width / 3,
            y: indicator.midY
        )
    }
}

enum LauncherIndicatorLocator {
    static func bounds(in xml: String, width: Int, height: Int) -> CGRect? {
        guard !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY") else { return nil }
        let delegate = IndicatorParser(width: width, height: height)
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.matches.count == 1 else { return nil }
        return delegate.matches[0]
    }

    private final class IndicatorParser: NSObject, XMLParserDelegate {
        let width: Int
        let height: Int
        var matches: [CGRect] = []
        init(width: Int, height: Int) { self.width = width; self.height = height }

        func parser(
            _ parser: XMLParser, didStartElement name: String,
            namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String]
        ) {
            guard name == "node",
                  attributes["package"] == LauncherActivityPolicy.launcherPackage,
                  attributes["resource-id"] == "\(LauncherActivityPolicy.launcherPackage):id/indicator",
                  attributes["enabled"] == "true", attributes["clickable"] == "true",
                  let bounds = attributes["bounds"],
                  let regex = try? NSRegularExpression(pattern: #"^\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]$"#),
                  let match = regex.firstMatch(in: bounds, range: NSRange(bounds.startIndex..., in: bounds))
            else { return }
            let numbers = (1...4).compactMap { index -> Int? in
                guard let range = Range(match.range(at: index), in: bounds) else { return nil }
                return Int(bounds[range])
            }
            guard numbers.count == 4, numbers[0] < numbers[2], numbers[1] < numbers[3],
                  numbers[2] <= width, numbers[3] <= height else { return }
            matches.append(CGRect(
                x: CGFloat(numbers[0]), y: CGFloat(numbers[1]),
                width: CGFloat(numbers[2] - numbers[0]), height: CGFloat(numbers[3] - numbers[1])
            ))
        }
    }
}

enum NavigationGuideLayout {
    /// Quartz座標。映像ウインドウの外へ置き、場所がなければ重ねずに隠す。
    static func frame(window: CGRect, visibleScreen: CGRect, height: CGFloat = 34) -> CGRect? {
        let width = min(max(window.width - 24, 160), 460)
        let x = min(max(window.midX - width / 2, visibleScreen.minX), visibleScreen.maxX - width)
        let candidates = [
            CGRect(x: x, y: window.maxY + 8, width: width, height: height),
            CGRect(x: x, y: window.minY - 8 - height, width: width, height: height),
        ]
        return candidates.first { visibleScreen.contains($0) && !$0.intersects(window) }
    }
}

/// `A`でアプリ一覧を開いてから続く、左右キーとEnterが有効な状態。
///
/// 当初は8秒で自動的に切る設計だったが、実機で試すと、アプリを開いて`Esc`で
/// 一覧へ戻ったときに矢印が死んでしまい使いものにならなかった。そのため
/// 時間切れと`Enter`・`Esc`による終了はやめ、`H`・`M`という
/// 「別の場所を開いた」と分かる操作でだけ終える。Macの別アプリから戻るため
/// Rokid画面をクリックしても、Rokid側の一覧は閉じないため選択を維持する。
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
