import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let audioChannelName = "dev.aer.rdp/audio"
  private var audioSink: AudioEngineSink?
  private var audioChannel: FlutterMethodChannel?
  private var lifecycleObservers: [NSObjectProtocol] = []

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    _ = dummy_method_to_enforce_bundling()
    registerLifecycleObservers()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  deinit {
    let center = NotificationCenter.default
    for observer in lifecycleObservers {
      center.removeObserver(observer)
    }
    lifecycleObservers.removeAll()
    audioSink?.close()
    audioSink = nil
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AerRdpAudioPlugin") else {
      return
    }

    let sink = audioSink ?? AudioEngineSink()
    audioSink = sink

    let channel = FlutterMethodChannel(
      name: audioChannelName,
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, let activeSink = self.audioSink else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "open":
        let args = call.arguments as? [String: Any]
        let sampleRate = (args?["sampleRate"] as? NSNumber)?.intValue ?? 48000
        let channels = (args?["channels"] as? NSNumber)?.intValue ?? 2
        let bitsPerSample = (args?["bitsPerSample"] as? NSNumber)?.intValue ?? 16
        result(activeSink.open(
          sampleRate: sampleRate,
          channels: channels,
          bitsPerSample: bitsPerSample
        ))
      case "writePcm":
        let args = call.arguments as? [String: Any]
        let typedData = args?["pcmBytes"] as? FlutterStandardTypedData
        result(activeSink.writePcm(typedData?.data ?? Data()))
      case "pollPlayoutDelta":
        result(activeSink.pollPlayoutDelta())
      case "pause":
        activeSink.pause()
        result(nil)
      case "resume":
        activeSink.resume()
        result(nil)
      case "close":
        activeSink.close()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    audioChannel = channel
  }

  private func registerLifecycleObservers() {
    guard lifecycleObservers.isEmpty else { return }
    let center = NotificationCenter.default
    lifecycleObservers.append(
      center.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.audioSink?.pause()
      }
    )
    lifecycleObservers.append(
      center.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.audioSink?.resume()
      }
    )
  }
}
