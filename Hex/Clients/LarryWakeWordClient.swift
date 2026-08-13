//
//  LarryWakeWordClient.swift
//  Hex — "Hey Larry" wake word
//
//  Listens continuously for the phrase "Hey Larry" and starts a recording when
//  it hears it, so the hotkey becomes optional rather than required.
//
//  Design notes, and why it is built this way:
//
//  * Recognition is Apple's `SFSpeechRecognizer` pinned to on-device mode, not
//    Parakeet. Wake-word spotting does not need transcription quality, and
//    running Parakeet continuously would burn far more power for no benefit.
//    On-device also means no audio leaves the Mac and it works offline.
//
//  * `SFSpeechRecognitionTask` stops on its own after roughly a minute of
//    audio. A wake word that quietly dies after the first minute looks exactly
//    like one that works, so the task is recycled on a timer well before that
//    limit, and also restarted if it ends on its own.
//
//  * Hex's recorder owns the input node while it captures. Two engines tapping
//    the same input device at once is unreliable, so this suspends itself for
//    the duration of a recording and resumes afterwards — see `suspend()` and
//    `resume()`, called from TranscriptionFeature.
//
//  Requires `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` in the target's
//  build settings (alongside the existing microphone string).
//

import AVFoundation
import Foundation
import HexCore
import Speech

private let wakeLog = HexLog.larryWakeWord

@MainActor
final class LarryWakeWord: NSObject {
  static let shared = LarryWakeWord()

  /// Called on the main actor when the phrase is heard.
  var onDetected: (() -> Void)?

