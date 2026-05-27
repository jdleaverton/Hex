import Foundation
import HexCore

#if canImport(FluidAudio)
import FluidAudio

actor ParakeetClient {
  private var asr: AsrManager?
  private var models: AsrModels?
  private var currentVariant: ParakeetModel?
  private var loadTask: Task<Void, Error>?
  private var loadVariant: ParakeetModel?
  private var loadGeneration = 0
  /// Guards against concurrent inference. FluidAudio's AsrManager is not
  /// safe for overlapping predictions — concurrent calls corrupt shared
  /// MLMultiArray buffers and crash in CoreML's prediction pipeline.
  private var isTranscribing = false
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

    if let loadTask, loadVariant == variant {
      logger.notice("Joining in-flight Parakeet load variant=\(variant.identifier)")
      let p = Progress(totalUnitCount: 100)
      p.completedUnitCount = 1
      progress(p)
      try await loadTask.value
      p.completedUnitCount = 100
      progress(p)
      return
    }

    if let loadTask, let loadVariant {
      logger.notice("Cancelling stale Parakeet load oldVariant=\(loadVariant.identifier) newVariant=\(variant.identifier)")
      loadTask.cancel()
      self.loadTask = nil
      self.loadVariant = nil
    }

    if currentVariant != variant {
      asr = nil
      models = nil
    }

    loadGeneration += 1
    let generation = loadGeneration
    let task = Task {
      try await self.loadParakeet(variant: variant, progress: progress)
    }
    loadTask = task
    loadVariant = variant

    do {
      try await task.value
    } catch {
      if loadGeneration == generation {
        loadTask = nil
        loadVariant = nil
      }
      logger.error("Parakeet load failed variant=\(variant.identifier) error=\(error.localizedDescription)")
      throw error
    }

    if loadGeneration == generation {
      loadTask = nil
      loadVariant = nil
    }
  }

  private func loadParakeet(variant: ParakeetModel, progress: @escaping (Progress) -> Void) async throws {
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
    try Task.checkCancellation()
    self.models = models
    let manager = AsrManager(config: .init())
    try await manager.initialize(models: models)
    try Task.checkCancellation()
    self.asr = manager
    self.currentVariant = variant
    p.completedUnitCount = 100
    progress(p)
    logger.notice("Parakeet load completed variant=\(variant.identifier) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    await warmup()
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
    let queueStart = Date()
    try await waitForInferenceSlot()
    let queuedMs = Int(Date().timeIntervalSince(queueStart) * 1000)
    defer { isTranscribing = false }
    let t0 = Date()
    logger.notice("Transcribing with Parakeet file=\(url.lastPathComponent) queuedMs=\(queuedMs)")
    let result = try await asr.transcribe(url)
    let inferenceMs = Int(Date().timeIntervalSince(t0) * 1000)
    logger.info("Parakeet transcription finished queuedMs=\(queuedMs) inferenceMs=\(inferenceMs)")
    return ParakeetTextNormalization.cleanChunkBoundaryArtifacts(result.text)
  }

  /// Transcribe raw 16 kHz mono Float32 samples directly, skipping file I/O.
  /// FluidAudio's ChunkProcessor handles chunking internally for audio >15s
  /// with ~15s windows, 2s overlap, and 3-tier merge (contiguous/LCS/midpoint).
  func transcribe(samples: [Float]) async throws -> String {
    guard let asr else { throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Parakeet not initialized"]) }
    let queueStart = Date()
    try await waitForInferenceSlot()
    let queuedMs = Int(Date().timeIntervalSince(queueStart) * 1000)
    defer { isTranscribing = false }
    let t0 = Date()
    let sampleCount = samples.count
    let durationSec = Double(sampleCount) / 16000.0
    logger.notice("Transcribing with Parakeet samples=\(sampleCount) (~\(String(format: "%.1f", durationSec))s) queuedMs=\(queuedMs)")
    let result = try await asr.transcribe(samples)
    let inferenceMs = Int(Date().timeIntervalSince(t0) * 1000)
    logger.info("Parakeet buffer transcription finished queuedMs=\(queuedMs) inferenceMs=\(inferenceMs)")
    return ParakeetTextNormalization.cleanChunkBoundaryArtifacts(result.text)
  }

  private func waitForInferenceSlot() async throws {
    var loggedQueue = false
    while isTranscribing {
      if !loggedQueue {
        logger.notice("Queueing Parakeet transcription while inference is in progress")
        loggedQueue = true
      }
      try Task.checkCancellation()
      try await Task.sleep(for: .milliseconds(20))
    }
    isTranscribing = true
  }

  /// Release the in-memory model objects without deleting cached files on disk.
  /// The next transcription will re-load from the local cache.
  func unload(reason: String) {
    guard !isTranscribing else {
      logger.warning("Skipping Parakeet unload reason=\(reason) - inference in progress")
      return
    }
    asr = nil
    models = nil
    currentVariant = nil
    loadTask?.cancel()
    loadTask = nil
    loadVariant = nil
    logger.info("Parakeet model unloaded reason=\(reason)")
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
      if loadVariant == variant {
        loadTask?.cancel()
        loadTask = nil
        loadVariant = nil
      }
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
  func unload(reason: String) {}
  func warmup() async {}
  func deleteCaches(modelName: String) async throws {}
}

#endif
