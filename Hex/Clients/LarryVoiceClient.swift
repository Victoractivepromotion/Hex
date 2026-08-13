//
//  LarryVoiceClient.swift
//  Hex — "Hey Larry" wiring
//
//  Routes a finished transcription to Larry's voice brain (/larry/voice) and
//  speaks the reply out loud instead of pasting the raw dictation.
//
//  Enabled by default in this fork (the whole point of the build). Toggle off
//  via UserDefaults key "larryVoiceEnabled" to fall back to plain dictation.
//
//  Wire-format notes, all verified against the live endpoint:
//
//    * It never returns `audio/wav`. The reply is always JSON with the WAV
//      base64-encoded inside it:
//        {"ok":true,"data":{"reply":"…","audio":{"mime":"audio/wav",
//                                                "audio_b64":"UklGRr…"}}}
//    * Failures arrive as HTTP **200** with {"ok":false,"error":"…"}, so the
//      status code alone cannot tell success from failure.
//    * Round-trips measure 42–48 s, so the timeout has real headroom.
//    * `data.audio` is absent when tts is false — never force-unwrap it.
//
//  Decoded audio is 1 ch, 24 kHz, Int16 WAV.
//

import AVFoundation
import Foundation
import HexCore

private let larryLog = HexLog.larryVoice

enum LarryVoice {
  /// Endpoint on our VPS. Same brain as Discord (memory + tasks + persona).
  static let endpoint = URL(string: "https://shopify.activepromotion.dk/larry/voice")!

  /// Larry-mode is on unless explicitly disabled.
  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: "larryVoiceEnabled") == nil
      ? true
      : UserDefaults.standard.bool(forKey: "larryVoiceEnabled")
  }

  enum Failure: LocalizedError {
    case emptyTranscript
    case httpStatus(Int)
    /// 200 with `{"ok": false, "error": "…"}`.
    case server(String)
    case malformedResponse

    var errorDescription: String? {
      switch self {
      case .emptyTranscript: return "Nothing was transcribed"
      case let .httpStatus(code): return "Larry returned HTTP \(code)"
      case let .server(message): return message
      case .malformedResponse: return "Larry sent a response I couldn't parse"
      }
    }
  }

  private struct Response: Decodable {
    struct Payload: Decodable {
      let reply: String?
      let audio: Audio?
    }

    struct Audio: Decodable {
      let mime: String?
      let audioB64: String?

      enum CodingKeys: String, CodingKey {
        case mime
        case audioB64 = "audio_b64"
      }

      /// Base64 → WAV bytes, tolerating a `data:` URI prefix and line wrapping.
      func decoded() -> Foundation.Data? {
        guard var encoded = audioB64, !encoded.isEmpty else { return nil }
        if let marker = encoded.range(of: "base64,") {
          encoded = String(encoded[marker.upperBound...])
        }
        guard let bytes = Foundation.Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              !bytes.isEmpty
        else {
          larryLog.error("audio_b64 present but undecodable")
          return nil
        }
        return bytes
      }
    }

    let ok: Bool
    let error: String?
    let data: Payload?
  }

  /// Measured round-trip is 42–48 s; leave real headroom above that.
  private static let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 120
    config.timeoutIntervalForResource = 180
    config.waitsForConnectivity = true
    return URLSession(configuration: config)
  }()

  /// Send the spoken text to Larry, play the audio reply, and return the reply text.
  /// Throws on network/decoding failure so the caller can fall back to pasting.
  @discardableResult
  static func ask(_ text: String) async throws -> String {
    let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !spoken.isEmpty else { throw Failure.emptyTranscript }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONSerialization.data(
      withJSONObject: ["text": spoken, "tts": true]
    )

    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
      throw Failure.httpStatus(http.statusCode)
    }

    let decoded: Response
    do {
      decoded = try JSONDecoder().decode(Response.self, from: data)
    } catch {
      larryLog.error(
        "Undecodable body: \(String(decoding: data.prefix(400), as: UTF8.self), privacy: .public)"
      )
      throw Failure.malformedResponse
    }

    // Errors ride in on a 200 — the `ok` flag is the only reliable signal.
    guard decoded.ok else {
      throw Failure.server(decoded.error ?? "Larry reported an unspecified failure")
    }
    guard let payload = decoded.data, let reply = payload.reply, !reply.isEmpty else {
      throw Failure.malformedResponse
    }

    if let wav = payload.audio?.decoded() {
      await MainActor.run { LarryHUD.shared.setState(.speaking) }
      await LarryAudioPlayer.shared.play(wav)
    } else {
      // Not fatal — the caller still has text.
      larryLog.warning("Requested TTS but no audio came back; text-only reply")
    }

    larryLog.info("Larry replied (\(reply.count) chars)")
    return reply
  }
}

