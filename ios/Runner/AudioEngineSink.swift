import AVFoundation
import Flutter
import Foundation

final class AudioEngineSink {
  private let lock = NSLock()
  private var engine: AVAudioEngine?
  private var playerNode: AVAudioPlayerNode?
  private var pcmFormat: AVAudioFormat?
  private var sampleRate: Int = 48000
  private var channels: Int = 2
  private var isOpen: Bool = false
  private var isPaused: Bool = false
  private var isInterrupted: Bool = false
  private var generation: UInt64 = 0
  private var epoch: UInt64 = 0
  private var completedFramesInEpoch: Int64 = 0
  private var cumulativePlayedAtStop: Int64 = 0
  private var lastReportedFrames: Int64 = 0
  private var observers: [NSObjectProtocol] = []

  deinit {
    close()
  }

  func open(sampleRate: Int, channels: Int, bitsPerSample: Int) -> Bool {
    close()

    guard sampleRate > 0, (1...2).contains(channels), bitsPerSample == 16 else {
      return false
    }

    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: Double(sampleRate),
      channels: AVAudioChannelCount(channels),
      interleaved: false
    ) else {
      return false
    }

    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try? session.setPreferredSampleRate(Double(sampleRate))
      try? session.setPreferredIOBufferDuration(0.02)
      try session.setActive(true)
    } catch {
      return false
    }

    let createdEngine = AVAudioEngine()
    let createdNode = AVAudioPlayerNode()
    createdEngine.attach(createdNode)
    createdEngine.connect(createdNode, to: createdEngine.mainMixerNode, format: format)
    createdEngine.prepare()

    do {
      try createdEngine.start()
      createdNode.play()
    } catch {
      createdNode.stop()
      createdEngine.stop()
      try? session.setActive(false, options: [.notifyOthersOnDeactivation])
      return false
    }

    lock.lock()
    self.generation &+= 1
    self.epoch &+= 1
    self.engine = createdEngine
    self.playerNode = createdNode
    self.pcmFormat = format
    self.sampleRate = sampleRate
    self.channels = channels
    self.isOpen = true
    self.isPaused = false
    self.isInterrupted = false
    self.completedFramesInEpoch = 0
    self.cumulativePlayedAtStop = 0
    self.lastReportedFrames = 0
    registerObserversLocked()
    lock.unlock()

    return true
  }

  func writePcm(_ data: Data) -> [String: Any] {
    lock.lock()
    let deltaFrames = consumePlayedFramesDeltaLocked()
    let pausedNow = !isOpen || isPaused || isInterrupted
    guard !pausedNow,
          let node = playerNode,
          let format = pcmFormat,
          let activeEngine = engine
    else {
      lock.unlock()
      return [
        "framesPlayedDelta": deltaFrames,
        "paused": true,
      ]
    }

    let bytesPerFrame = channels * 2
    let frameCount = bytesPerFrame > 0 ? (data.count / bytesPerFrame) : 0
    if frameCount <= 0 {
      lock.unlock()
      return [
        "framesPlayedDelta": deltaFrames,
        "paused": false,
      ]
    }

    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: AVAudioFrameCount(frameCount)
    ) else {
      lock.unlock()
      return [
        "framesPlayedDelta": deltaFrames,
        "paused": false,
      ]
    }

    buffer.frameLength = AVAudioFrameCount(frameCount)
    guard let floatChannelData = buffer.floatChannelData else {
      lock.unlock()
      return [
        "framesPlayedDelta": deltaFrames,
        "paused": false,
      ]
    }

    let channelCount = channels
    data.withUnsafeBytes { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: UInt8.self)
      for frame in 0..<frameCount {
        for ch in 0..<channelCount {
          let offset = (frame * channelCount + ch) * 2
          let lo = UInt16(bytes[offset])
          let hi = UInt16(bytes[offset + 1])
          let sample = Int16(bitPattern: lo | (hi << 8))
          floatChannelData[ch][frame] = Float(sample) / 32768.0
        }
      }
    }

    let activeGen = generation
    if !activeEngine.isRunning {
      lock.unlock()
      var started = false
      do {
        try AVAudioSession.sharedInstance().setActive(true)
        try activeEngine.start()
        started = activeEngine.isRunning
      } catch {
        started = false
      }
      lock.lock()
      guard started,
            isOpen,
            !isPaused,
            !isInterrupted,
            generation == activeGen,
            activeEngine.isRunning
      else {
        lock.unlock()
        return [
          "framesPlayedDelta": deltaFrames,
          "paused": true,
        ]
      }
    }

    if !node.isPlaying {
      node.play()
    }

    let activeEpoch = epoch
    let scheduledFrames = Int64(frameCount)
    node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      guard let self = self else { return }
      self.lock.lock()
      if self.generation == activeGen && self.epoch == activeEpoch {
        self.completedFramesInEpoch += scheduledFrames
      }
      self.lock.unlock()
    }
    lock.unlock()

    return [
      "framesPlayedDelta": deltaFrames,
      "paused": false,
    ]
  }

  func pollPlayoutDelta() -> [String: Any] {
    lock.lock()
    let deltaFrames = consumePlayedFramesDeltaLocked()
    let pausedNow = !isOpen || isPaused || isInterrupted
    lock.unlock()
    return [
      "framesPlayedDelta": deltaFrames,
      "paused": pausedNow,
    ]
  }

  func pause() {
    lock.lock()
    isPaused = true
    let (activeNode, activeEngine) = prepareStopPlaybackLocked()
    lock.unlock()

    activeNode?.stop()
    activeEngine?.pause()
  }

  func resume() {
    lock.lock()
    isPaused = false
    guard isOpen, let activeEngine = engine, let node = playerNode else {
      lock.unlock()
      return
    }
    let activeGen = generation
    lock.unlock()

    var started = activeEngine.isRunning
    do {
      try AVAudioSession.sharedInstance().setActive(true)
      if !activeEngine.isRunning {
        try activeEngine.start()
      }
      if !node.isPlaying {
        node.play()
      }
      started = activeEngine.isRunning
    } catch {
      started = false
    }

    lock.lock()
    if isOpen && generation == activeGen && !isPaused {
      isInterrupted = !started
    }
    lock.unlock()
  }

  func close() {
    lock.lock()
    let wasOpen = isOpen
    isOpen = false
    isPaused = false
    isInterrupted = false
    generation &+= 1
    epoch &+= 1
    let activeNode = playerNode
    let activeEngine = engine
    playerNode = nil
    engine = nil
    pcmFormat = nil
    completedFramesInEpoch = 0
    cumulativePlayedAtStop = 0
    lastReportedFrames = 0
    removeObserversLocked()
    lock.unlock()

    activeNode?.stop()
    if let activeEngine = activeEngine {
      if let activeNode = activeNode {
        activeEngine.detach(activeNode)
      }
      activeEngine.stop()
    }

    if wasOpen {
      try? AVAudioSession.sharedInstance().setActive(
        false,
        options: [.notifyOthersOnDeactivation]
      )
    }
  }

  private func consumePlayedFramesDeltaLocked() -> Int {
    let total = cumulativePlayedAtStop + completedFramesInEpoch
    let delta = max(0, total - lastReportedFrames)
    lastReportedFrames = total
    return Int(min(delta, Int64(Int.max)))
  }

  private func prepareStopPlaybackLocked() -> (AVAudioPlayerNode?, AVAudioEngine?) {
    cumulativePlayedAtStop += completedFramesInEpoch
    completedFramesInEpoch = 0
    epoch &+= 1
    return (playerNode, engine)
  }

  private func registerObserversLocked() {
    removeObserversLocked()
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(),
        queue: nil
      ) { [weak self] notification in
        self?.handleInterruption(notification)
      }
    )
    observers.append(
      center.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: AVAudioSession.sharedInstance(),
        queue: nil
      ) { [weak self] notification in
        self?.handleRouteChange(notification)
      }
    )
    observers.append(
      center.addObserver(
        forName: NSNotification.Name.AVAudioEngineConfigurationChange,
        object: engine,
        queue: nil
      ) { [weak self] _ in
        self?.handleEngineConfigurationChange()
      }
    )
  }

  private func removeObserversLocked() {
    let center = NotificationCenter.default
    for observer in observers {
      center.removeObserver(observer)
    }
    observers.removeAll()
  }

  private func handleInterruption(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let interruptionType = AVAudioSession.InterruptionType(rawValue: rawType)
    else {
      return
    }

    switch interruptionType {
    case .began:
      lock.lock()
      isInterrupted = true
      let (activeNode, activeEngine) = prepareStopPlaybackLocked()
      lock.unlock()

      activeNode?.stop()
      activeEngine?.pause()
    case .ended:
      let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
        .contains(.shouldResume)
      guard shouldResume else {
        // Keep isInterrupted = true until an explicit resume() or open() reactivates the session.
        return
      }

      lock.lock()
      guard isOpen else {
        lock.unlock()
        return
      }
      if isPaused {
        isInterrupted = false
        lock.unlock()
        return
      }
      guard let activeEngine = engine, let node = playerNode else {
        lock.unlock()
        return
      }
      let activeGen = generation
      lock.unlock()

      var started = false
      do {
        try AVAudioSession.sharedInstance().setActive(true)
        if !activeEngine.isRunning {
          try activeEngine.start()
        }
        if !node.isPlaying {
          node.play()
        }
        started = activeEngine.isRunning
      } catch {
        started = false
      }

      lock.lock()
      if isOpen && generation == activeGen {
        isInterrupted = !started
      }
      lock.unlock()
    @unknown default:
      break
    }
  }

  private func handleRouteChange(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let rawReason = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
    else {
      return
    }

    switch reason {
    case .oldDeviceUnavailable, .categoryChange, .override, .newDeviceAvailable:
      lock.lock()
      guard isOpen,
            !isPaused,
            !isInterrupted,
            let activeEngine = engine,
            let node = playerNode
      else {
        lock.unlock()
        return
      }
      let activeGen = generation
      lock.unlock()

      var started = activeEngine.isRunning
      if !started {
        do {
          try AVAudioSession.sharedInstance().setActive(true)
          try activeEngine.start()
          started = activeEngine.isRunning
        } catch {
          started = false
        }
      }
      if started && !node.isPlaying {
        node.play()
      }
      if !started {
        lock.lock()
        if isOpen && generation == activeGen {
          isInterrupted = true
        }
        lock.unlock()
      }
    default:
      break
    }
  }

  private func handleEngineConfigurationChange() {
    lock.lock()
    guard isOpen,
          let activeEngine = engine,
          let node = playerNode,
          let format = pcmFormat
    else {
      lock.unlock()
      return
    }
    cumulativePlayedAtStop += completedFramesInEpoch
    completedFramesInEpoch = 0
    epoch &+= 1
    let activeGen = generation
    let shouldRestart = !isPaused && !isInterrupted
    lock.unlock()

    activeEngine.connect(node, to: activeEngine.mainMixerNode, format: format)
    activeEngine.prepare()
    guard shouldRestart else {
      return
    }

    var restarted = false
    do {
      try AVAudioSession.sharedInstance().setActive(true)
      if !activeEngine.isRunning {
        try activeEngine.start()
      }
      if !node.isPlaying {
        node.play()
      }
      restarted = activeEngine.isRunning
    } catch {
      restarted = false
    }

    if !restarted {
      lock.lock()
      if isOpen && generation == activeGen {
        isInterrupted = true
      }
      lock.unlock()
    }
  }
}
