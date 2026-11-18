#if os(iOS)
import CommonCrypto
import Combine
import Foundation
import JavaScriptCore
import OSLog
import Security

/// Carries the message of a fatal script error out of `JSContext.exceptionHandler`.
/// JavaScriptCore clears `JSContext.exception` once the handler runs, so the
/// context alone cannot tell us that a script was rejected.
private final class JSScriptErrorBox {
    var message: String?
}

/// iOS counterpart of LX Mobile's QuickJS bridge.  The provider script stays
/// user supplied; this class only implements the LX 2.0 host protocol.
@MainActor
final class LXUserAPIService: ObservableObject {
    private let logger = Logger(subsystem: "com.jiajia2222.imusic.ios", category: "LXSource")
    struct ResolvedURL {
        let url: URL
        let quality: String
        /// Official provider APIs report the tier actually returned. LX User
        /// API scripts only return a URL, so their requested tier is not proof
        /// of the file's codec or bitrate.
        var qualityIsVerified: Bool = true
        /// True when playback is about to reuse a link produced earlier. Those
        /// are the only failures worth re-resolving; a link fetched seconds ago
        /// that will not play points at the provider instead.
        var isFromCache: Bool = false
    }

    struct ResolvedLyrics {
        let lyric: String
        let tlyric: String?
        let rlyric: String?
        let lxlyric: String?
        let yrc: String?
    }

    struct SourceCheckResult: Equatable {
        enum Status: Equatable {
            case available
            case unavailable
            case requiresTrack
        }

        let status: Status
        let message: String
        let detail: String?

        var isAvailable: Bool { status == .available }
        var requiresTrack: Bool { status == .requiresTrack }
    }

    private struct SourceOperationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    static let shared = LXUserAPIService()
    private static let lyricsResolver = LXUserAPIService()
    private static let qualityResolver = LXUserAPIService()
    private static let downloadResolver = LXUserAPIService()
    private static let pluginSearchResolver = LXUserAPIService()

    private let session: URLSession
    private var context: JSContext?
    private var key = ""
    private var loadedID: String?
    private var loadedName: String = ""
    private var loadedScript: String?
    private var tasks: [String: URLSessionDataTask] = [:]
    private var scriptRequestKeys = Set<String>()
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var requestTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var sourceInitializationTask: Task<Void, Never>?
    private var pendingInitializationID: String?
    private var sourceOperationActive = false
    private var sourceOperationWaiters: [SourceOperationWaiter] = []
    private var selectedSourceReloadPending = false
    private var selectedSourceReloadForced = false
    /// A MusicFree plugin uses a different preload but the same native bridge.
    private var loadedKind: LXSourceStore.SourceKind = .lx
    private var mfHTTPTasks: [String: URLSessionDataTask] = [:]
    private var mfTimers: [String: Task<Void, Never>] = [:]
    /// Per-host cookie jar shared by plugins in this resolver instance.
    private var mfCookies: [String: [String]] = [:]
    /// Only the first few timer callbacks are logged; LX sources schedule a
    /// lot of timeouts and writing every one would bury the useful lines.
    private var timeoutDiagnosticCount = 0
    /// "sourceID#platform" → how many slow failures happened in a row. A route
    /// that keeps burning the full probe is demoted for the rest of the
    /// session: shorter probe, tried after the healthy routes. Cleared as soon
    /// as that route answers once.
    private var slowRouteFailures: [String: Int] = [:]
    /// Resolved direct URLs, keyed by source + track + quality. Resolving is
    /// the expensive part of starting a song, and the same answer stays usable
    /// for a while, so both a prefetched track and a repeated one can skip the
    /// provider walk entirely.
    private var resolutionCache: [String: CachedResolution] = [:]
    private var prefetchTask: Task<Void, Never>?
    /// Provider links carry an expiry that is not visible in the URL for every
    /// backend, so the cache stays well inside the shortest observed lifetime
    /// and an expired entry is re-resolved rather than trusted.
    private static let resolutionCacheTTL: TimeInterval = 12 * 60
    @Published private(set) var capabilities: [String: [String]] = [:]
    @Published private(set) var qualityCapabilities: [String: [String]] = [:]
    @Published private(set) var statusMessage = "未加载音源"

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    func loadSelectedSource() {
        guard !sourceOperationActive else {
            selectedSourceReloadPending = true
            selectedSourceReloadForced = true
            return
        }
        load(LXSourceStore.shared.selectedSource)
    }

    static func sourceConfigurationDidChange() {
        [shared, lyricsResolver, qualityResolver, downloadResolver, pluginSearchResolver]
            .forEach { $0.invalidateSourceWork() }
    }

