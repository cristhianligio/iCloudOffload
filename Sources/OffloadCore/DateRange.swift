import Foundation

/// Reglas para que el rango de fechas elegido sea realista:
/// - nunca en el futuro,
/// - nunca antes de 1900 (fecha razonable incluso para fotos antiguas escaneadas),
/// - «desde» nunca posterior a «hasta».
public enum DateRangePolicy {
    public static let earliest: Date = {
        var c = DateComponents(); c.year = 1900; c.month = 1; c.day = 1
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    /// Rango permitido para «Desde».
    public static func fromRange(to: Date, now: Date = Date()) -> ClosedRange<Date> {
        earliest...min(max(to, earliest), now)
    }

    /// Rango permitido para «Hasta».
    public static func toRange(from: Date, now: Date = Date()) -> ClosedRange<Date> {
        min(max(from, earliest), now)...now
    }

    /// Corrige cualquier par de fechas para que cumpla las reglas.
    public static func clamp(from: Date, to: Date, now: Date = Date()) -> (from: Date, to: Date) {
        let t = min(max(to, earliest), now)
        let f = min(max(from, earliest), t)
        return (f, t)
    }

    /// Límites para la búsqueda: [inicio del día «desde», inicio del día siguiente a «hasta»).
    public static func fetchBounds(from: Date, to: Date, calendar: Calendar = .current, now: Date = Date())
        -> (start: Date, endExclusive: Date)
    {
        let (f, t) = clamp(from: from, to: to, now: now)
        let start = calendar.startOfDay(for: f)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: t)) ?? t
        return (start, end)
    }
}
