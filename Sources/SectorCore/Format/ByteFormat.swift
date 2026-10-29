import Foundation

/// Formats byte counts the way the design shows them: "64,8 ГБ", with
/// decimal units by default (as Finder does) and the locale's separator.
public enum ByteFormat {
  /// Base for unit steps: 1000 (decimal, Finder) or 1024 (binary).
  nonisolated(unsafe) public static var base: Double = 1000

  public struct Parts: Sendable, Equatable {
    /// "64,8"
    public var number: String
    /// "ГБ"
    public var unit: String
  }

  private static let units = ["Б", "КБ", "МБ", "ГБ", "ТБ", "ПБ"]

  /// Splits a size into number and unit, so a view can style them apart.
  public static func parts(_ bytes: UInt64, locale: Locale = .current) -> Parts {
    var value = Double(bytes)
    var index = 0
    while value >= base * 0.9995 && index < units.count - 1 {
      value /= base
      index += 1
    }
    let digits = index == 0 ? 0 : (value >= 100 ? 0 : 1)
    let number = value.formatted(
      .number.precision(.fractionLength(digits)).grouping(.automatic).locale(locale))
    return Parts(number: number, unit: localizedUnit(index))
  }

  /// "64,8 ГБ"
  public static func string(_ bytes: UInt64, locale: Locale = .current) -> String {
    let p = parts(bytes, locale: locale)
    return "\(p.number) \(p.unit)"
  }

  public static func string(_ bytes: Int64, locale: Locale = .current) -> String {
    string(UInt64(max(0, bytes)), locale: locale)
  }

  /// Size in gigabytes with one decimal ("123,4"), for big counters that
  /// print the unit separately.
  public static func gigabytes(_ bytes: UInt64, locale: Locale = .current) -> String {
    (Double(bytes) / (base * base * base)).formatted(
      .number.precision(.fractionLength(1)).locale(locale))
  }

  public static func localizedUnit(_ index: Int) -> String {
    switch index {
    case 0: return String(localized: "Б")
    case 1: return String(localized: "КБ")
    case 2: return String(localized: "МБ")
    case 3: return String(localized: "ГБ")
    case 4: return String(localized: "ТБ")
    default: return String(localized: "ПБ")
    }
  }

  /// Gigabyte unit label alone ("ГБ").
  public static var gigabyteUnit: String { localizedUnit(3) }
}