    /// Queries every enabled MusicFree plugin with its `search` method.
    /// Results are deliberately kept in a separate resolver so a search never
    /// replaces the JavaScript context used by active playback or lyrics.
    func musicFreeSearch(keyword: String, page: Int, limit: Int) async -> [Track] {
        let resolver = Self.pluginSearchResolver
        let store = LXSourceStore.shared
        let revision = store.configurationRevision
        let sources = store.musicFreeSources
        guard !sources.isEmpty else { return [] }

        do {
            try await resolver.acquireSourceOperation()
        } catch {
            return []
        }
        defer { resolver.releaseSourceOperation() }

        var collected: [Track] = []
        for source in sources {
            guard !Task.isCancelled,
                  store.configurationRevision == revision,
                  store.playbackSources.contains(where: {
                      $0.id == source.id && $0.script == source.script
                  }) else { break }
            guard await resolver.activate(source) else { continue }
            do {
                let response = try await resolver.requestPlugin(
                    method: "search",
                    args: [keyword, page, "music"]
                )
                guard let envelope = response["result"] as? [String: Any],
                      let items = envelope["data"] as? [[String: Any]] else { continue }
                let platform = (envelope["platform"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
                    ?? source.name
                let tracks = items.compactMap {
                    MusicFreeTrackConverter.track(
                        from: $0,
                        platform: platform,
                        sourceID: source.id
                    )
                }
                collected.append(contentsOf: tracks.prefix(limit))
                DiagnosticLogger.shared.info(
                    "MusicFree 插件搜索 \(source.name): \(tracks.count) 条",
                    category: "plugin"
                )
            } catch {
                if error is CancellationError { break }
                DiagnosticLogger.shared.warning(
                    "MusicFree 插件搜索失败 \(source.name): \(error.localizedDescription)",
                    category: "plugin"
                )
            }
        }
        return collected
    }

    func resolveDownloadMusicURL(for track: Track, quality: String) async throws -> ResolvedURL {
        try await Self.downloadResolver.resolveMusicURL(for: track, quality: quality)
    }

    /// Load a provider only when a request actually needs one.  A user's
    /// imported JavaScript must not be evaluated while the app scene is
    /// launching.
    func ensureSelectedSourceLoaded() {
        let selectedID = LXSourceStore.shared.selectedID
        guard loadedID != selectedID else { return }
        loadSelectedSource()
    }

    func load(_ source: LXSourceStore.Source?) {
        sourceInitializationTask?.cancel()
        sourceInitializationTask = nil
        pendingInitializationID = source?.id
        context = nil
        loadedID = source?.id
        loadedName = source?.name ?? ""
        loadedScript = source?.script
        loadedKind = source?.kind ?? .lx
        capabilities = [:]
        qualityCapabilities = [:]
        statusMessage = source == nil ? "未选择音源" : "正在加载音源"
        DiagnosticLogger.shared.info(
            "音源 load 开始: name=\(source?.name ?? "nil") id=\(source?.id ?? "nil") scriptBytes=\(source?.script.utf8.count ?? 0)",
            category: "source"
        )

        guard let source else {
            pendingInitializationID = nil
            DiagnosticLogger.shared.warning("没有选中的 LX 音源，跳过加载", category: "source")
            return
        }
        let isPlugin = loadedKind == .musicFree
        let preloadName = isPlugin ? "MusicFreePreload" : "LXUserAPIPreload"
        guard let preloadURL = Self.preloadScriptURL(preloadName),
              let preload = try? String(contentsOf: preloadURL, encoding: .utf8) else {
            pendingInitializationID = nil
            statusMessage = "\(preloadName) 预加载桥接文件不存在"
            DiagnosticLogger.shared.error(
                "找不到 \(preloadName).js（已检查 main bundle 与所有内嵌 .bundle），跳过脚本加载",
                category: "source"
            )
            return
        }
        guard let js = JSContext() else {
            pendingInitializationID = nil
            context = nil
            statusMessage = "JSContext 创建失败"
            DiagnosticLogger.shared.error("JSContext() 返回 nil，无法加载音源", category: "source")
            return
        }
        // Setting `exceptionHandler` makes `JSContext.exception` unreliable: the
        // handler consumes the value, so `js.exception` comes back nil after a
        // fatal script error. That is how a preload rejected at parse time was
        // reported as "plugin loaded". Record the message ourselves and treat
        // it as the source of truth.
        let scriptError = JSScriptErrorBox()
        js.exceptionHandler = { _, exception in
            guard let exception else { return }
            let detail = exception.toString() ?? "unknown"
            scriptError.message = detail
            Logger(subsystem: "com.jiajia2222.imusic.ios", category: "LXSource.Script")
                .error("JavaScript exception: \(detail, privacy: .private)")
            DiagnosticLogger.shared.error("JavaScript 异常: \(detail)", category: "source")
        }
        context = js
        key = UUID().uuidString
        installHostFunctions(in: js)
        DiagnosticLogger.shared.info("开始执行 \(preloadName) 预加载桥接脚本", category: "source")
        scriptError.message = nil
        js.evaluateScript(preload)
        if let failure = Self.scriptFailure(js, scriptError) {
            context = nil
            pendingInitializationID = nil
            statusMessage = "\(preloadName) 桥接加载失败：\(failure)"
            DiagnosticLogger.shared.error(
                "\(preloadName) 预加载脚本执行失败: \(failure)",
                category: "source"
            )
            return
        }
        let setupName = isPlugin ? "mf_setup" : "lx_setup"
        // A missing entry point used to be silently ignored: `objectForKeyedSubscript`
        // yields a JSValue wrapping `undefined`, so optional chaining still called
        // into it and the TypeError was swallowed below. Fail loudly instead.
        guard let setup = js.objectForKeyedSubscript(setupName),
              !setup.isUndefined, !setup.isNull else {
            context = nil
            pendingInitializationID = nil
            let detail = Self.scriptFailure(js, scriptError) ?? "未导出 \(setupName)"
            statusMessage = "\(isPlugin ? "插件" : "LX 音源")桥接初始化失败：\(detail)"
            DiagnosticLogger.shared.error(
                "\(preloadName) 未提供 \(setupName) 入口（\(detail)）",
                category: isPlugin ? "plugin" : "source"
            )
            return
        }
        scriptError.message = nil
        setup.call(withArguments: [key, source.id, source.name, source.description,
                                   source.version, source.author, source.homepage, source.script])
        if let failure = Self.scriptFailure(js, scriptError) {
            context = nil
            pendingInitializationID = nil
            statusMessage = "\(isPlugin ? "插件" : "LX 音源")初始化失败：\(failure)"
            DiagnosticLogger.shared.error("\(setupName) 初始化失败: \(failure)",
                                          category: isPlugin ? "plugin" : "source")
            return
        }
        if isPlugin {
            // CommonJS evaluation happens inside mf_setup; evaluating the raw
            // script again here would execute it outside the module wrapper.
            guard context != nil else { return }
            // Capabilities arrive through the async native bridge, so readiness
            // is confirmed in handleNativeCall("init"), not here. Say exactly
            // that instead of claiming the plugin is loaded.
            DiagnosticLogger.shared.info(
                "MusicFree 插件脚本已求值，等待上报接口: \(source.name)",
                category: "plugin"
            )
        } else {
            DiagnosticLogger.shared.info("开始执行用户导入的音源脚本", category: "source")
            scriptError.message = nil
            _ = js.evaluateScript(source.script)
            if let failure = Self.scriptFailure(js, scriptError) {
                context = nil
                pendingInitializationID = nil
                statusMessage = "LX 音源脚本错误：\(failure)"
                logger.error("Failed to load LX source \(source.name, privacy: .private): \(failure, privacy: .private)")
                DiagnosticLogger.shared.error("用户音源脚本执行失败: \(failure)", category: "source")
            } else {
                DiagnosticLogger.shared.info("音源脚本加载完成", category: "source")
            }
        }
        if context != nil {
            scheduleInitializationFallback(for: source.id)
        }
    }

    /// Reads a fatal script error from either the context or the handler sink.
    private static func scriptFailure(_ js: JSContext, _ sink: JSScriptErrorBox) -> String? {
        if let exception = js.exception, !exception.isUndefined, !exception.isNull {
            return exception.toString() ?? sink.message
        }
        return sink.message
    }

    /// Never reference `Bundle.module` here: the generated SwiftPM accessor
    /// force-unwraps the resource bundle and traps when a re-signer drops it.
    /// Look in the main bundle and every embedded `.bundle` instead.
    private static func preloadScriptURL(_ resource: String = "LXUserAPIPreload") -> URL? {
        if let url = Bundle.main.url(forResource: resource, withExtension: "js") {
            return url
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Bundle.main.bundleURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        for candidate in contents where candidate.pathExtension == "bundle" {
            if let url = Bundle(url: candidate)?.url(forResource: resource, withExtension: "js") {
                return url
            }
        }
        return nil
    }

    /// A resolved link with the moment it was produced, so playback can tell a
    /// fresh answer from a stale one.
    fileprivate struct CachedResolution {
        let resolved: ResolvedURL
        let storedAt: Date
        /// Recorded so the log can tell a warmed-ahead link from a replay of a
        /// track that was simply played twice.
        let fromPrefetch: Bool
    }

    func resolveMusicURL(for track: Track, quality: String,
                         isPrefetch: Bool = false) async throws -> ResolvedURL {
        // A real tap always outranks a guess about what plays next: drop the
        // prefetch so it yields the resolver lock instead of sitting in front
        // of the request the user is waiting on.
        if !isPrefetch {
            cancelPrefetch()
            if let cached = cachedResolution(for: track, quality: quality) {
                DiagnosticLogger.shared.info(
                    "\(cached.fromPrefetch ? "预取命中" : "重播复用"): \(track.name) "
                        + "缓存年龄=\(Int(Date().timeIntervalSince(cached.storedAt)))s",
                    category: "play"
                )
                var hit = cached.resolved
                hit.isFromCache = true
                return hit
            }
        }
        if isPrefetch {
            DiagnosticLogger.shared.info("预取开始: \(track.name) / \(quality)", category: "play")
        } else {
            DiagnosticLogger.shared.info("resolveMusicURL 开始: \(track.name) / \(quality)", category: "play")
        }
        do {
            try await acquireSourceOperation()
            defer { releaseSourceOperation() }
            try Task.checkCancellation()
            let resolved = try await resolveMusicURLAcrossSources(for: track, quality: quality)
            storeResolution(resolved, for: track, quality: quality, prefetched: isPrefetch)
            DiagnosticLogger.shared.info(
                isPrefetch ? "预取完成: \(track.name)" : "resolveMusicURL 成功: \(track.name)",
                category: "play"
            )
            return resolved
        } catch {
            // A song switch cancels the previous resolution. That is normal
            // operation, and logging it as ERROR would hide real failures.
            if error is CancellationError || Task.isCancelled {
                DiagnosticLogger.shared.info(
                    isPrefetch ? "预取已放弃: \(track.name)" : "resolveMusicURL 已取消: \(track.name)",
                    category: "play"
                )
            } else if isPrefetch {
                // A prefetch that finds nothing is not a playback failure; the
                // same song is simply resolved again when it is actually
                // reached.
                DiagnosticLogger.shared.info(
                    "预取未命中: \(track.name) -> \(error.localizedDescription)",
                    category: "play"
                )
            } else {
                DiagnosticLogger.shared.error("resolveMusicURL 失败: \(track.name) -> \(error.localizedDescription)", category: "play")
            }
            throw error
        }
#if false
        ensureSelectedSourceLoaded()
        await waitForSourceReady()
        guard context != nil else { throw LXError.noSource }
        guard capabilities.values.contains(where: { $0.contains("musicUrl") }) else {
            throw LXError.sourceUnavailable(statusMessage)
        }
        let primarySource = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        var failures: [String] = []

        for platform in sourceCandidates(for: track, action: "musicUrl") {
            let platformName = LXCatalogPlatform.displayName(for: platform)
            let requestTrack: Track
            if platform == primarySource {
                requestTrack = track
            } else {
                // IDs are platform-specific. A Kuwo RID cannot be sent to a
                // Kugou/QQ/NetEase source, so look up a matching result first.
                guard let matched = await LXCatalogService.matchingTrack(track, on: platform) else {
                    failures.append("\(platformName)：找不到对应歌曲")
                    continue
                }
                requestTrack = matched
            }

            let supportedQualitys = supportedQualityNames(for: requestTrack, platform: platform)
            let requestedQuality = Self.lxQuality(for: quality,
                                                  supported: supportedQualitys.isEmpty ? ["128k"] : supportedQualitys)
            do {
                let response = try await request(source: platform, action: "musicUrl",
                                                 info: ["type": protocolQualityToken(requestedQuality, platform: platform),
                                                        "musicInfo": musicInfo(for: requestTrack,
                                                                                platform: platform,
                                                                                qualities: supportedQualitys)])
                guard let data = response["data"] as? [String: Any],
                      let rawURL = data["url"] as? String,
                      let url = URL(string: rawURL),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    failures.append("\(platformName)：没有返回有效播放地址")
                    continue
                }
                let actualQuality = Self.resolvedQuality(
                    returned: (data["type"] as? String)
                        ?? (data["quality"] as? String)
                        ?? (data["format"] as? String),
                    requested: requestedQuality,
                    available: supportedQualitys.isEmpty ? ["128k"] : supportedQualitys
                )
                return ResolvedURL(url: url, quality: actualQuality)
            } catch {
                failures.append("\(platformName)：\(error.localizedDescription)")
            }
        }
        throw LXError.resolveFailed(failures.isEmpty
            ? ["当前音源没有可用的 musicUrl 平台"]
            : failures)
#endif
    }

    // MARK: - Resolution cache and prefetch

    /// Warms the link for the track that will play next, so reaching it costs a
    /// cache read instead of the full provider walk. Only ever one track ahead:
    /// every prefetch holds the single resolver lock, and songs further down the
    /// queue are usually skipped or reordered before they are reached.
    func prefetchNextTrack(_ track: Track, quality: String) {
        cancelPrefetch()
        guard cachedResolution(for: track, quality: quality) == nil else { return }
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            // Cancellation and an empty result are both normal here; the song
            // is simply resolved again when it is actually reached.
            _ = try? await self.resolveMusicURL(for: track, quality: quality, isPrefetch: true)
        }
    }

    /// Drops any in-flight prefetch. Cancelling is enough to release the
    /// source-operation lock: `request` observes cancellation and resumes its
    /// continuation immediately.
    func cancelPrefetch() {
        guard prefetchTask != nil else { return }
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    func hasCachedResolution(for track: Track, quality: String) -> Bool {
        cachedResolution(for: track, quality: quality) != nil
    }

    /// A cached link that failed to play is worse than no cache at all, so the
    /// entry is dropped and the next attempt resolves from scratch.
    func invalidateCachedResolution(for track: Track, quality: String) {
        resolutionCache.removeValue(forKey: cacheKey(for: track, quality: quality))
    }

    private func cacheKey(for track: Track, quality: String) -> String {
        let platform = track.source ?? track.sourceMetadata["source"] ?? "-"
        return "\(platform)|\(track.id)|\(quality)"
    }

    private func cachedResolution(for track: Track, quality: String) -> CachedResolution? {
        let key = cacheKey(for: track, quality: quality)
        guard let entry = resolutionCache[key] else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) < Self.resolutionCacheTTL else {
            resolutionCache.removeValue(forKey: key)
            return nil
        }
        return entry
    }

    private func storeResolution(_ resolved: ResolvedURL, for track: Track,
                                 quality: String, prefetched: Bool) {
        if resolutionCache.count > 200 { resolutionCache.removeAll() }
        resolutionCache[cacheKey(for: track, quality: quality)] = CachedResolution(
            resolved: resolved, storedAt: Date(), fromPrefetch: prefetched
        )
    }

    private static func isNeteaseTrack(_ track: Track) -> Bool {
        guard let rawSource = track.source ?? track.sourceMetadata["source"] else {
            // Native NetEase catalogue responses do not carry an LX source
            // marker. They are the only unmarked tracks in the queue.
            return true
        }
        let source = rawSource
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty || ["wy", "163", "netease", "neteasecloudmusic", "cloudmusic"].contains(source)
    }

    private func resolveMusicURLAcrossSources(for track: Track, quality: String) async throws -> ResolvedURL {
        let sourceRevision = LXSourceStore.shared.configurationRevision
        let playbackSources = LXSourceStore.shared.playbackSources
        guard !playbackSources.isEmpty else { throw LXError.noSource }

        let primaryPlatform = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        // A track produced by a MusicFree plugin only carries that plugin's own
        // ID space. Try the plugin that produced it first so playback does not
        // start by loading an unrelated source that cannot serve it.
        var orderedSources = playbackSources
        if let originID = track.sourceMetadata["mf.sourceID"],
           let originIndex = orderedSources.firstIndex(where: { $0.id == originID }) {
            orderedSources.insert(orderedSources.remove(at: originIndex), at: 0)
        }
        var failures: [String] = []
        // A single track used to spend 20 s per candidate platform with no
        // overall cap, so one dead provider froze playback for minutes. Keep the
        // per-track ceiling, and additionally cap the first probe of every
        // route: a healthy provider answers in 50–1200 ms, while the 8–10 s
        // outliers in practice never returned a URL at all.
        let startedAt = Date()
        var budgetExhausted = false
        // Routes our own probe cut short, retried once at the very end. Without
        // that a slow-but-playable provider would become a skipped song; with
        // it the common case stays fast and the rare case still plays.
        var slowRoutes: [(source: LXSourceStore.Source, platform: String)] = []

        // Resolve each route before preparing fallbacks. This honors the
        // selected source and avoids doing catalogue work for backups when the
        // preferred source can play the track.
        for source in orderedSources {
            try Task.checkCancellation()
            try validateSourceConfiguration(sourceRevision, source: source)
            if Date().timeIntervalSince(startedAt) > Self.sourceResolveBudget {
                budgetExhausted = true
                break
            }
            let isAvailable = await activate(source)
            try validateSourceConfiguration(sourceRevision, source: source)
            guard isAvailable else {
                failures.append("\(source.name): unavailable")
                DiagnosticLogger.shared.warning(
                    "跳过音源 \(source.name)：加载失败（\(statusMessage.isEmpty ? "未知原因" : statusMessage)）",
                    category: "play"
                )
                continue
            }
            let platforms = sourceCandidates(for: track, action: "musicUrl")
            if platforms.isEmpty {
                failures.append("\(source.name): no musicUrl platform")
                DiagnosticLogger.shared.info(
                    "跳过音源 \(source.name)：未声明 musicUrl 接口（已声明 \(Self.describeCapabilities(capabilities))）",
                    category: "play"
                )
                continue
            }

            // A provider often has one broken platform and four working ones.
            // Probe the healthy routes first so the broken one cannot decide
            // how long the song takes to start.
            for platform in orderPlatforms(platforms, for: source) {
                if Date().timeIntervalSince(startedAt) > Self.sourceResolveBudget {
                    budgetExhausted = true
                    break
                }
                let routeStartedAt = Date()
                let outcome = try await attemptRoute(
                    source: source,
                    platform: platform,
                    track: track,
                    primaryPlatform: primaryPlatform,
                    quality: quality,
                    budget: attemptBudget(for: source, platform: platform, since: startedAt)
                )
                recordRouteHealth(source: source, platform: platform, outcome: outcome,
                                  elapsed: Date().timeIntervalSince(routeStartedAt))
                switch outcome {
                case .resolved(let resolved):
                    DiagnosticLogger.shared.info(
                        "音乐地址来自 音源=\(source.name) 平台=\(platform) "
                            + "音质=\(resolved.quality) 总耗时=\(Self.milliseconds(since: startedAt)) ms",
                        category: "play"
                    )
                    return resolved
                case .notFound(let reason), .failed(let reason):
                    failures.append(reason)
                case .slow(let reason):
                    failures.append(reason)
                    slowRoutes.append((source: source, platform: platform))
                }
            }
            if budgetExhausted { break }
        }

        // Second chance for the routes our own probe cut short. Only reached
        // when every fast candidate already failed, so the common case never
        // pays for it.
        if !slowRoutes.isEmpty, !budgetExhausted,
           Date().timeIntervalSince(startedAt) < Self.sourceResolveBudget {
            DiagnosticLogger.shared.info(
                "寻源兜底：重试 \(slowRoutes.count) 条慢通道（首次探测上限 \(Int(Self.platformAttemptBudget)) 秒）",
                category: "play"
            )
            for route in slowRoutes {
                let remaining = Self.sourceResolveBudget - Date().timeIntervalSince(startedAt)
                guard remaining > 1 else { break }
                try Task.checkCancellation()
                try validateSourceConfiguration(sourceRevision, source: route.source)
                guard await activate(route.source) else { continue }
                try validateSourceConfiguration(sourceRevision, source: route.source)
                let routeStartedAt = Date()
                let outcome = try await attemptRoute(
                    source: route.source,
                    platform: route.platform,
                    track: track,
                    primaryPlatform: primaryPlatform,
                    quality: quality,
                    budget: max(3, remaining)
                )
                recordRouteHealth(source: route.source, platform: route.platform,
                                  outcome: outcome,
                                  elapsed: Date().timeIntervalSince(routeStartedAt))
                switch outcome {
                case .resolved(let resolved):
                    DiagnosticLogger.shared.info(
                        "兜底命中 音源=\(route.source.name) 平台=\(route.platform) "
                            + "音质=\(resolved.quality) 总耗时=\(Self.milliseconds(since: startedAt)) ms",
                        category: "play"
                    )
                    return resolved
                case .notFound(let reason), .failed(let reason), .slow(let reason):
                    failures.append(reason)
                }
            }
        }

        if budgetExhausted {
            failures.append("寻源超出 \(Int(Self.sourceResolveBudget)) 秒预算，已放弃剩余音源")
            DiagnosticLogger.shared.error(
                "寻源超时，放弃剩余候选: \(track.name)（失败明细：\(failures.joined(separator: " | "))）",
                category: "play"
            )
        }
        if failures.isEmpty {
            throw LXError.sourceUnavailable("No enabled LX source exposes musicUrl")
        }
        throw LXError.resolveFailed(failures)
    }

    /// How a single (source, platform) candidate ended. `slow` is the only
    /// outcome that earns a second attempt: it means our own probe gave up,
    /// not that the provider answered "no".
    private enum RouteOutcome {
        case resolved(ResolvedURL)
        case notFound(String)
        case failed(String)
        case slow(String)
    }

    /// Runs one candidate route. Throws only on cancellation, so the caller can
    /// tell a cancelled song switch apart from a provider failure.
    private func attemptRoute(source: LXSourceStore.Source,
                              platform: String,
                              track: Track,
                              primaryPlatform: String,
                              quality: String,
                              budget: TimeInterval) async throws -> RouteOutcome {
        let sourceRevision = LXSourceStore.shared.configurationRevision
        let attemptStartedAt = Date()
        // A timed-out provider request tears the JavaScript context down
        // (`cancelPendingRequest` drops it so late callbacks cannot attach to
        // the next route), which leaves every later platform without a source.
        // Reload before probing so one timeout cannot poison the rest.
        if loadedID != source.id || context == nil {
            guard await activate(source) else {
                return .failed("\(source.name): 重新加载失败")
            }
        }
        let requestTrack: Track
        if platform == primaryPlatform {
            requestTrack = track
        } else {
            // IDs are platform-specific. Match the song before using a
            // different platform's musicUrl endpoint.
            guard let matched = await LXCatalogService.matchingTrack(track, on: platform) else {
                DiagnosticLogger.shared.info(
                    "音源 \(source.name)/\(platform) 未命中该歌曲（\(Self.milliseconds(since: attemptStartedAt)) ms）",
                    category: "play"
                )
                return .notFound("\(source.name)/\(platform): track not found")
            }
            requestTrack = matched
        }
        try Task.checkCancellation()
        try validateSourceConfiguration(sourceRevision, source: source)

        let supported = supportedQualityNames(for: requestTrack, platform: platform)
        let requested = Self.lxQuality(for: quality,
                                       supported: supported.isEmpty ? ["128k"] : supported)
        do {
            let response = try await request(
                source: platform,
                action: "musicUrl",
                timeout: budget,
                info: [
                    "type": protocolQualityToken(requested, platform: platform),
                    "musicInfo": musicInfo(
                        for: requestTrack,
                        platform: platform,
                        qualities: supported
                    )
                ]
            )
            try Task.checkCancellation()
            try validateSourceConfiguration(sourceRevision, source: source)
            guard let data = response["data"] as? [String: Any],
                  let rawURL = data["url"] as? String,
                  let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                DiagnosticLogger.shared.warning(
                    "音源 \(source.name)/\(platform) 未返回有效播放地址（\(Self.milliseconds(since: attemptStartedAt)) ms）",
                    category: "play"
                )
                return .failed("\(source.name)/\(platform): invalid URL")
            }
            DiagnosticLogger.shared.info(
                "音源 \(source.name)/\(platform) 取地址用时 \(Self.milliseconds(since: attemptStartedAt)) ms",
                category: "play"
            )
            // The LX bridge echoes the requested `type`; it cannot confirm the
            // provider's actual codec or bitrate.
            return .resolved(ResolvedURL(url: url, quality: requested,
                                        qualityIsVerified: false))
        } catch {
            if error is CancellationError { throw error }
            try validateSourceConfiguration(sourceRevision, source: source)
            let elapsed = Self.milliseconds(since: attemptStartedAt)
            if let lx = error as? LXError, case .requestTimedOut = lx {
                DiagnosticLogger.shared.warning(
                    "音源 \(source.name)/\(platform) 探测超时（\(elapsed) ms，上限 \(Int(budget)) 秒），排到兜底阶段",
                    category: "play"
                )
                return .slow("\(source.name)/\(platform): 探测超时 \(elapsed) ms")
            }
            DiagnosticLogger.shared.warning(
                "音源 \(source.name)/\(platform) 取地址失败（\(elapsed) ms）：\(error.localizedDescription)",
                category: "play"
            )
            return .failed("\(source.name)/\(platform): \(error.localizedDescription)")
        }
    }

