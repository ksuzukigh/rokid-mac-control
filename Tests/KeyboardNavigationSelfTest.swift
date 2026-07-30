import Foundation

/// ADBの代わりに命令を記録するだけの模擬送信先。
///
/// `failingCalls`に指定した回数目の送信を「失敗」として扱い、
/// 失敗の直後でも次のキーを処理できることを確かめられるようにする。
private final class MockCommandSink: RokidCommandSink {
    private(set) var commands: [RokidCommand] = []
    private(set) var failedCount = 0
    var failingCalls: Set<Int> = []
    private var callIndex = 0

    func send(_ command: RokidCommand) {
        callIndex += 1
        if failingCalls.contains(callIndex) {
            // 実機のADBはエラーを投げずに失敗するため、記録だけして戻る。
            failedCount += 1
            return
        }
        commands.append(command)
    }

    func drain() -> [RokidCommand] {
        let result = commands
        commands = []
        return result
    }
}

@main
enum KeyboardNavigationSelfTest {
    static func main() {
        testShortcutCoordinates()
        testDirectShortcuts()
        testLeftRightAndEnterRequireAppList()
        testEscapeAlwaysSendsBack()
        testSelectionSurvivesEnterAndEscape()
        testSelectionEndsOnHomeMemoAndMouse()
        testRecoversAfterFailedCommand()
        testGuideText()
        print("Keyboard navigation self-test passed")
    }

    // MARK: - 座標

    /// Hは480×640で中央Home座標240,320をタップする。
    private static func testShortcutCoordinates() {
        precondition(
            LauncherShortcut.memo.horizontalOffset(for: 480) == -32
        )
        precondition(
            LauncherShortcut.home.horizontalOffset(for: 480) == 0
        )
        precondition(
            LauncherShortcut.applications.horizontalOffset(for: 480) == 32
        )
        let home = LauncherShortcut.home.devicePoint(
            forScreenWidth: 480,
            height: 640
        )
        precondition(home.x == 240 && home.y == 320)

        let memo = LauncherShortcut.memo.devicePoint(
            forScreenWidth: 480,
            height: 640
        )
        precondition(memo.x == 208 && memo.y == 320)

        let apps = LauncherShortcut.applications.devicePoint(
            forScreenWidth: 480,
            height: 640
        )
        precondition(apps.x == 272 && apps.y == 320)
    }

    // MARK: - H / M / A

    /// H・M・Aはどの画面からでも、1回のキー入力でそれぞれの項目だけを開く。
    private static func testDirectShortcuts() {
        let sink = MockCommandSink()
        let router = KeyboardCommandRouter(sink: sink)

        router.handle(.home)
        precondition(sink.drain() == [.openShortcut(.home)])

        router.handle(.memo)
        precondition(sink.drain() == [.openShortcut(.memo)])

        router.handle(.applications)
        precondition(sink.drain() == [.openShortcut(.applications)])
        precondition(router.isSelectingApp)

        // Hを10回繰り返してもHome以外は開かない。
        let repeated = MockCommandSink()
        let repeatedRouter = KeyboardCommandRouter(sink: repeated)
        for _ in 0..<10 {
            repeatedRouter.handle(.home)
        }
        precondition(
            repeated.drain() == Array(
                repeating: RokidCommand.openShortcut(.home),
                count: 10
            )
        )
    }

    // MARK: - 左右キーとEnter

    /// Aを押す前の左右キーとEnterはADBへ送らない。Aの後だけ送る。
    private static func testLeftRightAndEnterRequireAppList() {
        let sink = MockCommandSink()
        let router = KeyboardCommandRouter(sink: sink)

        for key in [RokidKey.left, .right, .enter] {
            precondition(router.handle(key) == false)
        }
        precondition(sink.drain().isEmpty)

        router.handle(.applications)
        precondition(sink.drain() == [.openShortcut(.applications)])

        router.handle(.left)
        router.handle(.right)
        precondition(
            sink.drain() == [
                .keyEvent("KEYCODE_DPAD_LEFT"),
                .keyEvent("KEYCODE_DPAD_RIGHT"),
            ]
        )

        // H・M・マウス操作で終えたあとは、もう送らない。
        router.endSelection()
        router.handle(.left)
        router.handle(.enter)
        precondition(sink.drain().isEmpty)
    }

