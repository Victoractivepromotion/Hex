//
//  TranscriptionFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import CoreGraphics
import Foundation
import HexCore
import Inject
import SwiftUI
import WhisperKit

private let transcriptionFeatureLogger = HexLog.transcription

@Reducer
struct TranscriptionFeature {
  @ObservableState
  struct State {
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var isPrewarming: Bool = false
    var error: String?
    var recordingStartTime: Date?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)

    /// Set when a recording was started by the wake word rather than the
    /// hotkey. There is no key to release in that case, so the recording has
    /// to end itself — see the silence detection in `.audioLevelUpdated`.
    var isHandsFree: Bool = false
    /// Last moment the input was loud enough to count as speech.
    var lastVoiceAt: Date?
    /// Whether this hands-free utterance has contained any speech yet, so a
    /// pause *before* you start talking cannot end it immediately.
    var heardSpeech: Bool = false
    /// Loudest level seen during this utterance, used to calibrate the silence
    /// threshold to how loud you actually are rather than a guessed constant.
    var loudestThisUtterance: Double = 0

    var sourceAppBundleID: String?
    var sourceAppName: String?
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
  }

  enum Action {
    case task
    case audioLevelUpdated(Meter)

    /// The "Hey Larry" wake word was heard.
    case wakeWordDetected

    // Hotkey actions
    case hotKeyPressed
    case hotKeyReleased

    // Recording flow
    case startRecording
    case stopRecording

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)

    // Transcription result flow
    case transcriptionResult(String, URL, TimeInterval)
    case transcriptionError(Error, URL?)

    // Model availability
    case modelMissing
  }

  enum CancelID {
    case metering
    case recordingStart
    case recordingCleanup
    case transcription
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
  @Dependency(\.date.now) var now
  @Dependency(\.transcriptPersistence) var transcriptPersistence
  @Dependency(\.speechSynthesizer) var speechSynthesizer

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      // MARK: - Lifecycle / Setup

      case .task:
        // Starts two concurrent effects:
        // 1) Observing audio meter
        // 2) Monitoring hot key events
        // 3) Priming the recorder for instant startup
        return .merge(
          startWakeWordEffect(),
          startMeteringEffect(),
          startHotKeyMonitoringEffect(),
          warmUpRecorderEffect()
        )

      // MARK: - Metering

      case let .audioLevelUpdated(meter):
        state.meter = meter
        return handleMeterForHandsFree(&state, meter: meter)

      case .wakeWordDetected:
        // Ignore if we're already busy — Larry shouldn't interrupt himself.
        guard !state.isRecording, !state.isTranscribing else { return .none }
        state.isHandsFree = true
        state.heardSpeech = false
        state.loudestThisUtterance = 0
        state.lastVoiceAt = now
        return .send(.startRecording)

      // MARK: - HotKey Flow

      case .hotKeyPressed:
        // If we're transcribing, send a cancel first. Otherwise start recording immediately.
        // We'll decide later (on release) whether to keep or discard the recording.
        return handleHotKeyPressed(isTranscribing: state.isTranscribing)

      case .hotKeyReleased:
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording)

      // MARK: - Recording Flow

      case .startRecording:
        return handleStartRecording(&state)

      case .stopRecording:
        return handleStopRecording(&state)

      // MARK: - Transcription Results

      case let .transcriptionResult(result, audioURL, duration):
        return handleTranscriptionResult(&state, result: result, audioURL: audioURL, duration: duration)

      case let .transcriptionError(error, audioURL):
        return handleTranscriptionError(&state, error: error, audioURL: audioURL)

      case .modelMissing:
        return .none

      // MARK: - Cancel/Discard Flow

      case .cancel:
        // Only cancel if we're in the middle of recording, transcribing, or post-processing
        guard state.isRecording || state.isTranscribing else {
          return .none
        }
        return handleCancel(&state)

      case .discard:
        // Silent discard for quick/accidental recordings
        guard state.isRecording else {
          return .none
        }
        return handleDiscard(&state)
      }
    }
  }
}

// MARK: - Hands-free silence detection