    private func routeKey(_ source: LXSourceStore.Source, _ platform: String) -> String {
        "\(source.id)#\(platform)"
    }

    /// Healthy platforms keep their natural order; demoted ones move to the
    /// back so a fast alternative can answer first.
    private func orderPlatforms(_ platforms: [String],
                                for source: LXSourceStore.Source) -> [String] {
        guard platforms.count > 1 else { return platforms }
        var healthy: [String] = []
        var demoted: [String] = []
        for platform in platforms {
            let failures = slowRouteFailures[routeKey(source, platform)] ?? 0
            if failures >= Self.slowRouteFailureThreshold {
                demoted.append(platform)
            } else {
                healthy.append(platform)
            }
        }
        return healthy + demoted
    }

    private func attemptBudget(for source: LXSourceStore.Source,
                               platform: String,
                               since start: Date) -> TimeInterval {
        let demoted = (slowRouteFailures[routeKey(source, platform)] ?? 0)
            >= Self.slowRouteFailureThreshold
        let cap = demoted ? Self.demotedPlatformAttemptBudget : Self.platformAttemptBudget
        return max(2.5, min(cap, Self.remainingSourceBudget(since: start)))
    }

    private func recordRouteHealth(source: LXSourceStore.Source,
                                   platform: String,
                                   outcome: RouteOutcome,
                                   elapsed: TimeInterval) {
        let key = routeKey(source, platform)
        switch outcome {
        case .resolved, .notFound:
            // Either a working route or a provider that answered quickly; both
            // mean the route is responsive.
            slowRouteFailures.removeValue(forKey: key)
        case .failed:
            // A fast failure is a real answer ("no such song"), not slowness.
            if elapsed >= Self.slowRouteFailureWindow {
                noteSlowRouteFailure(key: key, source: source, platform: platform)
            } else {
                slowRouteFailures.removeValue(forKey: key)
            }
        case .slow:
            noteSlowRouteFailure(key: key, source: source, platform: platform)
        }
    }

    private func noteSlowRouteFailure(key: String,
                                      source: LXSourceStore.Source,
                                      platform: String) {
        if slowRouteFailures.count > 64 { slowRouteFailures.removeAll() }
        let count = (slowRouteFailures[key] ?? 0) + 1
        slowRouteFailures[key] = count
        guard count == Self.slowRouteFailureThreshold else { return }
        DiagnosticLogger.shared.warning(
            "音源 \(source.name)/\(platform) 连续 \(count) 次慢失败，"
                + "后续只探测 \(Int(Self.demotedPlatformAttemptBudget)) 秒并排到健康通道之后",
            category: "play"
        )
    }

    /// Total wall-clock allowance for resolving one track across every source.
    private static let sourceResolveBudget: TimeInterval = 20

    /// First probe of one candidate route. Measured against a real log: the
    /// fastest useful providers answered in 50–400 ms, the slowest successful
    /// one took 3.96 s, while every 8–10 s attempt failed anyway.
    private static let platformAttemptBudget: TimeInterval = 5

    /// A route that burned the full probe this many times in a row is treated
    /// as broken for the rest of the session.
    private static let slowRouteFailureThreshold = 3
    private static let demotedPlatformAttemptBudget: TimeInterval = 3
    /// Failures returning faster than this are real answers, not slowness.
    private static let slowRouteFailureWindow: TimeInterval = 3

    /// Lyrics run in their own resolver, so they never delay playback, but a
    /// dead provider used to keep them running for minutes. Bound both the
    /// single request and the whole search.
    private static let lyricResolveBudget: TimeInterval = 15
    private static let lyricAttemptBudget: TimeInterval = 6

    /// A manual health check must finish while the user is still looking at the
    /// button: one short probe per platform, plus a ceiling for the whole run.
    private static let sourceCheckAttemptBudget: TimeInterval = 6
    private static let sourceCheckBudget: TimeInterval = 20

    /// Timeout handed to a single provider call, clamped to what is left of the
    /// per-track budget so a slow provider cannot outlive it.
    private static func remainingSourceBudget(since start: Date) -> TimeInterval {
        let remaining = sourceResolveBudget - Date().timeIntervalSince(start)
        return max(3, min(12, remaining))
    }

    private static func milliseconds(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }

    private static func describeCapabilities(_ capabilities: [String: [String]]) -> String {
        guard !capabilities.isEmpty else { return "无" }
        return capabilities
            .map { "\($0.key):\($0.value.joined(separator: "/"))" }
            .sorted()
            .joined(separator: " ")
    }

    /// Performs a real, read-only musicUrl request against the selected LX
    /// source. The test metadata is bundled locally so health checks never
    /// call a built-in music-platform catalogue endpoint.
    func checkSelectedSource() async -> SourceCheckResult {
        guard let source = LXSourceStore.shared.selectedSource else {
            return SourceCheckResult(status: .unavailable,
                                     message: "未选择音源",
                                     detail: "请先导入并启用一个 LX User API 音源。")
        }
        return await checkSource(source)
    }

