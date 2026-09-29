import Foundation

/// The currency costs are shown in: the macOS region's own, converted from the
/// USD the cost log records. With no rate for that currency they stay in USD.
struct Exchange: Equatable, Sendable {
    var currency: String
    var rate: Double

    static let usd = Exchange(currency: "USD", rate: 1)
    static let fallbackBRL = 5.40

    /// Reais read the rate the terminal statusline caches in `~/.claude/.usd_brl`
    /// first, so both show the same amount.
    static func current(locale: Locale = .current, brlText: String?, rates: [String: Double]) -> Exchange {
        guard let code = locale.currency?.identifier, code != "USD" else { return .usd }
        if code == "BRL", let brl = brlRate(brlText) { return Exchange(currency: code, rate: brl) }
        if let rate = rates[code], rate > 0 { return Exchange(currency: code, rate: rate) }
        if code == "BRL" { return Exchange(currency: code, rate: fallbackBRL) }
        return .usd
    }

    static func brlRate(_ contents: String?) -> Double? {
        guard let contents, let value = Double(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0, value < 100 else { return nil }
        return value
    }
}

/// USD → every currency, from open.er-api.com (free, no key; the service the
/// terminal statusline uses for USD → BRL). Fetched at most once a day and kept
/// in the app's cache folder.
enum ExchangeRates {
    static let endpoint = URL(string: "https://open.er-api.com/v6/latest/USD")!
    static let maxAge: TimeInterval = 86_400

    static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.cesar.claude-status-bar/usd_rates.json")
    }

    static func parse(_ data: Data) -> [String: Double]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["result"] as? String == "success",
              let raw = root["rates"] as? [String: Any]
        else { return nil }
        let rates = raw.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        return rates.isEmpty ? nil : rates
    }

    static func load(url: URL = cacheURL) -> [String: Double] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return parse(data) ?? [:]
    }

    static func isStale(url: URL = cacheURL, now: Date = Date()) -> Bool {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return true }
        return now.timeIntervalSince(modified) > maxAge
    }

    /// Keeps the old file when the network or the answer fails.
    static func refreshIfStale(url: URL = cacheURL, session: URLSession = .shared) async {
        guard isStale(url: url) else { return }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              parse(data) != nil
        else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
