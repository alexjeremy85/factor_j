import Foundation

/// Formatação de timestamps usada na UI e nas exportações.
public enum TimeFormat {
    /// "1:05" ou "1:02:05" — exibição na UI.
    public static func display(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// "00:00:05,120" — formato SRT.
    public static func srt(ms: Int) -> String {
        String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms % 3_600_000) / 60_000, (ms % 60_000) / 1000, ms % 1000)
    }

    /// "00:00:05.120" — formato WebVTT.
    public static func vtt(ms: Int) -> String {
        String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, (ms % 3_600_000) / 60_000, (ms % 60_000) / 1000, ms % 1000)
    }

    /// "1h02min" / "5min" / "32s" — duração amigável.
    public static func duration(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh%02dmin", h, m) }
        if m > 0 { return "\(m)min" }
        return "\(s)s"
    }
}