    /// Read-only health report for imported MusicFree plugins. It loads each
    /// plugin in an isolated context and reports which methods were detected;
    /// the selected source and the active playback context are never touched.
    func musicFreePluginReport() async -> [String] {
        let plugins = LXSourceStore.shared.sources.filter { $0.kind == .musicFree }
        guard !plugins.isEmpty else { return ["未导入 MusicFree 插件。"] }
        var lines: [String] = []
        for source in plugins {
            let startedAt = Date()
            let checker = LXUserAPIService()
            checker.load(source)
            await checker.waitForSourceReady()
            let actions = Set(checker.capabilities.values.flatMap { $0 }).sorted()
            let loadMilliseconds = Self.milliseconds(since: startedAt)
            guard checker.context != nil, !actions.isEmpty else {
                let status = checker.statusMessage.isEmpty ? "插件没有上报任何接口" : checker.statusMessage
                lines.append("\(source.name)：❌ 加载失败（\(status)）")
                DiagnosticLogger.shared.warning(
                    "插件体检失败 \(source.name): \(status)",
                    category: "plugin"
                )
                continue
            }
            var verdict: [String] = ["接口 \(actions.joined(separator: "/"))", "加载 \(loadMilliseconds) ms"]
            // Prove the plugin actually runs instead of only reporting that a
            // script parsed: search once, then resolve the first hit.
            if actions.contains("search") {
                do {
                    let response = try await checker.requestPlugin(
                        method: "search", args: [Self.pluginSelfTestKeyword, 1, "music"])
                    let envelope = response["result"] as? [String: Any]
                    let items = envelope?["data"] as? [[String: Any]] ?? []
                    verdict.append("搜索 \(items.count) 条")
                    if actions.contains("getMediaSource"), let first = items.first {
                        do {
                            let media = try await checker.requestPlugin(
                                method: "getMediaSource", args: [first, "standard"])
                            let data = (media["result"] as? [String: Any])?["data"] as? [String: Any]
                            if let url = data?["url"] as? String, !url.isEmpty {
                                verdict.append("播放地址 OK")
                            } else {
                                verdict.append("播放地址为空")
                            }
                        } catch {
                            verdict.append("取播放地址失败：\(error.localizedDescription)")
                        }
                    }
                } catch {
                    verdict.append("搜索失败：\(error.localizedDescription)")
                }
            } else {
                verdict.append("未实现 search")
            }
            lines.append("\(source.name)：✅ \(verdict.joined(separator: "，"))")
            DiagnosticLogger.shared.info(
                "插件体检通过 \(source.name): \(verdict.joined(separator: "，"))",
                category: "plugin"
            )
        }
        return lines
    }

    /// A neutral query that every search-capable plugin can answer with an
    /// empty list, so the self-test never depends on a provider's catalogue.
    static let pluginSelfTestKeyword = "晴天"

    /// Checks any imported source in an isolated JavaScript context. Testing a
    /// disabled backup must not select it (which would silently enable it),
    /// and swapping the shared context could interrupt an in-flight lookup.
    func checkSource(_ source: LXSourceStore.Source) async -> SourceCheckResult {
        let checker = LXUserAPIService()
        let startedAt = Date()
        DiagnosticLogger.shared.info("音源体检开始: \(source.name)", category: "plugin")
        let result = await withTaskCancellationHandler {
            defer { checker.cancelPendingRequests() }
            checker.load(source)
            await checker.waitForSourceReady()
            guard !Task.isCancelled else {
                return SourceCheckResult(status: .unavailable, message: "检测已取消", detail: nil)
            }
            return await checker.checkLoadedSource()
        } onCancel: {
            Task { @MainActor in checker.cancelPendingRequests() }
        }
        if !Task.isCancelled, LXSourceStore.shared.selectedID == source.id {
            statusMessage = result.detail.map { "\(result.message)：\($0)" } ?? result.message
        }
        DiagnosticLogger.shared.info(
            "音源体检结束: \(source.name) → \(result.message)（\(Self.milliseconds(since: startedAt)) ms）",
            category: "plugin"
        )
        return result
    }

    private func checkLoadedSource() async -> SourceCheckResult {
        guard context != nil else {
            return SourceCheckResult(status: .unavailable,
                                     message: "音源脚本加载失败",
                                     detail: statusMessage)
        }

        let platformOrder = ["wy", "kw", "kg", "tx", "mg"]
        let supportedPlatforms = platformOrder.filter {
            capabilities[$0]?.contains("musicUrl") == true
        }
        guard !supportedPlatforms.isEmpty else {
            let detail = capabilities.isEmpty
                ? "脚本没有返回平台能力。"
                : "脚本已加载，但没有提供 musicUrl 接口。"
            return SourceCheckResult(status: .unavailable,
                                     message: "没有可用的播放接口",
                                     detail: detail)
        }

        var failures: [String] = []
        var requiresTrackPlatforms: [String] = []
        let startedAt = Date()
        for (index, platform) in supportedPlatforms.enumerated() {
            guard !Task.isCancelled else {
                return SourceCheckResult(status: .unavailable, message: "检测已取消", detail: nil)
            }
            // A health check used to allow 20 s per platform with no overall
            // limit, which made the button look dead for over half a minute on
            // a slow source.
            if Date().timeIntervalSince(startedAt) > Self.sourceCheckBudget {
                for rest in supportedPlatforms.dropFirst(index) {
                    DiagnosticLogger.shared.info(
                        "音源体检跳过 \(LXCatalogPlatform.displayName(for: rest))：已用满 \(Int(Self.sourceCheckBudget)) 秒预算",
                        category: "plugin"
                    )
                }
                break
            }
            let platformName = LXCatalogPlatform.displayName(for: platform)
            let attemptStartedAt = Date()
            let currentTrack = PlayerService.shared.currentTrack
            let track = currentTrack.flatMap {
                canonicalPlatform($0.source ?? $0.sourceMetadata["source"]) == platform ? $0 : nil
            } ?? Self.sourceCheckTrack(for: platform)
            guard let track else {
                requiresTrackPlatforms.append(platformName)
                DiagnosticLogger.shared.info(
                    "音源体检 \(platformName)：需要该平台歌曲，跳过", category: "plugin")
                continue
            }

            let supportedQualitys = supportedQualityNames(for: track, platform: platform)
            let requestedQuality = Self.lxQuality(
                for: SettingsManager.shared.audioQuality.rawValue,
                supported: supportedQualitys.isEmpty ? ["128k"] : supportedQualitys
            )
            let info = musicInfo(for: track, platform: platform, qualities: supportedQualitys)
            do {
                let response = try await request(source: platform, action: "musicUrl",
                                                 timeout: Self.sourceCheckAttemptBudget,
                                                 info: ["type": protocolQualityToken(requestedQuality, platform: platform), "musicInfo": info])
                guard !Task.isCancelled else {
                    return SourceCheckResult(status: .unavailable, message: "检测已取消", detail: nil)
                }
                guard let data = response["data"] as? [String: Any],
                      let rawURL = data["url"] as? String,
                      let url = URL(string: rawURL),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    failures.append("\(platformName)：没有返回有效播放地址")
                    DiagnosticLogger.shared.info(
                        "音源体检 \(platformName)：没有返回有效播放地址（\(Self.milliseconds(since: attemptStartedAt)) ms）",
                        category: "plugin")
                    continue
                }
                DiagnosticLogger.shared.info(
                    "音源体检 \(platformName)：通过（\(Self.milliseconds(since: attemptStartedAt)) ms，档位 \(requestedQuality)）",
                    category: "plugin")

                let detail = "已通过 \(platformName) 的 musicUrl 接口，请求档位：\(requestedQuality)（音源未提供实际音质信息）"
                let result = SourceCheckResult(status: .available,
                                               message: "音源可用",
                                               detail: detail)
                statusMessage = "\(result.message)：\(detail)"
                return result
            } catch {
                if Task.isCancelled {
                    return SourceCheckResult(status: .unavailable, message: "检测已取消", detail: nil)
                }
                failures.append("\(platformName)：\(error.localizedDescription)")
                DiagnosticLogger.shared.warning(
                    "音源体检 \(platformName)：失败（\(Self.milliseconds(since: attemptStartedAt)) ms）：\(error.localizedDescription)",
                    category: "plugin")
            }
        }

        if !requiresTrackPlatforms.isEmpty {
            let attemptedDetail = failures.isEmpty ? nil : "已尝试的平台：\(failures.joined(separator: "；"))。"
            let trackDetail = "请先播放一首来自 \(requiresTrackPlatforms.joined(separator: "、")) 的歌曲，再重新检测。"
            DiagnosticLogger.shared.info(
                "音源体检完成：需要该平台歌曲才能确认（耗时 \(Self.milliseconds(since: startedAt)) ms）",
                category: "plugin")
            return SourceCheckResult(status: .requiresTrack,
                                     message: "需要该平台歌曲才能确认",
                                     detail: [attemptedDetail, trackDetail].compactMap { $0 }.joined())
        }