    // MARK: - Esc

    /// Escは選択状態の有無にかかわらずBackを送る。
    private static func testEscapeAlwaysSendsBack() {
        let sink = MockCommandSink()
        let router = KeyboardCommandRouter(sink: sink)

        router.handle(.escape)
        precondition(sink.drain() == [.keyEvent("KEYCODE_BACK")])

        router.handle(.applications)
        _ = sink.drain()
        precondition(router.isSelectingApp)

        router.handle(.escape)
        precondition(sink.drain() == [.keyEvent("KEYCODE_BACK")])
    }

    // MARK: - 選択状態の継続と終了

    /// アプリを開いてEscで一覧へ戻っても、左右キーがそのまま使える。
    ///
    /// 8秒で自動的に切る設計は実機で使いものにならなかったため、
    /// EnterでもEscでも時間経過でも選択状態を終えない。
    private static func testSelectionSurvivesEnterAndEscape() {
        let sink = MockCommandSink()
        let router = KeyboardCommandRouter(sink: sink)

        router.handle(.applications)
        router.handle(.right)
        router.handle(.enter)
        _ = sink.drain()
        precondition(router.isSelectingApp, "Enterで選択状態が切れている")

        // アプリの中でEscを押して一覧へ戻る。
        router.handle(.escape)
        precondition(sink.drain() == [.keyEvent("KEYCODE_BACK")])
        precondition(router.isSelectingApp, "Escで選択状態が切れている")

        // 戻ったあとも左右キーとEnterがそのまま効く。
        router.handle(.left)
        router.handle(.enter)
        precondition(
            sink.drain() == [
                .keyEvent("KEYCODE_DPAD_LEFT"),
                .keyEvent("KEYCODE_ENTER"),
            ]
        )
    }

    /// H・M・マウス操作でだけ、選択案内から通常案内へ戻る。
    private static func testSelectionEndsOnHomeMemoAndMouse() {
        for ending in ["home", "memo", "mouse"] {
            let sink = MockCommandSink()
            let router = KeyboardCommandRouter(sink: sink)
            var guideStates: [Bool] = []
            router.onSelectionChanged = { guideStates.append($0) }

            router.handle(.applications)
            precondition(guideStates == [true], "\(ending): 選択案内へ切り替わらない")

            switch ending {
            case "home":
                router.handle(.home)
            case "memo":
                router.handle(.memo)
            default:
                router.endSelection()
            }

            precondition(
                guideStates == [true, false],
                "\(ending): 通常案内へ戻らない"
            )
            precondition(!router.isSelectingApp)

            // 終えたあとの左右キーは送らない。
            _ = sink.drain()
            router.handle(.right)
            precondition(sink.drain().isEmpty, "\(ending): 終了後に矢印を送っている")
        }
    }

    // MARK: - 失敗からの復帰

    /// 1回の入力失敗後も、次のキーをそのまま処理する。
    private static func testRecoversAfterFailedCommand() {
        let sink = MockCommandSink()
        sink.failingCalls = [1]
        let router = KeyboardCommandRouter(sink: sink)

        router.handle(.home)
        precondition(sink.failedCount == 1)
        precondition(sink.drain().isEmpty)

        router.handle(.memo)
        router.handle(.applications)
        router.handle(.left)
        precondition(
            sink.drain() == [
                .openShortcut(.memo),
                .openShortcut(.applications),
                .keyEvent("KEYCODE_DPAD_LEFT"),
            ]
        )
    }

    // MARK: - 案内文

    private static func testGuideText() {
        precondition(
            NavigationGuide.text(isSelectingApp: false)
                == NavigationGuide.standard
        )
        precondition(
            NavigationGuide.text(isSelectingApp: true)
                == NavigationGuide.appSelection
        )
        // Rokidの下段アイコンと同じ順（メモ→Home→アプリ）で並べる。
        let standard = NavigationGuide.standard
        guard
            let memo = standard.range(of: "メモ"),
            let home = standard.range(of: "Home"),
            let apps = standard.range(of: "アプリ")
        else {
            preconditionFailure("通常案内に3項目がそろっていない")
        }
        precondition(memo.lowerBound < home.lowerBound)
        precondition(home.lowerBound < apps.lowerBound)
    }

}
