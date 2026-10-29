import Charts
import SectorCore
import SwiftUI

/// "Свободное место за 30 дней": daily free-space samples, the trend per
/// day and where it leads.
struct ForecastCard: View {
  @Environment(AppModel.self) private var model

  private struct Point: Identifiable {
    var id: Date { date }
    var date: Date
    var gigabytes: Double
  }

  private struct Forecast {
    var points: [Point]
    var today: Point
    var end: Point
    var trend: Double
    var start: Date
  }

  var body: some View {
    let forecast = makeForecast()
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text("Свободное место за 30 дней")
          .font(.system(size: 13, weight: .semibold))
        Spacer(minLength: 8)
        if let forecast { trendChip(forecast.trend) }
      }
      if let forecast {
        ForecastChart(
          points: forecast.points.map { ($0.date, $0.gigabytes) },
          today: (forecast.today.date, forecast.today.gigabytes),
          end: (forecast.end.date, forecast.end.gigabytes)
        )
        .frame(height: 72)
        .padding(.top, 8)
        labels(forecast)
          .padding(.top, 4)
        Spacer(minLength: 4)
        Text(sentence(forecast))
          .font(.system(size: 12))
          .foregroundStyle(.primary.opacity(0.8))
          .lineLimit(2)
      } else {
        Spacer(minLength: 4)
        HStack(spacing: 12) {
          Image(systemName: "chart.line.downtrend.xyaxis")
            .font(.system(size: 22, weight: .light))
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 2) {
            Text("График появится через пару дней")
              .font(.system(size: 12, weight: .medium))
            Text("Sector отмечает свободное место раз в день и покажет, куда оно уходит.")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 4)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .overviewCard()
    .hoverLift()
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Прогноз свободного места")
  }

  // MARK: - Data

  private func makeForecast() -> Forecast? {
    let now = Date()
    let history = model.history
    let cutoff = now.addingTimeInterval(-30 * 86_400)
    let samples = history.samples.filter { $0.date >= cutoff }
    guard samples.count >= 2, let trend = history.dailyTrend(now: now),
      let first = samples.first, let last = samples.last
    else { return nil }
    let gb = pow(ByteFormat.base, 3)
    let points = samples.map { Point(date: $0.date, gigabytes: Double($0.available) / gb) }
    let available = Double(model.volume?.available ?? last.available)
    let today = Point(date: max(now, last.date), gigabytes: available / gb)
    // The forecast takes the last quarter of the chart, as in the mock.
    let span = max(86_400, today.date.timeIntervalSince(first.date))
    let horizon = span / 3
    let endValue = max(0, available + trend * horizon / 86_400)
    return Forecast(
      points: points + (last.date < today.date ? [today] : []), today: today,
      end: Point(date: today.date.addingTimeInterval(horizon), gigabytes: endValue / gb),
      trend: trend, start: first.date)
  }

  private func trendChip(_ trend: Double) -> some View {
    let falling = trend < 0
    let amount = ByteFormat.string(UInt64(abs(trend)))
    let color: Color = falling ? .sectorWarning : .sectorSuccess
    return Text(falling ? "−\(amount) в день" : "+\(amount) в день")
      .font(.system(size: 11, weight: .semibold))
      .monospacedDigit()
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .background(
        (falling ? Color.sectorWarningFill : Color.sectorSuccess).opacity(0.14),
        in: .rect(cornerRadius: 8))
  }

  private func labels(_ forecast: Forecast) -> some View {
    let total = forecast.end.date.timeIntervalSince(forecast.start)
    let todayFraction =
      total > 0 ? forecast.today.date.timeIntervalSince(forecast.start) / total : 0.75
    return GeometryReader { geo in
      ZStack(alignment: .topLeading) {
        Text(forecast.start.formatted(.dateTime.day().month(.abbreviated)))
          .fixedSize()
          .frame(maxWidth: .infinity, alignment: .leading)
        Text("Сегодня")
          .fixedSize()
          .position(x: min(geo.size.width - 60, geo.size.width * todayFraction), y: 7)
        Text("Прогноз")
          .fixedSize()
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
    .frame(height: 14)
  }

  private func sentence(_ forecast: Forecast) -> String {
    guard forecast.trend < 0 else {
      return String(localized: "Свободного места не становится меньше.")
    }
    let available = model.volume?.available ?? 0
    if let days = model.history.daysUntilFull(available: available), days <= 60 {
      let span = Plural.format(days, "день", "дня", "дней")
      return String(localized: "При таком темпе диск заполнится через \(span).")
    }
    let date = Date().addingTimeInterval(30 * 86_400).formatted(.dateTime.day().month(.wide))
    let left = HeroBytes.string(UInt64(max(0, Double(available) + forecast.trend * 30)))
    return String(localized: "При таком темпе к \(date) свободно останется ~\(left).")
  }
}

/// Line of free space with a fading area, a dashed forecast and a "today"
/// dot; draws in from the left.
private struct ForecastChart: View {
  var points: [(date: Date, value: Double)]
  var today: (date: Date, value: Double)
  var end: (date: Date, value: Double)
  @State private var reveal: CGFloat = 0

  var body: some View {
    let values = points.map(\.value) + [end.value]
    let low = values.min() ?? 0
    let high = values.max() ?? 1
    let pad = max(0.5, (high - low) * 0.15)
    let floor = max(0, low - pad)
    Chart {
      ForEach(points, id: \.date) { p in
        AreaMark(
          x: .value("Дата", p.date), yStart: .value("Минимум", floor),
          yEnd: .value("Свободно", p.value)
        )
        .foregroundStyle(
          LinearGradient(
            colors: [Color.sectorAccent.opacity(0.22), Color.sectorAccent.opacity(0)],
            startPoint: .top, endPoint: .bottom))
        LineMark(
          x: .value("Дата", p.date), y: .value("Свободно", p.value),
          series: .value("Ряд", "history")
        )
        .foregroundStyle(Color.sectorAccent)
        .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
      }
      LineMark(
        x: .value("Дата", today.date), y: .value("Свободно", today.value),
        series: .value("Ряд", "forecast")
      )
      .foregroundStyle(Color.sectorWarningFill)
      .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 5]))
      LineMark(
        x: .value("Дата", end.date), y: .value("Свободно", end.value),
        series: .value("Ряд", "forecast")
      )
      .foregroundStyle(Color.sectorWarningFill)
      .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 5]))
      PointMark(x: .value("Дата", today.date), y: .value("Свободно", today.value))
        .symbol {
          Circle()
            .fill(.background)
            .overlay(Circle().strokeBorder(Color.sectorAccent, lineWidth: 2.2))
            .frame(width: 9, height: 9)
        }
    }
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartLegend(.hidden)
    .chartYScale(domain: floor...(high + pad))
    .chartXScale(domain: (points.first?.date ?? today.date)...end.date)
    .mask(alignment: .leading) {
      GeometryReader { geo in
        Rectangle().frame(width: geo.size.width * reveal + 6)
      }
    }
    .onAppear {
      if Motion.reduced {
        reveal = 1
      } else {
        withAnimation(.timingCurve(0.32, 0.72, 0, 1, duration: 1.6).delay(0.4)) { reveal = 1 }
      }
    }
    .accessibilityHidden(true)
  }
}