  /// Wake word is on unless explicitly disabled — the point of the build is
  /// that you never touch a key. Note this holds the microphone open, so the
  /// system mic indicator stays lit whenever Larry is listening.
  /// Turn off permanently with
  /// `defaults write com.kitlangton.Hex larryWakeWordEnabled -bool false`.
  /// `nonisolated` because the reducer reads this from the key-event monitor
  /// and from `.run` effects, neither of which is on the main actor. Backed by
  /// UserDefaults, which is safe to read from any thread.
  nonisolated static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: "larryWakeWordEnabled") == nil
      ? true
      : UserDefaults.standard.bool(forKey: "larryWakeWordEnabled")
  }

  /// Muted by the user with right-Option. Distinct from `isSuspended`, which
  /// is the short automatic pause while a recording owns the microphone: a
  /// mute has to survive that pause, so `resume()` must not undo it.
  private(set) var isMuted = false

  /// Called when the user taps right-Option. Returns the new muted state so
  /// the caller can reflect it in the UI.
  @discardableResult
  func toggleMuted() -> Bool {
    isMuted.toggle()
    if isMuted {
      wakeLog.info("Wake word muted by right-Option")
      stop()
      LarryHUD.shared.setState(.muted)
    } else {
      wakeLog.info("Wake word unmuted by right-Option")
      LarryHUD.shared.setState(.standby)
      Task { await start() }
    }
    return isMuted
  }

  /// Spellings to accept. On-device recognition rarely returns the exact
  /// casing or spelling of a name, and "Larry" lands on several near-misses —
  /// including Danish-accented ones — so a small set beats an exact match.
  private static let phrases = [
    "hey larry", "hey lary", "hey larri", "hey laurie", "hey lari",
    "hej larry", "hej lary", "hey harry", "hey lorry",
  ]

  /// Recycle the recognition task well inside the ~60s ceiling.
  private static let taskLifetime: TimeInterval = 45

  /// Longest a suspension may last before the watchdog forces a resume. Comfortably
  /// past a normal utterance plus Larry's ~40s reply, so it only fires on a genuine
  /// missed resume.
  private static let maxSuspension: TimeInterval = 90

  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private var engine: AVAudioEngine?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var recycleTimer: Timer?
  private var suspendWatchdog: Timer?

  /// True while a recording owns the microphone.
  private var isSuspended = false
  private var isRunning = false

  /// Guards against firing repeatedly while the phrase stays in the rolling
  /// transcript — one detection per task generation.
  private var hasFiredThisGeneration = false

  // MARK: Lifecycle

  /// Requests permission and starts listening. Safe to call more than once.
  func start() async {
    guard Self.isEnabled, !isMuted else { return }
    guard let recognizer, recognizer.isAvailable else {
      wakeLog.error("No speech recogniser available for en-US; wake word disabled")
      return
    }
    guard recognizer.supportsOnDeviceRecognition else {
      // Refuse rather than silently stream microphone audio to Apple's servers.
      wakeLog.error("On-device recognition unavailable for en-US; wake word disabled")
      return
    }

    let status = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    guard status == .authorized else {
      wakeLog.error("Speech recognition not authorised (status \(status.rawValue))")
      return
    }

    listen()
  }

  /// Stops listening and releases the microphone.
  func stop() {
    recycleTimer?.invalidate()
    recycleTimer = nil
    task?.cancel()
    task = nil
    request?.endAudio()
    request = nil
    if let engine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    engine = nil
    isRunning = false
  }

  /// Called when Hex starts recording, so the recorder can own the input node.
  func suspend() {
    isSuspended = true
    stop()

    // Watchdog. A suspension that never gets its matching resume leaves the
    // wake word silently dead until the app is restarted — indistinguishable,
    // from the outside, from it simply not working. Every caller is paired
    // today, but this failure is invisible and the recovery is free, so time
    // the suspension out rather than trusting every future path to be correct.
    suspendWatchdog?.invalidate()
    suspendWatchdog = Timer.scheduledTimer(
      withTimeInterval: Self.maxSuspension, repeats: false
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.isSuspended else { return }
        wakeLog.error("Suspension exceeded \(Self.maxSuspension)s with no resume — recovering")
        self.resume()
      }
    }
  }

  /// Called when a recording finishes.
  func resume() {
    suspendWatchdog?.invalidate()
    suspendWatchdog = nil
    guard isSuspended else { return }
    isSuspended = false
    // A mute set while recording must outlive the automatic pause.
    guard !isMuted else { return }
    Task { await start() }
  }

  // MARK: Listening

  private func listen() {
    guard !isSuspended, !isMuted, !isRunning else { return }
    stop()

    let engine = AVAudioEngine()
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = true

    let inputNode = engine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0 else {
      wakeLog.error("Input node reports a zero sample rate; is a microphone connected?")
      return
    }

    inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
      request.append(buffer)
    }

    engine.prepare()
    do {
      try engine.start()
    } catch {
      wakeLog.error("Wake-word engine failed to start: \(error.localizedDescription, privacy: .public)")
      inputNode.removeTap(onBus: 0)
      return
    }

    self.engine = engine
    self.request = request
    hasFiredThisGeneration = false
    isRunning = true

    task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
      Task { @MainActor in
        guard let self else { return }
        if let result {
          self.inspect(result.bestTranscription.formattedString)
        }
        if error != nil || result?.isFinal == true {
          // The task ended — recycle so listening does not silently stop.
          self.restartSoon()
        }
      }
    }

    // Pre-empt the ~60s task ceiling.
    recycleTimer = Timer.scheduledTimer(withTimeInterval: Self.taskLifetime, repeats: false) { [weak self] _ in
      Task { @MainActor in self?.restartSoon() }
    }

    wakeLog.info("Wake word listening")
  }

  private func inspect(_ transcript: String) {
    guard !hasFiredThisGeneration else { return }
    let normalized = transcript
      .lowercased()
      .replacingOccurrences(of: "[^a-z ]", with: "", options: .regularExpression)
    guard Self.phrases.contains(where: { normalized.contains($0) }) else { return }

    hasFiredThisGeneration = true
    wakeLog.info("Wake word detected")
    onDetected?()
    // Deliberately *not* suspending here. Suspension is owned solely by
    // `handleStartRecording`/`finalize…`, which pair it with a resume. If a
    // detection is dropped — say Larry is already answering — suspending here
    // would leave the wake word off for good, with nothing to switch it back on.
  }

  private func restartSoon() {
    guard !isSuspended, !isMuted else { return }
    stop()
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 200_000_000)
      guard !self.isSuspended else { return }
      self.listen()
    }
  }
}