private extension TranscriptionFeature {
  /// Narrows an "Option, either side" dictation hotkey to the left key while
  /// the wake word is on, so right-Option is free to mute it.
  ///
  /// Hex ships with Option/either as the default hotkey, which means right
  /// Option would otherwise both start a recording *and* toggle the mute on
  /// the same press. Only the ambiguous case is rewritten — an explicitly
  /// chosen hotkey, including a deliberate right-Option one, is left alone.
  static func dictationHotkey(from hotkey: HotKey) -> HotKey {
    guard LarryWakeWord.isEnabled, hotkey.key == nil else { return hotkey }
    guard hotkey.modifiers.matchesExactly([Modifier(kind: .option, side: .either)]) else {
      return hotkey
    }
    return HotKey(key: nil, modifiers: [Modifier(kind: .option, side: .left)])
  }

  /// Bridges "Hey Larry" detections into the reducer. Does nothing unless the
  /// wake word is switched on, so the microphone is only held open when the
  /// feature is actually wanted.
  func startWakeWordEffect() -> Effect<Action> {
    .run { send in
      guard LarryWakeWord.isEnabled else { return }
      let detections = AsyncStream<Void> { continuation in
        Task { @MainActor in
          LarryWakeWord.shared.onDetected = { continuation.yield(()) }
          await LarryWakeWord.shared.start()
        }
        continuation.onTermination = { _ in
          Task { @MainActor in LarryWakeWord.shared.stop() }
        }
      }
      for await _ in detections {
        await send(.wakeWordDetected)
      }
    }
  }

  /// Absolute floor for what can count as speech. The meter is raw RMS from
  /// the capture engine (roughly 0.001 for a quiet room, 0.02–0.1 for speech),
  /// so this only has to clear room tone — the real decision is the relative
  /// test below.
  static let speechFloor: Double = 0.006
  /// Speech is anything above this fraction of the loudest moment so far. A
  /// fixed threshold cannot work for every microphone, distance and voice: too
  /// high and your speech reads as silence so the recording never ends, too low
  /// and room tone reads as speech so it also never ends. Calibrating against
  /// your own peak sidesteps both.
  static let speechRatio: Double = 0.18
  /// Silence this long ends the utterance.
  static let silenceToEnd: TimeInterval = 1.2
  /// If no speech is ever detected, end well before the hard ceiling instead of
  /// leaving the recording open — a mis-fired wake word shouldn't hang for 30s.
  static let noSpeechTimeout: TimeInterval = 8
  /// Never let a hands-free recording run away if the room is simply noisy.
  static let handsFreeCeiling: TimeInterval = 30

  /// Ends a hands-free recording once you stop talking, so there is never an
  /// Enter to press. Hotkey recordings are untouched — those end on release.
  func handleMeterForHandsFree(_ state: inout State, meter: Meter) -> Effect<Action> {
    guard state.isHandsFree, state.isRecording else { return .none }

    let level = meter.averagePower
    state.loudestThisUtterance = max(state.loudestThisUtterance, level)

    // Calibrate against how loud this speaker actually is, with an absolute
    // floor so a silent room can never talk itself into a high bar.
    let threshold = max(Self.speechFloor, state.loudestThisUtterance * Self.speechRatio)
    if level > threshold {
      state.heardSpeech = true
      state.lastVoiceAt = now
      return .none
    }

    let elapsed = state.recordingStartTime.map { now.timeIntervalSince($0) } ?? 0

    // Bail out of a recording that is running long regardless of level.
    if elapsed > Self.handsFreeCeiling {
      transcriptionFeatureLogger.notice(
        "Hands-free recording hit its ceiling (peak \(state.loudestThisUtterance)); sending what we have"
      )
      return .send(.stopRecording)
    }

    // Never heard anything speech-like — don't hold the recording open.
    guard state.heardSpeech, let last = state.lastVoiceAt else {
      if elapsed > Self.noSpeechTimeout {
        transcriptionFeatureLogger.notice(
          "Hands-free recording heard no speech in \(Self.noSpeechTimeout)s (peak \(state.loudestThisUtterance)); ending"
        )
        return .send(.stopRecording)
      }
      return .none
    }

    // Silence *after* speech ends the utterance — a pause before you begin
    // must not cut you off before you have said anything.
    guard now.timeIntervalSince(last) >= Self.silenceToEnd else { return .none }

    transcriptionFeatureLogger.info(
      "Silence detected after speech (peak \(state.loudestThisUtterance)); auto-sending"
    )
    return .send(.stopRecording)
  }
}