        let detail = failures.isEmpty ? "音源没有返回可播放地址。" : failures.joined(separator: "；")
        let result = SourceCheckResult(status: .unavailable,
                                       message: "音源不可用",
                                       detail: detail)
        DiagnosticLogger.shared.warning(
            "音源体检完成：不可用（耗时 \(Self.milliseconds(since: startedAt)) ms）：\(detail)",
            category: "plugin")
        statusMessage = "\(result.message)：\(detail)"
        return result
    }

    func resolveLyrics(for track: Track) async throws -> ResolvedLyrics {
        let resolver = Self.lyricsResolver
        try await resolver.acquireSourceOperation()
        defer { resolver.releaseSourceOperation() }
        try Task.checkCancellation()
        return try await resolver.resolveLyricsAcrossSources(for: track)
#if false
        ensureSelectedSourceLoaded()
        await waitForSourceReady()
        guard context != nil else { throw LXError.noSource }
        let primarySource = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        for platform in sourceCandidates(for: track, action: "lyric") {
            guard capabilities[platform]?.contains("lyric") == true else { continue }
            let requestTrack: Track
            if platform == primarySource {
                requestTrack = track
            } else {
                guard let matched = await LXCatalogService.matchingTrack(track, on: platform) else { continue }
                requestTrack = matched
            }
            for attempt in 0..<2 {
                guard let response = try? await request(source: platform, action: "lyric",
                                                        info: ["type": "lyric", "musicInfo": musicInfo(for: requestTrack, platform: platform)]),
                      let lyrics = await lyricPayload(from: response) else {
                    if attempt == 0 { try? await Task.sleep(for: .milliseconds(350)) }
                    continue
                }
                return lyrics
            }
        }
        throw LXError.resolveFailed([])
#endif
    }
    private func resolveLyricsAcrossSources(for track: Track) async throws -> ResolvedLyrics {
        let sourceRevision = LXSourceStore.shared.configurationRevision
        let playbackSources = LXSourceStore.shared.playbackSources
        guard !playbackSources.isEmpty else { throw LXError.noSource }

        let primaryPlatform = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        let startedAt = Date()
        var missed: [String] = []
        DiagnosticLogger.shared.info(
            "歌词解析开始: \(track.name)（主平台=\(primaryPlatform)，候选音源=\(playbackSources.count)）",
            category: "lyric"
        )
        for source in playbackSources {
            try Task.checkCancellation()
            if Date().timeIntervalSince(startedAt) > Self.lyricResolveBudget {
                DiagnosticLogger.shared.warning(
                    "歌词解析超出 \(Int(Self.lyricResolveBudget)) 秒预算，放弃剩余音源: \(track.name)",
                    category: "lyric"
                )
                break
            }
            try validateSourceConfiguration(sourceRevision, source: source)
            let isAvailable = await activate(source)
            try validateSourceConfiguration(sourceRevision, source: source)
            guard isAvailable else {
                missed.append("\(source.name): 加载失败")
                continue
            }
            for platform in sourceCandidates(for: track, action: "lyric") {
                let requestTrack: Track
                if platform == primaryPlatform {
                    requestTrack = track
                } else {
                    guard let matched = await LXCatalogService.matchingTrack(track, on: platform) else {
                        missed.append("\(source.name)/\(platform): 未匹配到歌曲")
                        continue
                    }
                    requestTrack = matched
                }
                try Task.checkCancellation()
                try validateSourceConfiguration(sourceRevision, source: source)
                let attemptStartedAt = Date()

                for attempt in 0..<2 {
                    do {
                        let response = try await request(
                            source: platform,
                            action: "lyric",
                            timeout: Self.lyricAttemptBudget,
                            info: [
                                "type": "lyric",
                                "musicInfo": musicInfo(for: requestTrack, platform: platform)
                            ]
                        )
                        try Task.checkCancellation()
                        try validateSourceConfiguration(sourceRevision, source: source)
                        if let lyrics = await lyricPayload(from: response) {
                            DiagnosticLogger.shared.info(
                                "歌词命中 音源=\(source.name) 平台=\(platform) "
                                    + "正文=\(lyrics.lyric.count)字 "
                                    + "翻译=\(lyrics.tlyric?.isEmpty == false ? "有" : "无") "
                                    + "逐字=\(lyrics.lxlyric?.isEmpty == false || lyrics.yrc?.isEmpty == false ? "有" : "无") "
                                    + "耗时=\(Self.milliseconds(since: attemptStartedAt)) ms "
                                    + "总耗时=\(Self.milliseconds(since: startedAt)) ms",
                                category: "lyric"
                            )
                            return lyrics
                        }
                    } catch {
                        if error is CancellationError { throw error }
                        try validateSourceConfiguration(sourceRevision, source: source)
                    }
                    if attempt == 0 { try? await Task.sleep(for: .milliseconds(350)) }
                }
                missed.append("\(source.name)/\(platform): 无歌词（\(Self.milliseconds(since: attemptStartedAt)) ms）")
            }
        }
        DiagnosticLogger.shared.warning(
            "歌词解析失败: \(track.name)（耗时 \(Self.milliseconds(since: startedAt)) ms，"
                + "明细：\(missed.isEmpty ? "无可尝试的组合" : missed.joined(separator: " | "))）",
            category: "lyric"
        )
        throw LXError.resolveFailed([])
    }

    /// LX source scripts do not all return the same lyric shape. In the wild
    /// `data` may be a string, an object with `lyric`/`lrc`, or an object that
    /// points to a separate LRC URL. Accept all of those forms so Kuwo,
    /// Kugou, QQ and Migu sources are not incorrectly reported as lyric-less.
    private func lyricPayload(from response: [String: Any]) async -> ResolvedLyrics? {
        let raw = response["data"]
        let object = raw as? [String: Any]
        var lyric = raw as? String
        var tlyric: String?
        var rlyric: String?
        var lxlyric: String?
        var yrc: String?

        if let object {
            func text(_ keys: [String]) -> String? {
                for key in keys {
                    if let value = object[key] as? String,
                       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
                    if let nested = object[key] as? [String: Any],
                       let value = nested["lyric"] as? String { return value }
                }
                return nil
            }
            lyric = text(["lyric", "lrc", "lyricText", "content", "text"])
            tlyric = text(["tlyric", "translation", "translatedLyric"])
            rlyric = text(["rlyric", "romalrc", "romaji"])
            lxlyric = text(["lxlyric"])
            yrc = text(["yrc", "verbatim", "wordLyric"])

            if lyric == nil,
               let urlString = text(["lrcUrl", "lyricUrl", "url"]),
               let url = URL(string: urlString),
               let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true {
                lyric = String(data: data, encoding: .utf8)
            }
        }

        guard let lyric = lyric ?? yrc,
              !lyric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ResolvedLyrics(lyric: lyric, tlyric: tlyric, rlyric: rlyric,
                              lxlyric: lxlyric, yrc: yrc)
    }

    enum LXError: LocalizedError {
        case noSource
        case resolveFailed([String])
        case sourceUnavailable(String)
        case requestTimedOut(seconds: Int)
        case javascript(String)

        var errorDescription: String? {
            switch self {
            case .noSource: return "请先在“设置 → LX 音源”中导入并启用音源"
            case .resolveFailed(let failures):
                guard !failures.isEmpty else { return "LX 音源没有返回可播放地址" }
                return failures.prefix(2).joined(separator: "；")
            case .sourceUnavailable(let status):
                return status.isEmpty ? "LX 音源尚未返回可用播放接口" : status
            case .javascript(let message): return message
            case .requestTimedOut(let seconds):
                return "音源 \(seconds) 秒内没有响应，已跳过"
            }
        }
    }

    private func installHostFunctions(in js: JSContext) {
        let consoleLog: @convention(block) (String) -> Void = { message in
            Logger(subsystem: "com.jiajia2222.imusic.ios", category: "LXSource.Script").debug("\(message, privacy: .private)")
        }
        let console = JSValue(newObjectIn: js)
        console?.setObject(consoleLog, forKeyedSubscript: "log" as NSString)
        console?.setObject(consoleLog, forKeyedSubscript: "info" as NSString)
        console?.setObject(consoleLog, forKeyedSubscript: "warn" as NSString)
        console?.setObject(consoleLog, forKeyedSubscript: "error" as NSString)
        js.setObject(console, forKeyedSubscript: "console" as NSString)

        let nativeCall: @convention(block) (String, String, String) -> Void = { [weak self] key, action, data in
            Task { @MainActor in
                guard let self, self.key == key else { return }
                self.handleNativeCall(action: action, data: data)
            }
        }
        js.setObject(nativeCall, forKeyedSubscript: "__lx_native_call__" as NSString)

        let str2b64: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        let b642buf: @convention(block) (String) -> String = { value in
            let bytes = Data(base64Encoded: value) ?? Data()
            return "[" + bytes.map(String.init).joined(separator: ",") + "]"
        }
        let md5: @convention(block) (String) -> String = { value in
            md5Hex(value.removingPercentEncoding ?? value)
        }
        let aes: @convention(block) (String, String, String, String) -> String = { input, key, iv, mode in
            aesEncrypt(input: input, key: key, iv: iv, mode: mode)
        }
        let rsa: @convention(block) (String, String, String) -> String = { input, publicKey, padding in
            rsaEncrypt(input: input, publicKey: publicKey, padding: padding)
        }
        js.setObject(str2b64, forKeyedSubscript: "__lx_native_call__utils_str2b64" as NSString)
        js.setObject(b642buf, forKeyedSubscript: "__lx_native_call__utils_b642buf" as NSString)
        js.setObject(md5, forKeyedSubscript: "__lx_native_call__utils_str2md5" as NSString)
        js.setObject(aes, forKeyedSubscript: "__lx_native_call__utils_aes_encrypt" as NSString)
        js.setObject(rsa, forKeyedSubscript: "__lx_native_call__utils_rsa_encrypt" as NSString)

        let timeout: @convention(block) (Int, Int) -> Void = { [weak self] id, delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(0, delay))) {
                Task { @MainActor in
                    guard let self else { return }
                    // This is the exact path that used to abort with SIGABRT
                    // (NSInvalidArgumentException in NSJSONSerialization).
                    // Log the first few callbacks so a successful run is
                    // visible in the exported diagnostics without flooding it.
                    if self.timeoutDiagnosticCount < 3 {
                        self.timeoutDiagnosticCount += 1
                        DiagnosticLogger.shared.info(
                            "LX setTimeout 回调 #\(self.timeoutDiagnosticCount): id=\(id) delay=\(delay)ms",
                            category: "source"
                        )
                    }
                    self.callJS(action: "__set_timeout__", data: id)
                }
            }
        }
        js.setObject(timeout, forKeyedSubscript: "__lx_native_call__set_timeout" as NSString)

        // ---- MusicFree plugin bridge (unused by LX sources) ----
        let mfHTTP: @convention(block) (String) -> Void = { [weak self] json in
            guard let self else { return }
            Task { @MainActor in self.handleMusicFreeHTTP(json) }
        }
        let mfSetTimeout: @convention(block) (String, Int) -> Void = { [weak self] timerID, delay in
            guard let self else { return }
            Task { @MainActor in self.scheduleMusicFreeTimer(id: timerID, delayMS: delay, repeats: false) }
        }
        let mfSetInterval: @convention(block) (String, Int) -> Void = { [weak self] timerID, delay in
            guard let self else { return }
            Task { @MainActor in self.scheduleMusicFreeTimer(id: timerID, delayMS: delay, repeats: true) }
        }
        let mfClearTimer: @convention(block) (String) -> Void = { [weak self] timerID in
            guard let self else { return }
            Task { @MainActor in
                self.mfTimers.removeValue(forKey: timerID)?.cancel()
            }
        }
        let mfHash: @convention(block) (String, String) -> String = { algo, text in
            hashHex(algorithm: algo, text: text)
        }
        let mfHMAC: @convention(block) (String, String, String) -> String = { algo, text, keyHex in
            guard let key = hexData(keyHex) else { return "" }
            return hmacHex(algorithm: algo, text: text, key: key)
        }
        let mfAES: @convention(block) (String, String, String, String, String, String) -> String = { op, inputHex, keyHex, ivHex, mode, padding in
            aesHex(operation: op, inputHex: inputHex, keyHex: keyHex,
                   ivHex: ivHex, mode: mode, padding: padding)
        }
        let mfB64ToBytes: @convention(block) (String) -> [Int] = { value in
            guard let data = Data(base64Encoded: value) else { return [] }
            return data.map { Int($0) }
        }
        let mfB64ToString: @convention(block) (String) -> String = { value in
            guard let data = Data(base64Encoded: value) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        let mfGetVar: @convention(block) (String) -> String = { pluginID in
            let raw = UserDefaults.standard.string(forKey: "mf.userVariables") ?? "{}"
            guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let variables = object[pluginID] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: variables, options: [.fragmentsAllowed]) else {
                return "{}"
            }
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        js.setObject(mfHTTP, forKeyedSubscript: "__mf_http__" as NSString)
        js.setObject(mfSetTimeout, forKeyedSubscript: "__mf_set_timeout__" as NSString)
        js.setObject(mfSetInterval, forKeyedSubscript: "__mf_set_interval__" as NSString)
        js.setObject(mfClearTimer, forKeyedSubscript: "__mf_clear_timeout__" as NSString)
        js.setObject(mfHash, forKeyedSubscript: "__mf_hash__" as NSString)
        js.setObject(mfHMAC, forKeyedSubscript: "__mf_hmac__" as NSString)
        js.setObject(mfAES, forKeyedSubscript: "__mf_aes__" as NSString)
        js.setObject(mfB64ToBytes, forKeyedSubscript: "__mf_b642ab__" as NSString)
        js.setObject(mfB64ToString, forKeyedSubscript: "__mf_b642str__" as NSString)
        js.setObject(mfGetVar, forKeyedSubscript: "__mf_get_var__" as NSString)
    }

    private func handleNativeCall(action: String, data: String) {
        guard let payloadData = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payloadData) else { return }
        if action == "cancelRequest", let requestKey = object as? String {
            if scriptRequestKeys.remove(requestKey) != nil {
                tasks.removeValue(forKey: requestKey)?.cancel()
            } else {
                cancelPendingRequest(with: requestKey)
            }
            return
        }
        guard let payload = object as? [String: Any] else { return }
        switch action {
        case "init":
            sourceInitializationTask?.cancel()
            sourceInitializationTask = nil
            pendingInitializationID = nil
            guard payload["status"] as? Bool != false else {
                let label = loadedKind == .musicFree ? "插件" : "LX 音源"
                let reason = payload["errorMessage"] as? String ?? "未提供原因"
                statusMessage = "\(label)初始化失败：\(reason)"
                DiagnosticLogger.shared.error(
                    "\(label)初始化失败: \(loadedName)（\(reason)）",
                    category: loadedKind == .musicFree ? "plugin" : "source"
                )
                context = nil
                return
            }
            if let info = payload["info"] as? [String: Any],
               let sources = info["sources"] as? [String: Any] {
                capabilities = sources.reduce(into: [:]) { result, pair in
                    guard let value = pair.value as? [String: Any] else { return }
                    let actions = value["actions"] as? [String] ?? []
                    result[pair.key] = actions
                }
                qualityCapabilities = sources.reduce(into: [:]) { result, pair in
                    guard let value = pair.value as? [String: Any] else { return }
                    result[pair.key] = value["qualitys"] as? [String] ?? []
                }
                let active = capabilities
                    .filter { !$0.value.isEmpty }
                    .map { "\($0.key): \($0.value.joined(separator: ", "))" }
                    .sorted()
                statusMessage = active.isEmpty
                    ? "音源已加载，但没有可用接口"
                    : "音源已加载（\(active.joined(separator: "；"))）"
                let label = loadedKind == .musicFree ? "MusicFree 插件" : "LX 音源"
                if active.isEmpty {
                    DiagnosticLogger.shared.warning(
                        "\(label)上报了能力表但没有可用接口: \(loadedName)",
                        category: loadedKind == .musicFree ? "plugin" : "source"
                    )
                } else {
                    DiagnosticLogger.shared.info(
                        "\(label)就绪: \(loadedName) 接口=[\(active.joined(separator: " ; "))]",
                        category: loadedKind == .musicFree ? "plugin" : "source"
                    )
                }
            } else {
                DiagnosticLogger.shared.warning(
                    "\(loadedKind == .musicFree ? "插件" : "音源")上报了 init 但没有能力表: \(loadedName)",
                    category: loadedKind == .musicFree ? "plugin" : "source"
                )
            }
        case "request":
            if let requestKey = payload["requestKey"] as? String,
               let url = payload["url"] as? String,
               let requestURL = URL(string: url) {
                scriptRequestKeys.insert(requestKey)
                sendScriptRequest(requestKey: requestKey, url: requestURL,
                                  options: payload["options"] as? [String: Any] ?? [:])
            }
        case "cancelRequest":
            if let requestKey = payload["requestKey"] as? String {
                if scriptRequestKeys.remove(requestKey) != nil {
                    tasks.removeValue(forKey: requestKey)?.cancel()
                } else {
                    cancelPendingRequest(with: requestKey)
                }
            }
        case "response":
            guard let requestKey = payload["requestKey"] as? String else { return }
            requestTimeoutTasks.removeValue(forKey: requestKey)?.cancel()
            if payload["status"] as? Bool == true, let result = payload["result"] as? [String: Any] {
                pending.removeValue(forKey: requestKey)?.resume(returning: result)
            } else {
                let message = payload["errorMessage"] as? String ?? "LX 音源没有返回有效响应"
                pending.removeValue(forKey: requestKey)?.resume(throwing: LXError.javascript(message))
            }
        default: break
        }
    }

    // MARK: - MusicFree plugin native bridge
    // These helpers are installed into every JSContext but are only called by
    // MusicFreePreload.js. LX sources keep using sendScriptRequest above.

    private func handleMusicFreeHTTP(_ json: String) {
        guard let bytes = json.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let urlString = payload["url"] as? String,
              let url = URL(string: urlString) else {
            callJS(action: "__mf_http_response__", data: ["error": "插件请求地址无效"])
            return
        }
        let requestID = payload["requestId"] as? String ?? UUID().uuidString
        let host = url.host ?? ""
        var request = URLRequest(url: url)
        request.httpMethod = ((payload["method"] as? String) ?? "GET").uppercased()
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        if let headers = payload["headers"] as? [String: Any] {
            headers.forEach { request.setValue(String(describing: $0.value), forHTTPHeaderField: $0.key) }
        }
        if let cookie = mfCookies[host]?.joined(separator: "; "), !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let body = payload["body"], !(body is NSNull) {
            if let text = body as? String {
                request.httpBody = Data(text.utf8)
            } else if JSONSerialization.isValidJSONObject(body) {
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            }
        }
        if let timeout = payload["timeout"] as? Double, timeout > 0 {
            request.timeoutInterval = min(timeout / 1000, 60)
        }
        let wantsBinary = payload["binary"] as? Bool == true
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.mfHTTPTasks.removeValue(forKey: requestID)
                let http = response as? HTTPURLResponse
                if let fields = http?.allHeaderFields {
                    var newCookies: [String] = []
                    for (key, value) in fields where String(describing: key).lowercased() == "set-cookie" {
                        newCookies.append(contentsOf: String(describing: value)
                            .components(separatedBy: ",")
                            .compactMap { $0.components(separatedBy: ";").first }
                            .filter { !$0.isEmpty })
                    }
                    if !newCookies.isEmpty {
                        var stored = self.mfCookies[host] ?? []
                        for cookie in newCookies {
                            let name = cookie.components(separatedBy: "=").first ?? ""
                            stored.removeAll { $0.components(separatedBy: "=").first == name }
                            stored.append(cookie)
                        }
                        self.mfCookies[host] = stored
                    }
                }
                var result: [String: Any] = [
                    "requestId": requestID,
                    "status": http?.statusCode ?? 0,
                    "statusText": HTTPURLResponse.localizedString(forStatusCode: http?.statusCode ?? 0),
                    "headers": (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) {
                        $0[String(describing: $1.key)] = String(describing: $1.value)
                    }
                ]
                if let error {
                    result["error"] = error.localizedDescription
                } else {
                    let raw = data ?? Data()
                    if wantsBinary {
                        result["data"] = raw.base64EncodedString()
                    } else if let json = try? JSONSerialization.jsonObject(with: raw) {
                        result["data"] = json
                    } else {
                        result["data"] = String(data: raw, encoding: .utf8) ?? ""
                    }
                }
                self.callJS(action: "__mf_http_response__", data: result)
            }
        }
        mfHTTPTasks[requestID] = task
        task.resume()
    }

    private func scheduleMusicFreeTimer(id: String, delayMS: Int, repeats: Bool) {
        mfTimers.removeValue(forKey: id)?.cancel()
        let delay = max(repeats ? 16 : 0, delayMS)
        mfTimers[id] = Task { @MainActor [weak self] in
            repeat {
                do {
                    try await Task.sleep(for: .milliseconds(delay))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.callJS(action: "__mf_timer__", data: ["timerId": id])
                if !repeats { self.mfTimers.removeValue(forKey: id); return }
            } while true
        }
    }

    /// Generic plugin method call. The JS side resolves the returned Promise
    /// and answers through the standard `response` action, so this reuses the
    /// same pending-continuation and timeout machinery as LX requests.
    func requestPlugin(method: String, args: [Any]) async throws -> [String: Any] {
        guard context != nil else { throw LXError.noSource }
        let requestKey = "plugin__\(UUID().uuidString)"
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[requestKey] = continuation
                callJS(action: "pluginInvoke",
                       data: ["requestKey": requestKey, "method": method, "args": args])
                requestTimeoutTasks[requestKey] = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    guard let self, self.pending[requestKey] != nil else { return }
                    self.cancelPendingRequest(with: requestKey,
                                              error: LXError.requestTimedOut(seconds: 20))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelPendingRequest(with: requestKey) }
        }
    }

    private func sendScriptRequest(requestKey: String, url: URL, options: [String: Any]) {
        guard scriptRequestKeys.contains(requestKey) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = (options["method"] as? String ?? "GET").uppercased()
        // Match LX Mobile's request helper. A number of source backends reject
        // URLSession's default identity or return HTML without these headers.
        request.setValue("Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let headers = options["headers"] as? [String: Any] {
            headers.forEach { request.setValue(String(describing: $0.value), forHTTPHeaderField: $0.key) }
        }
        let method = request.httpMethod ?? "GET"
        if let body = options["body"], !(body is NSNull) {
            if let string = body as? String {
                request.httpBody = Data(string.utf8)
            } else if JSONSerialization.isValidJSONObject(body) {
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            }
            if request.value(forHTTPHeaderField: "Content-Type") == nil,
               method == "POST" || method == "PUT" || method == "PATCH" {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        } else if let form = options["form"] as? [String: Any] {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(form.map { "\($0.key.lxFormEncoded)=\(String(describing: $0.value).lxFormEncoded)" }.joined(separator: "&").utf8)
        } else if let formData = options["formData"] as? String {
            // Some older LX sources pass an already encoded formData string.
            // Preserve it instead of silently dropping the POST body.
            request.httpBody = Data(formData.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }
        if let timeout = options["timeout"] as? Double, timeout > 0 { request.timeoutInterval = min(timeout / 1000, 60) }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self, self.scriptRequestKeys.remove(requestKey) != nil else { return }
                self.tasks.removeValue(forKey: requestKey)
                let rawBody = data ?? Data()
                let body: Any
                if options["binary"] as? Bool == true {
                    // Binary responses are not parsed. The current LX source
                    // bridge only uses textual/JSON responses, but preserving
                    // this branch keeps the User API contract intact.
                    body = String(data: rawBody, encoding: .utf8) ?? ""
                } else if let jsonBody = try? JSONSerialization.jsonObject(with: rawBody) {
                    // LX User API scripts expect response.body to behave like
                    // LX Mobile's request helper: JSON bodies are objects,
                    // while non-JSON bodies remain strings.
                    body = jsonBody
                } else {
                    body = String(data: rawBody, encoding: .utf8) ?? ""
                }
                let http = response as? HTTPURLResponse
                var result: [String: Any] = [
                    "requestKey": requestKey,
                    "response": ["statusCode": http?.statusCode ?? 0,
                                  "statusMessage": HTTPURLResponse.localizedString(forStatusCode: http?.statusCode ?? 0),
                                  "headers": (http?.allHeaderFields ?? [:]).reduce(into: [:]) { $0[String(describing: $1.key)] = String(describing: $1.value) },
                                  "body": body,
                                  "url": http?.url?.absoluteString ?? url.absoluteString,
                                  "ok": (200..<300).contains(http?.statusCode ?? 0)],
                ]
                if let error { result["error"] = error.localizedDescription }
                self.callJS(action: "response", data: result)
            }
        }
        tasks[requestKey] = task
        task.resume()
    }

    private func request(source: String,
                         action: String,
                         timeout: TimeInterval = 20,
                         info: [String: Any]) async throws -> [String: Any] {
        guard context != nil else { throw LXError.noSource }
        let requestKey = "request__\(UUID().uuidString)"
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[requestKey] = continuation
                callJS(action: "request", data: ["requestKey": requestKey,
                                                    "data": ["source": source, "action": action, "info": info]])
                requestTimeoutTasks[requestKey] = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                    } catch {
                        return
                    }
                    guard let self, self.pending[requestKey] != nil else { return }
                    self.cancelPendingRequest(
                        with: requestKey,
                        error: LXError.requestTimedOut(seconds: Int(timeout.rounded()))
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelPendingRequest(with: requestKey) }
        }
    }

    private func cancelPendingRequest(
        with requestKey: String,
        error: Error = CancellationError()
    ) {
        requestTimeoutTasks.removeValue(forKey: requestKey)?.cancel()
        // The root LX callback may currently be waiting on one or more
        // `lx.request` calls. Cancel child work and discard this JS context so
        // late Promise callbacks cannot attach to the next source operation.
        callJS(action: "cancelRequest", data: ["requestKey": requestKey])
        guard let continuation = pending.removeValue(forKey: requestKey) else { return }
        sourceInitializationTask?.cancel()
        sourceInitializationTask = nil
        pendingInitializationID = nil
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        mfHTTPTasks.values.forEach { $0.cancel() }
        mfHTTPTasks.removeAll()
        mfTimers.values.forEach { $0.cancel() }
        mfTimers.removeAll()
        scriptRequestKeys.removeAll()
        key = UUID().uuidString
        context = nil
        loadedID = nil
        loadedScript = nil
        capabilities = [:]
        qualityCapabilities = [:]
        statusMessage = "音源请求已取消，下次使用时重新加载"
        continuation.resume(throwing: error)
    }

    private func cancelPendingRequests() {
        sourceInitializationTask?.cancel()
        sourceInitializationTask = nil
        pendingInitializationID = nil
        for requestKey in Array(pending.keys) {
            cancelPendingRequest(with: requestKey)
        }
        requestTimeoutTasks.values.forEach { $0.cancel() }
        requestTimeoutTasks.removeAll()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        mfHTTPTasks.values.forEach { $0.cancel() }
        mfHTTPTasks.removeAll()
        mfTimers.values.forEach { $0.cancel() }
        mfTimers.removeAll()
        scriptRequestKeys.removeAll()
        context = nil
        loadedID = nil
        capabilities = [:]
        qualityCapabilities = [:]
        session.invalidateAndCancel()
    }

    /// `init` is delivered through a main-actor callback. A number of user API
    /// sources initialise through a short network request, so do not reject
    /// the first playback request before that response has had a chance to
    /// arrive.  We still stop after a bounded interval and report the source
    /// state instead of inventing capabilities.
    private func waitForSourceReady() async {
        guard loadedID != nil else { return }
        for _ in 0..<120 {
            if Task.isCancelled { return }
            if !capabilities.isEmpty || context == nil || pendingInitializationID == nil { return }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
    }

    /// Never leave the manager in a permanent loading state.  Crucially this
    /// timeout must not manufacture a platform/quality capability table: that
    /// made unsupported routes appear selectable and broke genuine playback.
    private func scheduleInitializationFallback(for sourceID: String) {
        sourceInitializationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled,
                  let self,
                  self.pendingInitializationID == sourceID,
                  self.loadedID == sourceID else { return }
            self.pendingInitializationID = nil
            self.statusMessage = "音源未在 6 秒内返回平台能力，请重新加载或更换音源"
        }
    }

    private func callJS(action: String, data: Any? = nil) {
        guard let context, let function = context.objectForKeyedSubscript("__lx_native__") else { return }
        // NSJSONSerialization throws an uncatchable NSException for a scalar
        // top-level value. `__set_timeout__` passes an Int, so encode through
        // SafeJSON, which validates first and emits a JSON fragment instead.
        let encoded = SafeJSON.encodedString(data)
        if let data, encoded == nil {
            DiagnosticLogger.shared.warning(
                "LX 回传数据无法安全序列化，已省略 data: action=\(action) type=\(type(of: data))",
                category: "source"
            )
        }
        let arguments: [Any]
        if let encoded {
            arguments = [key, action, encoded]
        } else {
            arguments = [key, action]
        }
        _ = function.call(withArguments: arguments)
    }

    private func sourceCandidates(for track: Track, action: String = "musicUrl") -> [String] {
        let primary = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        var values: [String] = []

        // Soda Music is a playlist-import format only. Its IDs are not sent
        // to an LX source as a playable platform; imported tracks are matched
        // against the real catalogue platforms below instead.
        if primary != "sd" {
            values.append(primary)
        }

        if primary == "sd" {
            values.append(contentsOf: ["wy", "kw", "kg", "tx", "mg"])
        } else if SettingsManager.shared.enableSourcePlatformFallback {
            values.append(contentsOf: ["wy", "kw", "kg", "tx", "mg"])
        }
        var seen = Set<String>()
        return values.filter { platform in
            capabilities[platform]?.contains(action) == true && seen.insert(platform).inserted
        }
    }

    private func activate(_ source: LXSourceStore.Source) async -> Bool {
        if loadedID != source.id || loadedScript != source.script || context == nil {
            load(source)
        }
        await waitForSourceReady()
        return loadedID == source.id && context != nil && !capabilities.isEmpty
    }

    private func validateSourceConfiguration(
        _ revision: Int,
        source: LXSourceStore.Source? = nil
    ) throws {
        let store = LXSourceStore.shared
        guard store.configurationRevision == revision else { throw CancellationError() }
        if let source,
           !store.playbackSources.contains(where: { $0.id == source.id && $0.script == source.script }) {
            throw CancellationError()
        }
    }

    /// Music URL, lyric and per-track quality requests all switch this single
    /// JavaScript context while awaiting source callbacks. Keep each complete
    /// operation exclusive so another request cannot replace its context/key
    /// and strand the first continuation until timeout.
    private func acquireSourceOperation() async throws {
        try Task.checkCancellation()
        guard sourceOperationActive else {
            sourceOperationActive = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sourceOperationWaiters.append(SourceOperationWaiter(id: id, continuation: continuation))
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancelSourceOperationWaiter(id) }
        }
    }

    private func cancelSourceOperationWaiter(_ id: UUID) {
        guard let index = sourceOperationWaiters.firstIndex(where: { $0.id == id }) else { return }
        sourceOperationWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func releaseSourceOperation() {
        if !sourceOperationWaiters.isEmpty {
            sourceOperationWaiters.removeFirst().continuation.resume()
            return
        }
        sourceOperationActive = false
        guard selectedSourceReloadPending else { return }
        selectedSourceReloadPending = false
        let forceReload = selectedSourceReloadForced
        selectedSourceReloadForced = false
        let source = LXSourceStore.shared.selectedSource
        guard forceReload || loadedID != source?.id || loadedScript != source?.script else { return }
        load(source)
    }

    private func invalidateSourceWork() {
        sourceInitializationTask?.cancel()
        sourceInitializationTask = nil
        pendingInitializationID = nil
        for requestKey in Array(pending.keys) {
            cancelPendingRequest(with: requestKey)
        }
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        mfHTTPTasks.values.forEach { $0.cancel() }
        mfHTTPTasks.removeAll()
        mfTimers.values.forEach { $0.cancel() }
        mfTimers.removeAll()
        scriptRequestKeys.removeAll()
        context = nil
        loadedID = nil
        loadedScript = nil
        capabilities = [:]
        qualityCapabilities = [:]
        // Route health describes the previous source configuration; a new or
        // edited script deserves a fresh measurement.
        slowRouteFailures.removeAll()
        // Cached links were produced by the previous source configuration; a
        // disabled or edited source must not keep serving them.
        cancelPrefetch()
        resolutionCache.removeAll()
        statusMessage = "音源配置已更新"
        if sourceOperationActive {
            selectedSourceReloadPending = true
        }
    }

    private func canonicalPlatform(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        switch value {
        case "wy", "163", "netease", "neteasecloudmusic", "netease-cloud-music", "cloudmusic":
            return "wy"
        case "kw", "kuwo": return "kw"
        case "kg", "kugou": return "kg"
        case "tx", "qq", "qqmusic", "qq-music": return "tx"
        case "mg", "migu": return "mg"
        case "sd", "soda", "sodamusic", "soda-music", "qishui", "qishui-music": return "sd"
        default: return value
        }
    }

    /// This is only request metadata for the source's health check. It is not
    /// a playback catalogue and it never leaves the device except as part of
    /// the user-selected source's own `musicUrl` request.
    static func sourceCheckTrack(for platform: String) -> Track? {
        guard platform == "wy" else { return nil }
        return Track(
            id: 186_016,
            name: "晴天",
            artists: [ArtistRef(id: 1, name: "周杰伦")],
            album: AlbumRef(id: 0, name: "音源连通性测试", picUrl: nil),
            durationMS: 269_000,
            source: platform,
            sourceMetadata: [
                "id": "186016",
                "songmid": "186016",
                "songId": "186016",
                "copyrightId": "186016",
            ]
        )
    }

    // Canonical LX quality tokens, ordered from lowest to highest. Source-specific
    // names are normalized into this list only when the imported source declares them.
    private static let qualityOrder = ["128k", "320k", "flac", "flac24bit", "surround", "dolby", "atmos", "jymaster"]

    func availableQualityNames(for track: Track) async -> [String] {
        let resolver = Self.qualityResolver
        do {
            try await resolver.acquireSourceOperation()
        } catch {
            return []
        }
        defer { resolver.releaseSourceOperation() }
        guard !Task.isCancelled else { return [] }
        return await resolver.resolveAvailableQualityNames(for: track)
    }

    private func resolveAvailableQualityNames(for track: Track) async -> [String] {
        let store = LXSourceStore.shared
        let sourceRevision = store.configurationRevision
        let playbackSources = store.playbackSources
        let primaryPlatform = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        var available = Set<String>()
        for source in playbackSources {
            guard !Task.isCancelled,
                  store.configurationRevision == sourceRevision,
                  store.playbackSources.contains(where: {
                      $0.id == source.id && $0.script == source.script
                  }) else { return [] }
            guard await activate(source) else { continue }
            guard !Task.isCancelled,
                  store.configurationRevision == sourceRevision,
                  store.playbackSources.contains(where: {
                      $0.id == source.id && $0.script == source.script
                  }) else { return [] }
            let platforms = sourceCandidates(for: track, action: "musicUrl")
            // Quality probing is per-song and performs real network requests.
            // Probe the track's own catalogue first; only use one fallback
            // catalogue when that source cannot serve the primary platform.
            // This keeps the picker accurate without turning it into dozens of
            // cross-platform requests every time the sheet opens.
            let platformsToProbe = platforms.contains(primaryPlatform)
                ? [primaryPlatform]
                : Array(platforms.prefix(1))
            for platform in platformsToProbe {
                let qualityTrack: Track
                if platform == primaryPlatform {
                    qualityTrack = track
                } else {
                    guard let matched = await LXCatalogService.matchingTrack(track, on: platform) else { continue }
                    guard !Task.isCancelled,
                          store.configurationRevision == sourceRevision,
                          store.playbackSources.contains(where: {
                              $0.id == source.id && $0.script == source.script
                          }) else { return [] }
                    qualityTrack = matched
                }
                let declaredQualities = supportedQualityNames(for: qualityTrack, platform: platform)
                // `qualitys` describes what the adapter claims to support,
                // not what this particular song actually has.  Probe the
                // song's musicUrl response before exposing a quality picker;
                // otherwise a source that declares lossless/master globally
                // makes a 128K-only track advertise unavailable tiers.
                available.formUnion(await probeQualityNames(
                    source: source,
                    platform: platform,
                    track: qualityTrack,
                    declared: declaredQualities,
                    sourceRevision: sourceRevision
                ))
                guard store.configurationRevision == sourceRevision else { return [] }
            }
        }
        let order = Self.qualityOrder
        // The UI is best-first; protocol requests still use the canonical order.
        return order.reversed().filter(available.contains)
    }

    private func probeQualityNames(
        source: LXSourceStore.Source,
        platform: String,
        track: Track,
        declared: [String],
        sourceRevision: Int
    ) async -> Set<String> {
        guard !Task.isCancelled,
              LXSourceStore.shared.configurationRevision == sourceRevision,
              LXSourceStore.shared.playbackSources.contains(where: {
                  $0.id == source.id && $0.script == source.script
              }) else { return [] }
        guard await activate(source) else { return [] }
        guard !Task.isCancelled,
              LXSourceStore.shared.configurationRevision == sourceRevision,
              LXSourceStore.shared.playbackSources.contains(where: {
                  $0.id == source.id && $0.script == source.script
              }) else { return [] }
        let requestedQualities = declared.isEmpty ? ["128k"] : declared
        var requestable = Set<String>()

        for requested in requestedQualities {
            guard !Task.isCancelled,
                  LXSourceStore.shared.configurationRevision == sourceRevision,
                  LXSourceStore.shared.playbackSources.contains(where: {
                      $0.id == source.id && $0.script == source.script
                  }) else { break }
            do {
                let response = try await request(
                    source: platform,
                    action: "musicUrl",
                    info: [
                        "type": protocolQualityToken(requested, platform: platform),
                        "musicInfo": musicInfo(
                            for: track,
                            platform: platform,
                            qualities: requestedQualities
                        )
                    ]
                )
                guard LXSourceStore.shared.configurationRevision == sourceRevision,
                      let data = response["data"] as? [String: Any],
                      let rawURL = data["url"] as? String,
                      let url = URL(string: rawURL),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else { continue }

                // LX's bridge returns a URL and echoes the requested tier,
                // but does not expose the provider's actual codec/bitrate.
                // This only establishes that the source accepted the request.
                requestable.insert(Self.normalizedQuality(requested))
            } catch {
                if error is CancellationError { break }
                guard LXSourceStore.shared.configurationRevision == sourceRevision else { break }
            }
        }

        return requestable
    }

    private func isValidAudioURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Return the qualities that can be requested for this track.
    ///
    /// LX source `qualitys` describes the source adapter's capabilities, while
    /// catalogue file sizes describe the individual song.  Use both when the
    /// catalogue knows the song.  When it does not, the declaration is only a
    /// probe candidate; `probeQualityNames` must receive a matching URL for
    /// the request before the tier reaches the UI. LX sources cannot confirm
    /// the actual file quality.
    private func supportedQualityNames(for track: Track, platform: String) -> [String] {
        let order = Self.qualityOrder
        let declared = qualityCapabilities[platform, default: []]
            .map { Self.normalizedQuality($0) }
            .filter { order.contains($0) }
        let sourceNames = declared.isEmpty ? ["128k"] : order.filter(declared.contains)
        let concrete = Self.qualityNames(for: track)

        if !concrete.isEmpty {
            return order.filter { sourceNames.contains($0) && concrete.contains($0) }
        }

        return sourceNames
    }

    /// Preserve the token expected by the selected LX script. The UI treats
    /// aliases such as master/jymaster as one tier, but the request keeps the
    /// exact token advertised by the active source.
    private func protocolQualityToken(_ quality: String, platform: String) -> String {
        let canonical = Self.normalizedQuality(quality)
        return qualityCapabilities[platform, default: []].first {
            Self.normalizedQuality($0) == canonical
        } ?? quality
    }

    private func musicInfo(for track: Track, platform: String,
                           qualities requestedQualities: [String]? = nil) -> [String: Any] {
        // LX's User API receives the legacy MusicInfo object, not Kumone's
        // internal Track. This mirrors LX Mobile's toOldMusicInfo() exactly.
        let songmid = track.sourceMetadata["songmid"]
            ?? track.sourceMetadata["songId"]
            ?? String(track.id)
        let albumID = track.sourceMetadata["albumId"] ?? String(track.album.id)
        let canonicalQualities = requestedQualities?.isEmpty == false
            ? requestedQualities!
            : (Self.qualityNames(for: track).isEmpty ? ["128k"] : Self.qualityNames(for: track))
        let qualities = canonicalQualities.map { protocolQualityToken($0, platform: platform) }
        let qualityInfo = canonicalQualities.enumerated().map { index, canonical in
            let protocolToken = qualities[index]
            let size = track.sourceMetadata["lx.quality.\(canonical).size"]
                ?? track.sourceMetadata["lx.quality.\(protocolToken).size"]
                ?? ""
            return ["type": protocolToken, "size": size] as [String: Any]
        }
        let qualityMap = Dictionary(uniqueKeysWithValues: canonicalQualities.enumerated().map { index, canonical in
            let protocolToken = qualities[index]
            let size = track.sourceMetadata["lx.quality.\(canonical).size"]
                ?? track.sourceMetadata["lx.quality.\(protocolToken).size"]
                ?? ""
            return (protocolToken, ["size": size] as [String: Any])
        })
        var info: [String: Any] = [
            "name": track.name,
            "singer": track.artistNames,
            "source": platform,
            "songmid": songmid,
            "interval": String(format: "%02d:%02d", Int(track.duration) / 60, Int(track.duration) % 60),
            "albumName": track.album.name,
            "img": track.album.picUrl ?? "",
            "typeUrl": [:] as [String: String],
            "albumId": albumID,
            "types": qualityInfo,
            "_types": qualityMap,
            // MusicFree plugins receive the original item they produced for
            // search results. LX sources simply ignore these extra keys.
            "mfItem": track.sourceMetadata["mf.itemJSON"] ?? "",
            "mfPlatform": track.sourceMetadata["mf.platform"] ?? track.source ?? "",
        ]
        switch platform {
        case "kg":
            info["hash"] = track.sourceMetadata["hash"] ?? ""
            info["albumId"] = track.sourceMetadata["albumId"] ?? albumID
            info["albumAudioId"] = track.sourceMetadata["albumAudioId"]
                ?? track.sourceMetadata["albumAudioID"]
                ?? track.sourceMetadata["mixsongid"]
        case "tx":
            info["songId"] = Int(track.sourceMetadata["id"] ?? "") ?? track.id
            info["strMediaMid"] = track.sourceMetadata["strMediaMid"]?.isEmpty == false
                ? track.sourceMetadata["strMediaMid"]!
                : (track.sourceMetadata["media_mid"] ?? "")
            info["albumMid"] = track.sourceMetadata["albumMid"] ?? ""
        case "mg":
            info["copyrightId"] = track.sourceMetadata["copyrightId"] ?? songmid
            for key in ["lrcUrl", "mrcUrl", "trcUrl"] {
                if let value = track.sourceMetadata[key], !value.isEmpty { info[key] = value }
            }
        default:
            break
        }
        return info
    }

    private static func qualityNames(for track: Track) -> [String] {
        let order = Self.qualityOrder
        let concrete = order.filter { quality in
            guard let value = track.sourceMetadata["lx.quality.\(quality).size"] else { return false }
            return hasPositiveFileSize(value)
        }
        return concrete
    }

    private static func hasPositiveFileSize(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let match = normalized.range(of: #"^[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression),
              let number = Double(String(normalized[match])), number > 0 else { return false }
        return true
    }

    private static func lxQuality(for quality: String, supported: [String]) -> String {
        let requested: String
        switch quality {
        case "master": requested = "jymaster"
        case "atmos": requested = "atmos"
        case "dolby": requested = "dolby"
        case "surround": requested = "surround"
        case "standard": requested = "128k"
        case "higher", "exhigh": requested = "320k"
        case "lossless": requested = "flac"
        case "hires": requested = "flac24bit"
        default: requested = "320k"
        }
        guard !supported.isEmpty else { return "128k" }
        let order = Self.qualityOrder
        guard let requestedIndex = order.firstIndex(of: Self.normalizedQuality(requested)) else { return supported[0] }
        return order[...requestedIndex].reversed().first(where: supported.contains)
            ?? supported.first
            ?? "128k"
    }
    private static func normalizedQuality(_ value: String) -> String {
        let value = value.lowercased().replacingOccurrences(of: " ", with: "")
        switch value {
        case "128", "128k", "mp3": return "128k"
        case "320", "320k": return "320k"
        case "flac", "lossless", "ape": return "flac"
        case "flac24", "flac24bit", "hires", "highres": return "flac24bit"
        case "master", "jymaster", "master_quality", "master-quality": return "jymaster"
        case "atmos", "immersive": return "atmos"
        case "dolby", "dolby-atmos", "dolbyatmos": return "dolby"
        case "surround", "spatial", "spatial-audio": return "surround"
        default: return value
        }
    }
    private static func resolvedQuality(returned: String?, requested: String,
                                        available _: [String]) -> String {
        guard let returned else { return requested }
        let normalized = normalizedQuality(returned)
        let order = Self.qualityOrder
        guard let requestedIndex = order.firstIndex(of: normalizedQuality(requested)),
              let returnedIndex = order.firstIndex(of: normalized),
              returnedIndex <= requestedIndex else { return requested }
        return normalized
    }
}

private extension String {
    var lxFormEncoded: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

private func md5Hex(_ value: String) -> String {
    var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    let data = Data(value.utf8)
    data.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }
    return digest.map { String(format: "%02x", $0) }.joined()
}

private func aesEncrypt(input: String, key: String, iv: String, mode: String) -> String {
    guard let inputData = Data(base64Encoded: input), let keyData = Data(base64Encoded: key) else { return "" }
    let ivData = Data(base64Encoded: iv) ?? Data(repeating: 0, count: kCCBlockSizeAES128)
    let options: CCOptions = mode == "AES"
        ? CCOptions(kCCOptionECBMode)
        : CCOptions(kCCOptionPKCS7Padding)
    var output = [UInt8](repeating: 0, count: inputData.count + kCCBlockSizeAES128)
    var moved = 0
    let status = inputData.withUnsafeBytes { inputBuffer in
        keyData.withUnsafeBytes { keyBuffer in
            ivData.withUnsafeBytes { ivBuffer in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), options,
                        keyBuffer.baseAddress, keyData.count, mode == "AES" ? nil : ivBuffer.baseAddress,
                        inputBuffer.baseAddress, inputData.count, &output, output.count, &moved)
            }
        }
    }
    guard status == kCCSuccess else { return "" }
    return Data(output.prefix(moved)).base64EncodedString()
}

