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
        testKeyboardFocusPolicy()
        testScrcpyWindowPolicy()
        testLauncherActivityPolicy()
        testShortcutCoordinates()
        testGuideDoesNotCoverVideo()
        testDirectShortcuts()
        testLeftRightAndEnterRequireAppList()
        testEscapeAlwaysSendsBack()
        testSelectionSurvivesEnterAndEscape()
        testSelectionSurvivesFocusClick()
        testSelectionEndsOnHomeAndMemo()
        testRecoversAfterFailedCommand()
        testGuideText()
        testSystemAdjustmentScope()
        print("Keyboard navigation self-test passed")
    }

    private static func testSystemAdjustmentScope() {
        for activity in SystemAdjustmentPolicy.activities {
            for component in ["\(SystemAdjustmentPolicy.package)/\(activity)",
                              "\(SystemAdjustmentPolicy.package)/\(SystemAdjustmentPolicy.package)\(activity)"] {
                precondition(SystemAdjustmentPolicy.isForeground("topResumedActivity=ActivityRecord{123 u0 \(component) t42}"))
                precondition(!SystemAdjustmentPolicy.isForeground("Hist #0: ActivityRecord{123 u0 \(component) t42}"))
                precondition(!SystemAdjustmentPolicy.isForeground("topResumedActivity=ActivityRecord{123 u0 \(component)Extra t42}"))
            }
        }
        precondition(!SystemAdjustmentPolicy.isForeground("ResumedActivity: ActivityRecord{123 u0 com.rokid.os.sprite.launcher/.main.SpriteMainActivity t42}"))
        precondition(!SystemAdjustmentPolicy.isForeground("ResumedActivity: ActivityRecord{123 u0 other.app/.page.volume.SettingVolumeActivity t42}"))
    }

    private static func testKeyboardFocusPolicy() {
        precondition(
            KeyboardFocusPolicy.accepts(
                appIsActive: true,
                modalPresented: false,
                targetBelongsToRokidControl: false
            )
        )
        precondition(
            KeyboardFocusPolicy.accepts(
                appIsActive: false,
                modalPresented: false,
                targetBelongsToRokidControl: true
            )
        )
        precondition(
            !KeyboardFocusPolicy.accepts(
                appIsActive: true,
                modalPresented: true,
                targetBelongsToRokidControl: true
            )
        )
        precondition(
            !KeyboardFocusPolicy.accepts(
                appIsActive: false,
                modalPresented: false,
                targetBelongsToRokidControl: false
            )
        )
    }

    private static func testScrcpyWindowPolicy() {
        let smallHelper = ScrcpyWindowCandidate(
            bounds: CGRect(x: 15, y: 70, width: 220, height: 34),
            layer: 0,
            alpha: 1
        )
        let mainWindow = ScrcpyWindowCandidate(
            bounds: CGRect(x: 86, y: 27, width: 480, height: 672),
            layer: 0,
            alpha: 1
        )
        let overlay = ScrcpyWindowCandidate(
            bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            layer: 1,
            alpha: 1
        )

        precondition(
            ScrcpyWindowPolicy.bestBounds(
                from: [smallHelper, overlay, mainWindow]
            ) == mainWindow.bounds,
            "補助ウインドウではなくscrcpy画面本体を選べていない"
        )
    }

    private static func testLauncherActivityPolicy() {
        precondition(
            LauncherActivityPolicy.isLauncherForeground(
                """
                topResumedActivity=ActivityRecord{123 u0 \
                com.rokid.os.sprite.launcher/.main.SpriteMainActivity t42}
                """
            )
        )
        precondition(LauncherActivityPolicy.isLauncherForeground(
            "mFocusedApp=ActivityRecord{123 u0 com.rokid.os.sprite.launcher/.main.SpriteMainActivity t42}"
        ))
        precondition(
            !LauncherActivityPolicy.isLauncherForeground(
                """
                topResumedActivity=ActivityRecord{123 u0 \
                com.rokid.os.sprite.assistserver/\
                com.rokid.os.sprite.assist.media.page.CameraActivity t42}
                Hist #1: ActivityRecord{456 u0 \
                com.rokid.os.sprite.launcher/.main.SpriteMainActivity t41}
                """
            )
        )
    }

    // MARK: - 座標

    /// 新旧のYodaOS配置で現在の領域だけを押し、別のアプリの領域は使わない。
    private static func testShortcutCoordinates() {
        func xml(_ bounds: String, package: String = LauncherActivityPolicy.launcherPackage) -> String {
            "<hierarchy><node package=\"\(package)\" resource-id=\"\(package):id/indicator\" enabled=\"true\" clickable=\"true\" bounds=\"\(bounds)\"/></hierarchy>"
        }
        for (value, y) in [("[196,318][284,342]", CGFloat(330)), ("[196,478][284,502]", CGFloat(490))] {
            guard let bounds = LauncherIndicatorLocator.bounds(in: xml(value), width: 480, height: 640)
            else { preconditionFailure("RV101の配置を読み取れない") }
            let home = LauncherShortcut.home.devicePoint(in: bounds)
            precondition(home.x == 240 && home.y == y)
            let memo = LauncherShortcut.memo.devicePoint(in: bounds)
            let apps = LauncherShortcut.applications.devicePoint(in: bounds)
            precondition(bounds.contains(memo) && bounds.contains(apps))
            precondition(memo.x < home.x && apps.x > home.x)
        }
        precondition(LauncherIndicatorLocator.bounds(in: xml("[196,318][284,342]", package: "other.app"), width: 480, height: 640) == nil)
        precondition(LauncherIndicatorLocator.bounds(in: xml("[196,318][999,342]"), width: 480, height: 640) == nil)
        precondition(LauncherIndicatorLocator.bounds(in: "<hierarchy>", width: 480, height: 640) == nil)
        let duplicate = xml("[196,318][284,342]").replacingOccurrences(of: "</hierarchy>", with: "<node package=\"com.rokid.os.sprite.launcher\" resource-id=\"com.rokid.os.sprite.launcher:id/indicator\" enabled=\"true\" clickable=\"true\" bounds=\"[196,478][284,502]\"/></hierarchy>")
        precondition(LauncherIndicatorLocator.bounds(in: duplicate, width: 480, height: 640) == nil)
    }

    private static func testGuideDoesNotCoverVideo() {
        let screen = CGRect(x: 0, y: 24, width: 1920, height: 1032)
        for window in [
            CGRect(x: 300, y: 100, width: 480, height: 670),
            CGRect(x: 300, y: 386, width: 480, height: 670),
            CGRect(x: -20, y: 100, width: 240, height: 360),
        ] {
            guard let guide = NavigationGuideLayout.frame(window: window, visibleScreen: screen)
            else { preconditionFailure("画面外に置ける案内を生成できない") }
            precondition(screen.contains(guide))
            precondition(!guide.intersects(window))
        }
        precondition(NavigationGuideLayout.frame(window: screen, visibleScreen: screen) == nil)
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

        precondition(router.handle(.left))
        precondition(router.handle(.right))
        precondition(!router.handle(.enter))
        precondition(sink.drain() == [
            .adjustSettingIfForeground("KEYCODE_DPAD_LEFT"),
            .adjustSettingIfForeground("KEYCODE_DPAD_RIGHT"),
        ])

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

        // H・Mで終えたあとは、もう送らない。
        router.handle(.home)
        _ = sink.drain()
        router.handle(.left)
        router.handle(.enter)
        precondition(sink.drain() == [.adjustSettingIfForeground("KEYCODE_DPAD_LEFT")])
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

    /// Macの別アプリから戻るクリックでは、一覧と左右キーを維持する。
    private static func testSelectionSurvivesFocusClick() {
        let sink = MockCommandSink()
        let router = KeyboardCommandRouter(sink: sink)

        router.handle(.applications)
        _ = sink.drain()
        router.focusWindow()

        precondition(router.isSelectingApp, "フォーカスクリックで選択状態が切れている")
        router.handle(.right)
        precondition(
            sink.drain() == [.keyEvent("KEYCODE_DPAD_RIGHT")],
            "フォーカスを戻したあとに左右キーが送られない"
        )
    }

    /// H・Mでだけ、選択案内から通常案内へ戻る。
    private static func testSelectionEndsOnHomeAndMemo() {
        for ending in ["home", "memo"] {
            let sink = MockCommandSink()
            let router = KeyboardCommandRouter(sink: sink)
            var guideStates: [Bool] = []
            router.onSelectionChanged = { guideStates.append($0) }

            router.handle(.applications)
            precondition(guideStates == [true], "\(ending): 選択案内へ切り替わらない")

            switch ending {
            case "home":
                router.handle(.home)
            default:
                router.handle(.memo)
            }

            precondition(
                guideStates == [true, false],
                "\(ending): 通常案内へ戻らない"
            )
            precondition(!router.isSelectingApp)

            // 終えたあとの左右キーは送らない。
            _ = sink.drain()
            router.handle(.right)
            precondition(sink.drain() == [.adjustSettingIfForeground("KEYCODE_DPAD_RIGHT")], "\(ending): 終了後に無条件の矢印を送っている")
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