// MARK: - Effects: Metering & HotKey

private extension TranscriptionFeature {
  /// Effect to begin observing the audio meter.
  func startMeteringEffect() -> Effect<Action> {
    .run { send in
      for await meter in await recording.observeAudioLevel() {
        await send(.audioLevelUpdated(meter))
      }
    }
    .cancellable(id: CancelID.metering, cancelInFlight: true)
  }

  /// Effect to start monitoring hotkey events through the `keyEventMonitor`.
  func startHotKeyMonitoringEffect() -> Effect<Action> {
    .run { send in
      var hotKeyProcessor: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: [.option]))
      /// Tracks a solo right-Option press so the mute toggle fires on release.
      var rightOptionHeld = false
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      // Handle incoming input events (keyboard and mouse)
      let token = keyEventMonitor.handleInputEvent { inputEvent in
        // Skip if the user is currently setting a hotkey
        if isSettingHotKey {
          return false
        }

        // Always keep hotKeyProcessor in sync with current user hotkey preference
        hotKeyProcessor.hotkey = Self.dictationHotkey(from: hexSettings.hotkey)
        let useDoubleTapOnly = hexSettings.doubleTapLockEnabled && hexSettings.useDoubleTapOnly
        hotKeyProcessor.doubleTapLockEnabled = hexSettings.doubleTapLockEnabled
        hotKeyProcessor.useDoubleTapOnly = useDoubleTapOnly
        hotKeyProcessor.minimumKeyTime = hexSettings.minimumKeyTime

        switch inputEvent {
        case .keyboard(let keyEvent):
          // If Escape is pressed with no modifiers while idle, let's treat that as `cancel`.
          if keyEvent.key == .escape, keyEvent.modifiers.isEmpty,
             hotKeyProcessor.state == .idle
          {
            Task { await send(.cancel) }
            return false
          }

          // Right-Option on its own mutes and unmutes the wake word. Handled
          // before the hotkey processor so it can't also start a recording.
          //
          // The event is deliberately *not* intercepted: on a Danish layout
          // Option is how you type @, $, \ and friends, and swallowing it
          // would break that everywhere. Toggling on release keeps a held
          // Option-plus-key chord from counting as a tap.
          if LarryWakeWord.isEnabled, keyEvent.key == nil {
            let isRightOptionAlone = keyEvent.modifiers.contains(Modifier(kind: .option, side: .right))
              && keyEvent.modifiers.kinds == [.option]
            if isRightOptionAlone {
              rightOptionHeld = true
              return false
            }
            if rightOptionHeld, keyEvent.modifiers.isEmpty {
              rightOptionHeld = false
              Task { @MainActor in LarryWakeWord.shared.toggleMuted() }
              return false
            }
          }
          rightOptionHeld = false

          // Process the key event
          switch hotKeyProcessor.process(keyEvent: keyEvent) {
          case .startRecording:
            // If double-tap lock is triggered, we start recording immediately
            if hotKeyProcessor.state == .doubleTapLock {
              Task { await send(.startRecording) }
            } else {
              Task { await send(.hotKeyPressed) }
            }
            // If the hotkey is purely modifiers, return false to keep it from interfering with normal usage
            // But if useDoubleTapOnly is true, always intercept the key
            return useDoubleTapOnly || keyEvent.key != nil

          case .stopRecording:
            Task { await send(.hotKeyReleased) }
            return false // or `true` if you want to intercept

          case .cancel:
            Task { await send(.cancel) }
            return true

          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept - let the key chord reach other apps

          case .none:
            // If we detect repeated same chord, maybe intercept.
            if let pressedKey = keyEvent.key,
               pressedKey == hotKeyProcessor.hotkey.key,
               keyEvent.modifiers == hotKeyProcessor.hotkey.modifiers
            {
              return true
            }
            return false
          }

        case .mouseClick:
          // Process mouse click - for modifier-only hotkeys, this may cancel/discard
          switch hotKeyProcessor.processMouseClick() {
          case .cancel:
            Task { await send(.cancel) }
            return false // Don't intercept the click itself
          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept the click itself
          case .startRecording, .stopRecording, .none:
            return false
          }
        }
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
        }
      } onCancel: {
        token.cancel()
      }
    }
  }

  func warmUpRecorderEffect() -> Effect<Action> {
    .run { _ in
      await recording.warmUpRecorder()
    }
  }
}