private func rsaEncrypt(input: String, publicKey: String, padding: String) -> String {
    guard let inputData = Data(base64Encoded: input), let keyData = Data(base64Encoded: publicKey) else { return "" }
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                       kSecAttrKeyClass: kSecAttrKeyClassPublic]
    guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil) else { return "" }
    let algorithm: SecKeyAlgorithm = padding == "RSA/ECB/NoPadding" ? .rsaEncryptionRaw : .rsaEncryptionOAEPSHA1
    guard let encrypted = SecKeyCreateEncryptedData(key, algorithm, inputData as CFData, nil) as Data? else { return "" }
    return encrypted.base64EncodedString()
}

// MARK: - MusicFree crypto facade (CommonCrypto, no third-party libraries)

private func hexData(_ hex: String) -> Data? {
    guard hex.count % 2 == 0 else { return nil }
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
        data.append(byte)
        index = next
    }
    return data
}

private func hashedHex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func hashHex(algorithm: String, text: String) -> String {
    let data = Data(text.utf8)
    let count = data.count
    switch algorithm.lowercased() {
    case "md5":
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(count), &digest) }
        return hashedHex(digest)
    case "sha1":
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(count), &digest) }
        return hashedHex(digest)
    case "sha224":
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA224($0.baseAddress, CC_LONG(count), &digest) }
        return hashedHex(digest)
    case "sha384":
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA384_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA384($0.baseAddress, CC_LONG(count), &digest) }
        return hashedHex(digest)
    case "sha512":
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA512($0.baseAddress, CC_LONG(count), &digest) }
        return hashedHex(digest)
    default:
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(count), &digest) }
        return hashedHex(digest)
    }
}

