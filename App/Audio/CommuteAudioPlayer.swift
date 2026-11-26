import AVFoundation
import Combine
import Foundation
import MediaPlayer
import UIKit

@MainActor
final class CommuteAudioPlayer: ObservableObject {
    private struct CatalogCache: Codable {
        let date: Date
        let items: [CommuteAudioItem]
    }

    @Published var workMode: CommuteListening {
        didSet { defaults.set(workMode.rawValue, forKey: "audio.work") }
    }
    @Published var homeMode: CommuteListening {
        didSet { defaults.set(homeMode.rawValue, forKey: "audio.home") }
    }
    @Published private(set) var clientID: String
    @Published private(set) var nowPlaying: CommuteAudioItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var playbackError: String?
    @Published private(set) var loading: Set<CommuteListening> = []
    @Published private(set) var catalogErrors: [CommuteListening: String] = [:]
    @Published private(set) var neteaseSignedIn = false
    @Published private(set) var neteaseFavorites = false
    @Published private var catalogs: [CommuteListening: CatalogCache] = [:]

    private let defaults = UserDefaults.standard
    private let logger: AppLogger
    private let player = AVPlayer()
    private var queue: [CommuteAudioItem] = []
    private var index = 0
    private var progress: [String: Double]
    private var rateObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var observers: Set<AnyCancellable> = []
    private var timeObserver: Any?
    private var remotes: [(MPRemoteCommand, Any)] = []
    private var neteaseCookie: String?
    private var neteaseCatalogID = UUID()
    private var pendingPlayback: Task<Void, Never>?

    init(logger: AppLogger) {
        self.logger = logger
        let settings = UserDefaults.standard
        workMode = CommuteListening(rawValue: settings.string(forKey: "audio.work") ?? "") ?? .off
        homeMode = CommuteListening(rawValue: settings.string(forKey: "audio.home") ?? "") ?? .off
        clientID = settings.string(forKey: "audio.jamendoClientID") ?? ""
        progress = settings.dictionary(forKey: "audio.podcastProgress") as? [String: Double] ?? [:]
        neteaseCookie = NeteaseAudioCatalog.savedCookie()
        neteaseSignedIn = neteaseCookie != nil
        neteaseFavorites = neteaseSignedIn && settings.bool(forKey: "audio.neteaseFavorites")
        for mode in [CommuteListening.podcast, .music] {
            if let data = defaults.data(forKey: cacheKey(mode)),
               let cache = try? JSONDecoder().decode(CatalogCache.self, from: data) {
                catalogs[mode] = cache
            }
        }
        configurePlaybackObservers()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        for (command, token) in remotes { command.removeTarget(token) }
    }

    func items(for mode: CommuteListening) -> [CommuteAudioItem] { catalogs[mode]?.items ?? [] }

    func setClientID(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != clientID else { return }
        clientID = value
        defaults.set(value, forKey: "audio.jamendoClientID")
        defaults.removeObject(forKey: cacheKey(.music))
        catalogs[.music] = nil
        catalogErrors[.music] = nil
    }

    func refreshEnabled() async {
        for mode in Set([workMode, homeMode]) where mode != .off {
            await refresh(mode)
        }
    }

    func refresh(_ mode: CommuteListening, force: Bool = false) async {
        guard mode != .off, !loading.contains(mode) else { return }
        if mode == .netease {
            await refreshNetease(force: force)
            return
        }
        if !force, let cache = catalogs[mode], Calendar.current.isDateInToday(cache.date) { return }
        let requestedClientID = clientID
        guard mode != .music || !requestedClientID.isEmpty else { return }

        loading.insert(mode)
        catalogErrors[mode] = nil
        defer { loading.remove(mode) }
        do {
            let items = if mode == .podcast {
                try await CommuteAudioCatalog.episodes()
            } else {
                try await CommuteAudioCatalog.popularTracks(clientID: requestedClientID)
            }
            try Task.checkCancellation()
            guard mode != .music || clientID == requestedClientID else { return }
            let cache = CatalogCache(date: .now, items: items)
            catalogs[mode] = cache
            defaults.set(try JSONEncoder().encode(cache), forKey: cacheKey(mode))
            logger.record("通勤音频目录已更新：\(mode.title)，\(items.count) 项")
        } catch {
            guard !Task.isCancelled, mode != .music || clientID == requestedClientID else { return }
            catalogErrors[mode] = "更新\(mode.title)失败，请稍后重试。"
            logger.record("通勤音频目录更新失败：\(mode.title)", level: .error)
        }
    }