// MARK: - HotKey Press/Release Handlers

private extension TranscriptionFeature {
  func handleHotKeyPressed(isTranscribing: Bool) -> Effect<Action> {
    // If already transcribing, cancel first. Otherwise start recording immediately.
    guard isTranscribing else { return .send(.startRecording) }
    return .concatenate(
      .send(.cancel),
      .send(.startRecording)
    )
  }

  func handleHotKeyReleased(isRecording: Bool) -> Effect<Action> {
    // Always stop recording when hotkey is released
    return isRecording ? .send(.stopRecording) : .none
  }
}

// MARK: - Recording Handlers

private extension TranscriptionFeature {
  func handleStartRecording(_ state: inout State) -> Effect<Action> {
    guard state.modelBootstrapState.isModelReady else {
      return .merge(
        .send(.modelMissing),
        .run { _ in soundEffect.play(.cancel) }
      )
    }
    state.isRecording = true
    let startTime = now
    state.recordingStartTime = startTime

    // Barge-in: cut Larry off the moment you start speaking, so he isn't
    // still answering the last question over the top of the new one.
    Task { @MainActor in
      LarryAudioPlayer.shared.stop()
      LarryHUD.shared.setState(.listening)
      // The recorder needs sole ownership of the input node; two engines
      // tapping the same device at once is unreliable.
      LarryWakeWord.shared.suspend()
    }

    // Capture the active application
    if let activeApp = NSWorkspace.shared.frontmostApplication {
      state.sourceAppBundleID = activeApp.bundleIdentifier
      state.sourceAppName = activeApp.localizedName
    }
    transcriptionFeatureLogger.notice("Recording started at \(startTime.ISO8601Format())")

    // Prevent system sleep during recording
    return .merge(
      .cancel(id: CancelID.recordingCleanup),
      // Silence the agent read-aloud voice so it doesn't talk over (or into) the mic.
      .run { _ in await speechSynthesizer.stop() },
      .run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep] _ in
        // Play sound immediately for instant feedback
        soundEffect.play(.startRecording)

        if preventSleep {
          await sleepManagement.preventSleep(reason: "Hex Voice Recording")
        }
        guard !Task.isCancelled else {
          if preventSleep {
            await sleepManagement.allowSleep()
          }
          return
        }
        await recording.startRecording()
      }
      .cancellable(id: CancelID.recordingStart, cancelInFlight: true)
    )
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isHandsFree = false
    state.heardSpeech = false
    state.lastVoiceAt = nil
    state.loudestThisUtterance = 0

    let stopTime = now
    let startTime = state.recordingStartTime
    let duration = startTime.map { stopTime.timeIntervalSince($0) } ?? 0

    let decision = RecordingDecisionEngine.decide(
      .init(
        hotkey: state.hexSettings.hotkey,
        minimumKeyTime: state.hexSettings.minimumKeyTime,
        recordingStartTime: state.recordingStartTime,
        currentTime: stopTime
      )
    )

    let startStamp = startTime?.ISO8601Format() ?? "nil"
    let stopStamp = stopTime.ISO8601Format()
    let minimumKeyTime = state.hexSettings.minimumKeyTime
    let hotkeyHasKey = state.hexSettings.hotkey.key != nil
    transcriptionFeatureLogger.notice(
      "Recording stopped duration=\(String(format: "%.3f", duration))s start=\(startStamp) stop=\(stopStamp) decision=\(String(describing: decision)) minimumKeyTime=\(String(format: "%.2f", minimumKeyTime)) hotkeyHasKey=\(hotkeyHasKey)"
    )

    guard decision == .proceedToTranscription else {
      // If the user recorded for less than minimumKeyTime and the hotkey is modifier-only,
      // discard the audio to avoid accidental triggers.
      transcriptionFeatureLogger.notice("Discarding short recording per decision \(String(describing: decision))")
      return handleDiscard(&state)
    }

    // Otherwise, proceed to transcription
    state.isTranscribing = true
    state.error = nil
    let model = state.hexSettings.selectedModel
    let language = state.hexSettings.outputLanguage

    state.isPrewarming = true

    return .merge(
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] send in
        // Allow system to sleep again
        await sleepManagement.allowSleep()

        var audioURL: URL?
        defer {
          if let audioURL {
            FileManager.default.removeItemIfExists(at: audioURL)
          }
        }
        do {
          let capturedURL = await recording.stopRecording()
          audioURL = capturedURL
          guard !Task.isCancelled else { return }
          soundEffect.play(.stopRecording)

          // Create transcription options with the selected language
          // Note: cap concurrency to avoid audio I/O overloads on some Macs
          let decodeOptions = DecodingOptions(
            language: language,
            detectLanguage: language == nil, // Only auto-detect if no language specified
            chunkingStrategy: .vad,
          )

          let result = try await transcription.transcribe(capturedURL, model, decodeOptions) { _ in }

          transcriptionFeatureLogger.notice("Transcribed audio from \(capturedURL.lastPathComponent) to text length \(result.count)")
          audioURL = nil
          await send(.transcriptionResult(result, capturedURL, duration))
        } catch {
          transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription)")
          await send(.transcriptionError(error, nil))
        }
      }
      .cancellable(id: CancelID.transcription)
    )
  }
}

