import ActivityKit
import AVFoundation
import CoreMotion

/// 이어폰 음성 안내.
/// 잠금화면 실시간 현황이 켜져 있는 동안 앱이 백그라운드에 남아(무음 오디오), 이어폰이 연결돼 있을 때만
/// N분마다 ‘출발까지 N분’을 직접 말한다. (Siri 알림 읽어주기는 이 앱 알림을 읽지 않아서 직접 말하는 방식)
/// 열차에 타서 움직이기 시작하면(동작 감지: 차량 이동) 안내를 멈추고, 퇴근 실시간 현황도 끈다.
@MainActor
final class VoiceGuide: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = VoiceGuide()

    private let synthesizer = AVSpeechSynthesizer()
    private let motion = CMMotionActivityManager()
    private var silentPlayer: AVAudioPlayer?
    private var loop: Task<Void, Never>?
    private var motionRunning = false
    private var lastSpokenMinute = -1

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - 시작·중지

    /// 음성 안내가 켜진 노선의 실시간 현황이 떠 있으면 안내를 시작, 아니면 멈춘다.
    func sync() {
        if activeRoute() != nil { start() } else { stop() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        silentPlayer?.stop()
        silentPlayer = nil
        if motionRunning {
            motion.stopActivityUpdates()
            motionRunning = false
        }
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 열차 탑승 감지를 쓰려면 ‘동작 및 피트니스’ 권한이 필요하다. 앱을 열었을 때 한 번 물어본다.
    func requestMotionPermissionIfNeeded() {
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .notDetermined else { return }
        let now = Date()
        motion.queryActivityStarting(from: now.addingTimeInterval(-60), to: now, to: .main) { _, _ in }
    }

    private func start() {
        guard loop == nil else { return }
        lastSpokenMinute = TimeText.minutesOfDay(Date())
        configureSession(duck: false)
        startSilence()
        startMotion()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    // MARK: - 안내

    private static func stoppedKey(_ routeID: String) -> String { "voiceStopped-\(routeID)" }

    /// 실시간 현황이 떠 있고 음성 안내가 켜진 노선 (오늘 탑승해서 멈춘 노선 제외)
    private func activeRoute() -> Route? {
        let running = Set(Activity<CommuteActivityAttributes>.activities.map(\.attributes.routeID))
        guard !running.isEmpty, let routes = SharedData.loadRoutes() else { return nil }
        let today = RailSync.todayKey()
        return routes.first {
            $0.voiceEnabled
                && running.contains($0.id.uuidString)
                && UserDefaults.standard.string(forKey: Self.stoppedKey($0.id.uuidString)) != today
        }
    }

    private func tick() {
        guard let route = activeRoute() else {
            stop()
            return
        }
        let now = Date()
        let minute = TimeText.minutesOfDay(now)
        guard minute != lastSpokenMinute, minute % max(1, route.voiceInterval) == 0 else { return }
        lastSpokenMinute = minute
        guard headphonesConnected, let text = message(for: route, at: now) else { return }
        speak(text)
    }

    private var headphonesConnected: Bool {
        let wired: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones, .usbAudio]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { wired.contains($0.portType) }
    }

    /// "6시 11분" (TTS가 자연스럽게 읽도록)
    private static func spoken(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return m % 60 == 0 ? "\(m / 60)시" : "\(m / 60)시 \(m % 60)분"
    }

    private func message(for route: Route, at now: Date) -> String? {
        let day = DayOverride.effective(raw: SharedData.dayOverrideRaw, on: now)
        if let onboard = route.onboardTrain(at: now, day: day), let arrival = onboard.arrival {
            let minutes = max(0, Int(arrival.timeIntervalSince(now)) / 60)
            return "\(route.destination) 도착까지 \(minutes)분 남았어요."
        }
        guard let next = route.upcoming(from: now, day: day, limit: 1).first, !next.isTomorrow else { return nil }
        let toDeparture = max(0, next.secondsUntil / 60)
        if route.walkMinutes > 0 && next.leaveIn > 0 {
            return "\(Self.spoken(next.minutes)) 열차, 출발까지 \(toDeparture)분. \(Self.spoken(next.minutes - route.walkMinutes))까지 나가세요."
        }
        return "\(Self.spoken(next.minutes)) 열차, 출발까지 \(toDeparture)분 남았어요."
    }

    private func speak(_ text: String) {
        configureSession(duck: true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ko-KR")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.configureSession(duck: false) }
    }

    // MARK: - 백그라운드 유지 (무음 오디오)

    /// 말할 때만 음악 소리를 줄이고, 평소엔 다른 앱 소리와 섞여서 방해하지 않는다.
    private func configureSession(duck: Bool) {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = duck ? [.mixWithOthers, .duckOthers] : [.mixWithOthers]
        try? session.setCategory(.playback, mode: .spokenAudio, options: options)
        try? session.setActive(true)
    }

    private func startSilence() {
        guard silentPlayer == nil, let player = try? AVAudioPlayer(data: Self.silentWAV()) else { return }
        player.numberOfLoops = -1
        player.volume = 0
        player.play()
        silentPlayer = player
    }

    /// 1초짜리 무음 WAV (8kHz, 16bit, mono)
    private static func silentWAV() -> Data {
        let sampleRate: UInt32 = 8000
        let dataSize = sampleRate * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: MemoryLayout<T>.size))
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }

    // MARK: - 열차 탑승 감지

    private func startMotion() {
        guard CMMotionActivityManager.isActivityAvailable(), !motionRunning else { return }
        motionRunning = true
        motion.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity, activity.automotive, activity.confidence != .low else { return }
            Task { @MainActor in await self?.handleRiding() }
        }
    }

    /// 차량 이동이 감지됐을 때, 열차 출발 시각 무렵(출발 3분 전 ~ 출발 5분 뒤)이면 탑승한 것으로 본다.
    /// (버스 타고 역으로 가는 중에는 끄지 않도록 시각으로 한 번 더 확인)
    private func handleRiding() async {
        guard let route = activeRoute() else { return }
        let now = Date()
        let nowSeconds = TimeText.secondsOfDay(now)
        let day = DayOverride.effective(raw: SharedData.dayOverrideRaw, on: now)
        let boarding = route.visibleTimes(for: day).contains { departure in
            let diff = nowSeconds - departure * 60
            return diff >= -180 && diff <= 300
        }
        guard boarding else { return }

        UserDefaults.standard.set(RailSync.todayKey(), forKey: Self.stoppedKey(route.id.uuidString))
        if !route.hasBusConnection {
            // 퇴근: 열차를 탔으니 잠금화면 현황도 끈다.
            await LiveActivityManager.endAllFromShortcut()
        }
        stop()
    }
}