    func playForCommute(toWork: Bool) {
        let mode = toWork ? workMode : homeMode
        guard mode != .off else { return }
        if nowPlaying?.kind == mode, player.currentItem != nil, playbackError == nil {
            resume()
            return
        }
        if mode == .netease, items(for: mode).isEmpty {
            prepareNeteaseCommute()
            return
        }
        playCommuteItem(mode)
    }

    private func playCommuteItem(_ mode: CommuteListening) {
        let items = items(for: mode)
        let first: CommuteAudioItem?
        if mode == .podcast {
            first = items.first { (progress[$0.id] ?? 0) > 0 }
                ?? items.first { (progress[$0.id] ?? 0) >= 0 }
        } else if !items.isEmpty {
            let day = Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
            first = items[day % items.count]
        } else {
            first = nil
        }
        guard let first else {
            logger.record("没有可用的\(mode.title)条目，通勤继续导航")
            return
        }
        play(first)
    }

    func play(_ item: CommuteAudioItem) {
        saveProgress()
        queue = items(for: item.kind)
        if let selectedIndex = queue.firstIndex(where: { $0.id == item.id }) {
            index = selectedIndex
        } else {
            queue = [item]
            index = 0
        }
        startCurrent()
    }

    func toggle() {
        if isPlaying || pendingPlayback != nil { pause() } else if player.currentItem == nil, let nowPlaying {
            play(nowPlaying)
        } else { resume() }
    }

    func pause() {
        pendingPlayback?.cancel()
        pendingPlayback = nil
        player.pause()
        isPlaying = false
        saveProgress()
        updateNowPlaying()
    }