// MARK: - Transcription Handlers

private extension TranscriptionFeature {
  func handleTranscriptionResult(
    _ state: inout State,
    result: String,
    audioURL: URL,
    duration: TimeInterval
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false

    // Check for force quit command (emergency escape hatch)
    if ForceQuitCommandDetector.matches(result) {
      transcriptionFeatureLogger.fault("Force quit voice command recognized; terminating Hex.")
      return .run { _ in
        FileManager.default.removeItemIfExists(at: audioURL)
        await MainActor.run {
          NSApp.terminate(nil)
        }
      }
    }

    // If empty text, nothing else to do
    guard !result.isEmpty else {
      return .run { _ in
        FileManager.default.removeItemIfExists(at: audioURL)
      }
    }

    transcriptionFeatureLogger.info("Raw transcription: '\(result, privacy: .private)'")
    let remappings = state.hexSettings.wordRemappings
    let removalsEnabled = state.hexSettings.wordRemovalsEnabled
    let removals = state.hexSettings.wordRemovals
    let modifiedResult: String
    if state.isRemappingScratchpadFocused {
      modifiedResult = result
      transcriptionFeatureLogger.info("Scratchpad focused; skipping word modifications")
    } else {
      var output = result
      if removalsEnabled {
        let removedResult = WordRemovalApplier.apply(output, removals: removals)
        if removedResult != output {
          let enabledRemovalCount = removals.filter(\.isEnabled).count
          transcriptionFeatureLogger.info("Applied \(enabledRemovalCount) word removal(s)")
        }
        output = removedResult
      }
      let remappedResult = WordRemappingApplier.apply(output, remappings: remappings)
      if remappedResult != output {
        transcriptionFeatureLogger.info("Applied \(remappings.count) word remapping(s)")
      }
      modifiedResult = remappedResult
    }

    guard !modifiedResult.isEmpty else {
      return .run { _ in
        FileManager.default.removeItemIfExists(at: audioURL)
      }
    }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory

    return .run { send in
      do {
        try await finalizeRecordingAndStoreTranscript(
          result: modifiedResult,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          transcriptionHistory: transcriptionHistory
        )
      } catch {
        await send(.transcriptionError(error, audioURL))
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  func handleTranscriptionError(
    _ state: inout State,
    error: Error,
    audioURL: URL?
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.error = error.localizedDescription
    
    if let audioURL {
      FileManager.default.removeItemIfExists(at: audioURL)
    }

    return .none
  }

  /// Move file to permanent location, create a transcript record, paste text, and play sound.
  func finalizeRecordingAndStoreTranscript(
    result: String,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    audioURL: URL,
    transcriptionHistory: Shared<TranscriptionHistory>
  ) async throws {
    @Shared(.hexSettings) var hexSettings: HexSettings

    // Hand the microphone back to the wake word however this exits — the
    // Larry branch below returns early, and a throw skips the tail entirely.
    defer { Task { @MainActor in LarryWakeWord.shared.resume() } }

    if hexSettings.saveTranscriptionHistory {
      let transcript = try await transcriptPersistence.save(
        result,
        audioURL,
        duration,
        sourceAppBundleID,
        sourceAppName
      )

      transcriptionHistory.withLock { history in
        history.history.insert(transcript, at: 0)

        if let maxEntries = hexSettings.maxHistoryEntries, maxEntries > 0 {
          while history.history.count > maxEntries {
            if let removedTranscript = history.history.popLast() {
              Task {
                 try? await transcriptPersistence.deleteAudio(removedTranscript)
              }
            }
          }
        }
      }
    } else {
      FileManager.default.removeItemIfExists(at: audioURL)
    }

    // Hey Larry: route the spoken text to Larry's voice brain and speak the
    // reply instead of pasting raw dictation. Falls back to paste on failure.
    if LarryVoice.isEnabled {
      await MainActor.run { LarryHUD.shared.setState(.thinking) }
      do {
        _ = try await LarryVoice.ask(result)
        await MainActor.run { LarryHUD.shared.setState(.standby) }
        return
      } catch {
        // Endpoint unreachable/slow — degrade gracefully to normal dictation.
        transcriptionFeatureLogger.error(
          "Larry unavailable, pasting transcript instead: \(error.localizedDescription, privacy: .public)"
        )
        await MainActor.run { LarryHUD.shared.setState(.standby) }
      }
    }

    await pasteboard.paste(result)
    soundEffect.play(.pasteTranscript)
  }
}

// MARK: - Cancel/Discard Handlers

private extension TranscriptionFeature {
  func handleCancel(_ state: inout State) -> Effect<Action> {
    let wasRecording = state.isRecording
    state.isTranscribing = false
    state.isRecording = false
    state.isPrewarming = false
    state.isHandsFree = false
    state.heardSpeech = false
    state.lastVoiceAt = nil
    state.loudestThisUtterance = 0

    return .merge(
      .cancel(id: CancelID.transcription),
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        guard wasRecording else {
          soundEffect.play(.cancel)
          return
        }
        // Stop the recording to release microphone access
        let url = await recording.stopRecording()
        guard !Task.isCancelled else { return }
        FileManager.default.removeItemIfExists(at: url)
        soundEffect.play(.cancel)
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }

  func handleDiscard(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isPrewarming = false

    // Silently discard - no sound effect
    return .merge(
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        let url = await recording.stopRecording()
        guard !Task.isCancelled else { return }
        FileManager.default.removeItemIfExists(at: url)
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }
}

// MARK: - View

struct TranscriptionView: View {
  @Bindable var store: StoreOf<TranscriptionFeature>
  @ObserveInjection var inject

  var status: TranscriptionIndicatorView.Status {
    if store.isTranscribing {
      return .transcribing
    } else if store.isRecording {
      return .recording
    } else if store.isPrewarming {
      return .prewarming
    } else {
      return .hidden
    }
  }

  var body: some View {
    TranscriptionIndicatorView(
      status: status,
      meter: store.meter
    )
    .task {
      await store.send(.task).finish()
    }
    .enableInjection()
  }
}

// MARK: - Force Quit Command

private enum ForceQuitCommandDetector {
  static func matches(_ text: String) -> Bool {
    let normalized = normalize(text)
    return normalized == "force quit hex now" || normalized == "force quit hex"
  }

  private static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