// MARK: - Playback

/// Plays Larry's replies one at a time.
///
/// `AVAudioPlayer` must be retained for the whole of playback. The previous
/// implementation used a local `NSSound` that went out of scope the moment
/// `play()` returned, which truncates or silences the reply — hence the
/// property here, plus an await that only resolves once playback ends.
@MainActor
final class LarryAudioPlayer: NSObject, AVAudioPlayerDelegate {
  static let shared = LarryAudioPlayer()

  private var player: AVAudioPlayer?
  private var continuation: CheckedContinuation<Void, Never>?

  /// Plays `data`, returning once it has finished (or failed to start).
  func play(_ data: Data) async {
    stop()
    // Tell the wake word a reply is playing, so it will also accept a bare
    // "Larry" or "stop" as an interrupt for as long as he is talking.
    LarryWakeWord.shared.isSpeaking = true
    defer { LarryWakeWord.shared.isSpeaking = false }
    do {
      let player = try AVAudioPlayer(data: data)
      player.delegate = self
      player.prepareToPlay()
      self.player = player
      guard player.play() else {
        larryLog.error("AVAudioPlayer refused to start")
        self.player = nil
        return
      }
    } catch {
      larryLog.error("Cannot play reply audio: \(error.localizedDescription, privacy: .public)")
      return
    }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  /// Cuts playback short so Larry stops mid-sentence when a new recording
  /// starts, instead of talking over you.
  func stop() {
    player?.stop()
    player = nil
    finish()
  }

  private func finish() {
    continuation?.resume()
    continuation = nil
  }

  nonisolated func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
    Task { @MainActor in
      self.player = nil
      self.finish()
    }
  }

  nonisolated func audioPlayerDecodeErrorDidOccur(_: AVAudioPlayer, error: Error?) {
    larryLog.error(
      "Decode error during playback: \(error?.localizedDescription ?? "unknown", privacy: .public)"
    )
    Task { @MainActor in
      self.player = nil
      self.finish()
    }
  }
}

// MARK: - Startup chime

/// Fetches the Jarvis startup sound once, caches it on disk, and plays it at launch.
enum LarryStartupSound {
  private static let remote = URL(
    string: "https://shopify.activepromotion.dk/rebuilt-videos/jarvis_startup.mp3"
  )!

  private static var cacheURL: URL? {
    guard let support = try? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ) else { return nil }
    let directory = support.appendingPathComponent("Hex", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("jarvis_startup.mp3")
  }

  /// Call once at launch. Downloads on first run, plays from cache thereafter.
  static func play() async {
    guard LarryVoice.isEnabled, let cacheURL else { return }

    if !FileManager.default.fileExists(atPath: cacheURL.path) {
      do {
        let (data, response) = try await URLSession.shared.data(from: remote)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
          larryLog.error("Startup sound HTTP \(http.statusCode)")
          return
        }
        try data.write(to: cacheURL, options: .atomic)
        larryLog.info("Cached startup sound (\(data.count) bytes)")
      } catch {
        larryLog.error("Startup sound unavailable: \(error.localizedDescription, privacy: .public)")
        return
      }
    }

    guard let data = try? Data(contentsOf: cacheURL) else { return }
    await LarryAudioPlayer.shared.play(data)
  }
}