    func resume() {
        guard player.currentItem != nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: .mixWithOthers)
            try session.setActive(true)
            player.play()
            isPlaying = true
            updateNowPlaying()
        } catch {
            reportPlaybackFailure()
        }
    }

    func next() {
        saveProgress()
        advance()
    }

    func saveProgress() {
        guard let nowPlaying, nowPlaying.kind == .podcast else { return }
        let time = player.currentTime().seconds
        guard time.isFinite, time > 0 else { return }
        progress[nowPlaying.id] = time
        defaults.set(progress, forKey: "audio.podcastProgress")
    }

    private func startCurrent() {
        guard queue.indices.contains(index) else { return }
        pendingPlayback?.cancel()
        pendingPlayback = nil
        let item = queue[index]
        playbackError = nil
        elapsed = item.kind == .podcast ? max(0, progress[item.id] ?? 0) : 0
        nowPlaying = item
        if item.kind == .netease, let expiry = item.expiresAt, expiry <= .now {
            player.pause()
            player.replaceCurrentItem(with: nil)
            let cookie = neteaseCookie
            pendingPlayback = Task {
                await withPlaybackTime {
                    do {
                        let url = try await NeteaseAudioCatalog.stream(for: item, cookie: cookie)
                        try Task.checkCancellation()
                        pendingPlayback = nil
                        startPlayback(item, url: url)
                    } catch {
                        guard !Task.isCancelled else { return }
                        reportPlaybackFailure("网易云暂时无法播放该曲目，请刷新歌单或选择其他歌曲。")
                    }
                }
            }
        } else {
            startPlayback(item, url: item.stream)
        }
    }

    private func startPlayback(_ item: CommuteAudioItem, url: URL) {
        let asset = AVPlayerItem(url: url)
        itemObservation = asset.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard observed.status == .failed else { return }
            Task { @MainActor in
                guard let self, observed === self.player.currentItem else { return }
                self.reportPlaybackFailure()
            }
        }
        player.replaceCurrentItem(with: asset)
        if elapsed > 0 {
            player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600))
        }
        logger.record("通勤音频开始：\(item.kind.title)")
        resume()
    }

    private func advance() {
        if index + 1 < queue.count {
            index += 1
            startCurrent()
        } else {
            stop()
        }
    }

    private func stop() {
        pendingPlayback?.cancel()
        pendingPlayback = nil
        itemObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        nowPlaying = nil
        elapsed = 0
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func reportPlaybackFailure(_ message: String = "音频无法播放，请重试或选择其他内容。") {
        stop()
        playbackError = message
        logger.record("通勤音频播放失败", level: .error)
    }

    private func configurePlaybackObservers() {
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = self.player.timeControlStatus != .paused
                self.updateNowPlaying()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let time = self.player.currentTime().seconds
                guard time.isFinite else { return }
                self.elapsed = time
                if let item = self.nowPlaying, item.kind == .podcast, time - (self.progress[item.id] ?? 0) >= 15 {
                    self.saveProgress()
                }
                self.updateNowPlaying()
            }
        }
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self, let item = event.object as? AVPlayerItem, item === self.player.currentItem else { return }
                if let episode = self.nowPlaying, episode.kind == .podcast {
                    self.progress[episode.id] = -1
                    self.defaults.set(self.progress, forKey: "audio.podcastProgress")
                }
                self.advance()
            }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self, let item = event.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.reportPlaybackFailure()
            }
            .store(in: &observers)

        let center = MPRemoteCommandCenter.shared()
        remotes = [
            (center.playCommand, center.playCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.resume() }
                return .success
            }),
            (center.pauseCommand, center.pauseCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.pause() }
                return .success
            }),
            (center.togglePlayPauseCommand, center.togglePlayPauseCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.toggle() }
                return .success
            }),
            (center.nextTrackCommand, center.nextTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor in self?.next() }
                return .success
            })
        ]
    }

    private func updateNowPlaying() {
        guard let nowPlaying else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlaying.title,
            MPMediaItemPropertyArtist: nowPlaying.author,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .playing ? player.rate : 0
        ]
        if let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func cacheKey(_ mode: CommuteListening) -> String { "audio.catalog." + mode.rawValue }

    func authorizeNetease(_ cookie: String) throws {
        try NeteaseAudioCatalog.saveCookie(cookie)
        neteaseCookie = cookie
        neteaseSignedIn = true
        setNeteaseFavorites(true)
        logger.record("网易云账号已登录")
    }

    func recordNeteaseSignIn(_ message: String, failed: Bool = false) {
        logger.record("网易云扫码登录：\(message)", level: failed ? .error : .info)
    }

    func forgetNetease() throws {
        try NeteaseAudioCatalog.forgetCookie()
        neteaseCookie = nil
        neteaseSignedIn = false
        setNeteaseFavorites(false)
        logger.record("网易云本机登录已清除")
    }

    func setNeteaseFavorites(_ value: Bool) {
        neteaseFavorites = value && neteaseSignedIn
        defaults.set(neteaseFavorites, forKey: "audio.neteaseFavorites")
        neteaseCatalogID = UUID()
        catalogs[.netease] = nil
        catalogErrors[.netease] = nil
        loading.remove(.netease)
        if nowPlaying?.kind == .netease || pendingPlayback != nil { stop() }
        if queue.first?.kind == .netease { queue = [] }
    }

    private func refreshNetease(force: Bool) async {
        if !force, let cache = catalogs[.netease],
           Calendar.current.isDateInToday(cache.date),
           cache.items.contains(where: { ($0.expiresAt ?? .distantPast) > .now }) { return }
        let requestID = neteaseCatalogID
        loading.insert(.netease)
        catalogErrors[.netease] = nil
        defer {
            if requestID == neteaseCatalogID { loading.remove(.netease) }
        }
        do {
            let tracks = try await NeteaseAudioCatalog.tracks(cookie: neteaseCookie, favorites: neteaseFavorites)
            try Task.checkCancellation()
            guard requestID == neteaseCatalogID else { return }
            catalogs[.netease] = CatalogCache(date: .now, items: tracks)
            logger.record("网易云目录已更新，\(tracks.count) 首可播")
        } catch {
            guard !Task.isCancelled, requestID == neteaseCatalogID else { return }
            switch error {
            case NeteaseAudioCatalog.Failure.signedOut:
                catalogs[.netease] = nil
                catalogErrors[.netease] = "网易云登录已失效，请退出后重新扫码。"
            default:
                catalogErrors[.netease] = "网易云歌单更新失败，请稍后重试。"
            }
            logger.record("网易云目录更新失败", level: .error)
        }
    }

    private func prepareNeteaseCommute() {
        pendingPlayback?.cancel()
        pendingPlayback = Task {
            await withPlaybackTime {
                if loading.contains(.netease) {
                    for _ in 0..<16 {
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else { return }
                        if !loading.contains(.netease) { break }
                    }
                } else {
                    await refresh(.netease)
                }
                guard !Task.isCancelled else { return }
                pendingPlayback = nil
                playCommuteItem(.netease)
            }
        }
    }

    private func withPlaybackTime(_ operation: () async -> Void) async {
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "通勤音频准备") { [weak self] in
            self?.pendingPlayback?.cancel()
            self?.pendingPlayback = nil
        }
        defer {
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
        await operation()
    }
}
