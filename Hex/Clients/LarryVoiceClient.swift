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

import Foundation
import AppKit

enum LarryVoice {
  /// Endpoint on our VPS. Same brain as Discord (memory + tasks + persona).
  static let endpoint = URL(string: "https://shopify.activepromotion.dk/larry/voice")!

  /// Larry-mode is on unless explicitly disabled.
  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: "larryVoiceEnabled") == nil
      ? true
      : UserDefaults.standard.bool(forKey: "larryVoiceEnabled")
  }

  private struct Response: Decodable {
    struct Data: Decodable {
      let reply: String
      let audio: Audio?
    }
    struct Audio: Decodable {
      let mime: String
      let audio_b64: String
    }
    let ok: Bool
    let data: Data?
  }

  /// Send the spoken text to Larry, play the audio reply, and return the reply text.
  /// Throws on network/decoding failure so the caller can fall back to pasting.
  @discardableResult
  static func ask(_ text: String) async throws -> String {
    var req = URLRequest(url: endpoint)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 120
    let body: [String: Any] = ["text": text, "tts": true]
    req.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
      throw URLError(.badServerResponse)
    }

    let decoded = try JSONDecoder().decode(Response.self, from: data)
    guard decoded.ok, let payload = decoded.data else {
      throw URLError(.cannotParseResponse)
    }

    if let audio = payload.audio, let wav = Foundation.Data(base64Encoded: audio.audio_b64) {
      try play(wav: wav)
    }
    return payload.reply
  }

  /// Write the WAV to a temp file and play it via afplay (blocks until done).
  private static func play(wav: Foundation.Data) throws {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("larry_reply_\(UUID().uuidString).wav")
    try wav.write(to: tmp)
    if let sound = NSSound(contentsOf: tmp, byReference: false) {
      sound.play()
    }
  }
}
