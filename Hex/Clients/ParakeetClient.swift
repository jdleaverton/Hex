import Foundation
import HexCore

#if canImport(FluidAudio)
import FluidAudio

actor ParakeetClient {
  private var asr: AsrManager?
  private var models: AsrModels?
  private var currentVariant: ParakeetModel?
  private let logger = HexLog.parakeet
  private let vendorDirs = [
    // Our app-specific cache path convention (under XDG or {bundleID}/cache)
    "fluidaudio/Models",
    "FluidAudio/Models",
    // FluidAudio default under Application Support root
    "FluidAudio/Models"
  ]

  func isModelAvailable(_ modelName: String) async -> Bool {
    guard let variant = ParakeetModel(rawValue: modelName) else {
      logger.error("Unknown Parakeet variant requested: \(modelName)")
      return false
    }
    if currentVariant == variant, asr != nil { return true }

    logger.debug("Checking Parakeet availability variant=\(variant.identifier)")
    for dir in modelDirectories(variant) {
      if directoryContainsMLModelC(dir) {
        logger.notice("Found Parakeet cache at \(dir.path)")
        return true
      }
    }
    logger.debug("No Parakeet cache detected variant=\(variant.identifier)")
    return false
  }

  private func directoryContainsMLModelC(_ dir: URL) -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: dir.path) else { return false }
    if let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
      for case let url as URL in en {
        if url.pathExtension == "mlmodelc" || url.lastPathComponent.hasSuffix(".mlmodelc") { return true }
      }
    }
    return false
  }

  func ensureLoaded(modelName: String, progress: @escaping (Progress) -> Void) async throws {
    guard let variant = ParakeetModel(rawValue: modelName) else {
      throw NSError(
        domain: "Parakeet",
        code: -4,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported Parakeet variant: \(modelName)"]
      )
    }
    if currentVariant == variant, asr != nil { return }
    if currentVariant != variant {
      asr = nil
      models = nil
    }
    let t0 = Date()
    logger.notice("Starting Parakeet load variant=\(variant.identifier)")
    let p = Progress(totalUnitCount: 100)
    p.completedUnitCount = 1
    progress(p)

    // Best-effort progress polling while FluidAudio downloads
    let fm = FileManager.default
    let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let faDir = support?.appendingPathComponent("FluidAudio/Models/\(variant.identifier)", isDirectory: true)
    let pollTask = Task {
      while p.completedUnitCount < 95 {
        try? await Task.sleep(nanoseconds: 250_000_000)
        if let dir = faDir, let size = directorySize(dir) {
          let target: Double = 650 * 1024 * 1024 // ~650MB
          let frac = max(0.0, min(1.0, Double(size) / target))
          p.completedUnitCount = Int64(5 + frac * 90)
          progress(p)
        }
        if Task.isCancelled { break }
      }
    }
    defer { pollTask.cancel() }

    // Download + load the requested variant (returns when all assets are present)
    let models = try await AsrModels.downloadAndLoad(version: variant.asrVersion)
    self.models = models
    let manager = AsrManager(config: .init())
    try await manager.initialize(models: models)
    self.asr = manager
    self.currentVariant = variant
    p.completedUnitCount = 100
    progress(p)
    logger.notice("Parakeet ensureLoaded completed in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
  }

  private func directorySize(_ dir: URL) -> UInt64? {
    let fm = FileManager.default
    guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: .skipsHiddenFiles) else { return nil }
    var total: UInt64 = 0
    for case let url as URL in en {
      if let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), vals.isRegularFile == true {
        total &+= UInt64(vals.fileSize ?? 0)
      }
    }
    return total
  }

  func transcribe(_ url: URL) async throws -> String {
    guard let asr else { throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Parakeet not initialized"]) }
    let t0 = Date()
    logger.notice("Transcribing with Parakeet file=\(url.lastPathComponent)")
    let result = try await asr.transcribe(url)
    logger.info("Parakeet transcription finished in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    return Self.cleanChunkBoundaryArtifacts(result.text)
  }

  /// Transcribe raw 16 kHz mono Float32 samples directly, skipping file I/O.
  /// FluidAudio's ChunkProcessor handles chunking internally for audio >15s
  /// with ~15s windows, 2s overlap, and 3-tier merge (contiguous/LCS/midpoint).
  func transcribe(samples: [Float]) async throws -> String {
    guard let asr else { throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Parakeet not initialized"]) }
    let t0 = Date()
    let sampleCount = samples.count
    let durationSec = Double(sampleCount) / 16000.0
    logger.notice("Transcribing with Parakeet samples=\(sampleCount) (~\(String(format: "%.1f", durationSec))s)")
    let result = try await asr.transcribe(samples)
    logger.info("Parakeet buffer transcription finished in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    return Self.cleanChunkBoundaryArtifacts(result.text)
  }

  /// Cleans up artifacts from FluidAudio's ChunkProcessor merge.
  ///
  /// When audio is split into ~15s chunks, the TDT decoder appends a period at each
  /// chunk boundary (thinking it's the end of the utterance). The 3-tier merge keeps
  /// these as legitimate tokens, producing mid-word periods like "t.ier" or "m.erge".
  ///
  /// This removes periods that appear between two letters with no surrounding spaces,
  /// which are always chunk boundary artifacts, never real punctuation.
  private static func cleanChunkBoundaryArtifacts(_ text: String) -> String {
    // Pattern: a letter, then period, then a lowercase letter — always a chunk artifact.
    // Real sentence-ending periods are followed by a space or end-of-string.
    // Abbreviations like "U.S." have periods after uppercase letters (not matched).
    guard let regex = try? NSRegularExpression(pattern: #"(\p{L})\.(\p{Ll})"#) else {
      return text
    }
    let range = NSRange(text.startIndex..., in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1$2")
  }

  /// Release the in-memory model objects without deleting cached files on disk.
  /// The next transcription will re-load from the local cache.
  func unload() {
    asr = nil
    models = nil
    currentVariant = nil
    logger.info("Parakeet model unloaded from memory")
  }

  /// Run a short silent transcription to prime the ANE pipeline.
  /// Call after ensureLoaded() so the first real transcription is fast.
  func warmup() async {
    guard let asr else { return }
    let t0 = Date()
    logger.debug("Warming up Parakeet ANE pipeline...")
    // Minimum 1s (16000 samples) of silence to trigger full inference path
    let silence = [Float](repeating: 0, count: 16000)
    _ = try? await asr.transcribe(silence)
    logger.notice("Parakeet ANE warmup completed in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
  }

  // Delete cached Parakeet models from known locations and reset state
  func deleteCaches(modelName: String) async throws {
    guard let variant = ParakeetModel(rawValue: modelName) else { return }
    let fm = FileManager.default

    var removedAny = false
    for dir in modelDirectories(variant) {
      if fm.fileExists(atPath: dir.path) {
        try? fm.removeItem(at: dir)
        removedAny = true
      }
    }

    // Reset live objects so a future download can proceed cleanly
    if removedAny {
      self.asr = nil
      self.models = nil
      if currentVariant == variant {
        currentVariant = nil
      }
    }
  }

  /// Returns all candidate directories where a Parakeet model might be cached.
  /// Includes both exact matches and prefixed directories (e.g. versioned folders).
  private func modelDirectories(_ variant: ParakeetModel) -> [URL] {
    let fm = FileManager.default
    var result: [URL] = []

    for root in candidateRoots() {
      for vendor in vendorDirs {
        let base = root.appendingPathComponent(vendor, isDirectory: true)
        // Exact match directory
        let direct = base.appendingPathComponent(variant.identifier, isDirectory: true)
        result.append(direct)
        // Prefixed directories (e.g. versioned folders)
        if let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
          for item in items where item.lastPathComponent.hasPrefix(variant.identifier) && item != direct {
            result.append(item)
          }
        }
      }
    }
    return result
  }

  private func candidateRoots() -> [URL] {
    let fm = FileManager.default
    let xdg = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
    let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    let bundleID = Bundle.main.bundleIdentifier ?? "com.jdleaverton.Hex"
    let appCache = appSupport?.appendingPathComponent("\(bundleID)/cache", isDirectory: true)
    let userCache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache", isDirectory: true)
    return [xdg, appCache, appSupport, userCache].compactMap { $0 }
  }
}

private extension ParakeetModel {
  var asrVersion: AsrModelVersion {
    switch self {
    case .englishV2: return .v2
    case .multilingualV3: return .v3
    }
  }
}

#else

actor ParakeetClient {
  func isModelAvailable(_ modelName: String) async -> Bool { false }
  func ensureLoaded(modelName: String, progress: @escaping (Progress) -> Void) async throws {
    throw NSError(
      domain: "Parakeet",
      code: -2,
      userInfo: [NSLocalizedDescriptionKey: "Parakeet support not linked. Add Swift Package: https://github.com/FluidInference/FluidAudio.git and link FluidAudio to Hex."]
    )
  }
  func transcribe(_ url: URL) async throws -> String { throw NSError(domain: "Parakeet", code: -3, userInfo: [NSLocalizedDescriptionKey: "Parakeet not available"]) }
  func transcribe(samples: [Float]) async throws -> String { throw NSError(domain: "Parakeet", code: -3, userInfo: [NSLocalizedDescriptionKey: "Parakeet not available"]) }
  func unload() {}
  func warmup() async {}
  func deleteCaches(modelName: String) async throws {}
}

#endif
