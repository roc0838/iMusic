import Foundation

enum IOSUITestMode {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static let isEnabled = arguments.contains("-imusic-ui-testing")
    static let hasPlayerFixture = isEnabled && arguments.contains("-imusic-ui-player-fixture")
    /// Opens the player by itself a few seconds after launch, so a UI test
    /// can sample the screen continuously through the opening transition
    /// (an XCUITest tap waits for the app to go idle, i.e. until it is over).
    static let autoOpensPlayer = hasPlayerFixture && arguments.contains("-imusic-ui-auto-open-player")
}

#if os(iOS)

/// Starts optional account and source warm-ups without putting a launch page
/// over the library. The home screen owns its own stale-while-revalidate load.
@MainActor
final class IOSStartupCoordinator {
    static let shared = IOSStartupCoordinator()

    private var didStart = false
    private var preloadTasks: [Task<Void, Never>] = []

    private init() {}

    func start(
        player: PlayerService,
        account: AccountStore
    ) {
        guard !didStart else { return }
        didStart = true
        DiagnosticLogger.shared.info("startup.start 开始", category: "launch")

        LegacyBackgroundCleanup.clear()
        DiagnosticLogger.shared.info("LegacyBackgroundCleanup 完成，准备 player.startRuntime", category: "launch")
        player.startRuntime()
        DiagnosticLogger.shared.info("player.startRuntime 完成", category: "launch")

        guard !IOSUITestMode.isEnabled else { return }

        // Deliberately do NOT call LXUserAPIService.ensureSelectedSourceLoaded()
        // here. Evaluating user-supplied JavaScript on the main actor while the
        // scene is launching can trap (or trip the watchdog) and makes every
        // subsequent interaction look like a crash. Playback calls activate()
        // on first use and loads the script on demand.
        DiagnosticLogger.shared.info("启动期不执行用户音源脚本，改为首次播放/测试时按需加载", category: "launch")

        // These tasks do not gate the first frame or navigation. Network and
        // source initialization continue while the native home page is usable.
        preloadTasks.append(Task { @MainActor in
            DiagnosticLogger.shared.info("account.bootstrap 开始", category: "startup")
            await account.bootstrap()
            DiagnosticLogger.shared.info("account.bootstrap 完成", category: "startup")
        })
        preloadTasks.append(Task { @MainActor in
            DiagnosticLogger.shared.info("MusicSessionRefreshCoordinator 开始", category: "startup")
            await MusicSessionRefreshCoordinator.shared.refreshIfNeeded()
            DiagnosticLogger.shared.info("MusicSessionRefreshCoordinator 完成", category: "startup")
        })
    }
}

/// Removes wallpaper data saved by earlier builds now that custom app/player
/// backgrounds have been removed. The file target is resolved only inside the
/// app's own Application Support directory.
private enum LegacyBackgroundCleanup {
    static func clear() {
        let defaults = UserDefaults.standard
        let pathKey = "moumusic.background.path.v1"
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        if let support {
            let directory = support.appendingPathComponent("MoumusicBackground", isDirectory: true)
            let legacyFile = directory.appendingPathComponent("wallpaper.jpg")
            try? FileManager.default.removeItem(at: legacyFile)
            if let remaining = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ), remaining.isEmpty {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        [
            pathKey,
            "moumusic.background.data.v1",
            "moumusic.background.blur.v1",
            "moumusic.background.syncPlayer.v1",
            "moumusic.background.syncApp.v1"
        ].forEach { defaults.removeObject(forKey: $0) }
    }
}

#endif