private func hmacHex(algorithm: String, text: String, key: Data) -> String {
    let algorithmType: CCHmacAlgorithm
    let length: Int
    switch algorithm.lowercased() {
    case "md5": (algorithmType, length) = (CCHmacAlgorithm(kCCHmacAlgMD5), Int(CC_MD5_DIGEST_LENGTH))
    case "sha1": (algorithmType, length) = (CCHmacAlgorithm(kCCHmacAlgSHA1), Int(CC_SHA1_DIGEST_LENGTH))
    case "sha512": (algorithmType, length) = (CCHmacAlgorithm(kCCHmacAlgSHA512), Int(CC_SHA512_DIGEST_LENGTH))
    default: (algorithmType, length) = (CCHmacAlgorithm(kCCHmacAlgSHA256), Int(CC_SHA256_DIGEST_LENGTH))
    }
    var digest = [UInt8](repeating: 0, count: length)
    let textData = Data(text.utf8)
    key.withUnsafeBytes { keyBuffer in
        textData.withUnsafeBytes { textBuffer in
            CCHmac(algorithmType, keyBuffer.baseAddress, key.count,
                   textBuffer.baseAddress, textData.count, &digest)
        }
    }
    return hashedHex(digest)
}

private func aesHex(operation: String, inputHex: String, keyHex: String,
                    ivHex: String, mode: String, padding: String) -> String {
    guard let input = hexData(inputHex), let key = hexData(keyHex) else { return "" }
    let iv = hexData(ivHex) ?? Data(repeating: 0, count: kCCBlockSizeAES128)
    let isEncrypt = operation.lowercased() == "encrypt"
    var options: CCOptions = padding.lowercased() == "nopadding"
        ? CCOptions(0) : CCOptions(kCCOptionPKCS7Padding)
    if mode.uppercased() == "ECB" { options |= CCOptions(kCCOptionECBMode) }
    var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128 * 2)
    var moved = 0
    let status = input.withUnsafeBytes { inputBuffer in
        key.withUnsafeBytes { keyBuffer in
            iv.withUnsafeBytes { ivBuffer in
                CCCrypt(isEncrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES), options,
                        keyBuffer.baseAddress, key.count,
                        mode.uppercased() == "ECB" ? nil : ivBuffer.baseAddress,
                        inputBuffer.baseAddress, input.count,
                        &output, output.count, &moved)
            }
        }
    }
    guard status == kCCSuccess else { return "" }
    return hashedHex(Array(output.prefix(moved)))
}
#endif
