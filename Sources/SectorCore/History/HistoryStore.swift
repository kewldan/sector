import Foundation

/// What produced a cleanup, for the History list icon and wording.
public enum CleanupSource: String, Codable, Sendable {
  case smartClean, files, duplicates, apps, trash, explorer
}

/// One cleanup the user performed through Sector.
public struct CleanupRecord: Codable, Sendable, Identifiable, Hashable {
  public var id: UUID
  public var date: Date
  public var source: CleanupSource
  /// "Умная очистка", "Docker.raw", …
  public var title: String
  /// "7 категорий · 77 901 объект"
  public var detail: String
  public var mode: RemovalMode
  public var items: [RemovalOutcome.Removed]
  /// Original paths already moved back from the Trash.
  public var restoredPaths: Set<String>

  public init(
    id: UUID = UUID(), date: Date = Date(), source: CleanupSource, title: String, detail: String,
    mode: RemovalMode, items: [RemovalOutcome.Removed], restoredPaths: Set<String> = []
  ) {
    self.id = id
    self.date = date
    self.source = source
    self.title = title
    self.detail = detail
    self.mode = mode
    self.items = items
    self.restoredPaths = restoredPaths
  }

  public var freedBytes: UInt64 { items.reduce(0) { $0 + $1.size } }
  public var isFullyRestored: Bool { !items.isEmpty && restoredPaths.count >= items.count }
}

/// A free-space sample, for the 30-day chart and the "fills up in" forecast.
public struct SpaceSample: Codable, Sendable, Hashable {
  public var date: Date
  public var available: UInt64
  public var total: UInt64
}

/// Persists cleanup history and free-space samples as JSON in
/// `~/Library/Application Support/Sector`.
public final class HistoryStore: @unchecked Sendable {
  public private(set) var records: [CleanupRecord] = []
  public private(set) var samples: [SpaceSample] = []

  private let directory: URL
  private let lock = NSLock()

  public init(directory: URL? = nil) {
    self.directory =
      directory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Sector", isDirectory: true)
    load()
  }

  private var recordsURL: URL { directory.appendingPathComponent("history.json") }
  private var samplesURL: URL { directory.appendingPathComponent("space-samples.json") }

  private func load() {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let data = try? Data(contentsOf: recordsURL),
      let decoded = try? decoder.decode([CleanupRecord].self, from: data)
    {
      records = decoded
    }
    if let data = try? Data(contentsOf: samplesURL),
      let decoded = try? decoder.decode([SpaceSample].self, from: data)
    {
      samples = decoded
    }
  }

  private func save() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let data = try? encoder.encode(records) { try? data.write(to: recordsURL, options: .atomic) }
    if let data = try? encoder.encode(samples) { try? data.write(to: samplesURL, options: .atomic) }
  }

  public func add(_ record: CleanupRecord) {
    lock.withLock {
      records.insert(record, at: 0)
      save()
    }
  }

  public func update(_ record: CleanupRecord) {
    lock.withLock {
      guard let i = records.firstIndex(where: { $0.id == record.id }) else { return }
      records[i] = record
      save()
    }
  }

  /// Records today's free space; keeps one sample per day for 180 days.
  public func sample(_ volume: VolumeInfo, at date: Date = Date()) {
    lock.withLock {
      let calendar = Calendar.current
      samples.removeAll { calendar.isDate($0.date, inSameDayAs: date) }
      samples.append(SpaceSample(date: date, available: volume.available, total: volume.total))
      samples.sort { $0.date < $1.date }
      let cutoff = date.addingTimeInterval(-180 * 86_400)
      samples.removeAll { $0.date < cutoff }
      save()
    }
  }

  /// Average daily change of free space over the last `days` (negative when
  /// the disk is filling up), or nil without enough data.
  public func dailyTrend(days: Int = 30, now: Date = Date()) -> Double? {
    let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
    let recent = samples.filter { $0.date >= cutoff }
    guard let first = recent.first, let last = recent.last, last.date > first.date else {
      return nil
    }
    let span = last.date.timeIntervalSince(first.date) / 86_400
    guard span >= 1 else { return nil }
    return (Double(last.available) - Double(first.available)) / span
  }

  /// Days until free space reaches zero at the current trend.
  public func daysUntilFull(available: UInt64, now: Date = Date()) -> Int? {
    guard let trend = dailyTrend(now: now), trend < 0 else { return nil }
    return Int(Double(available) / -trend)
  }

  /// Total freed by cleanups since `date`.
  public func freed(since date: Date) -> UInt64 {
    records.filter { $0.date >= date }.reduce(0) { $0 + $1.freedBytes }
  }
}
