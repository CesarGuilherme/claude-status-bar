import Foundation

struct UsageResponse: Decodable, Equatable, Sendable {
    var fiveHour: UsageBucket?
    var sevenDay: UsageBucket?
    var sevenDayOpus: UsageBucket?
    var sevenDaySonnet: UsageBucket?
    var extraUsage: ExtraUsage?
    var limits: [UsageLimit]

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
        case limits
    }

    init(
        fiveHour: UsageBucket? = nil,
        sevenDay: UsageBucket? = nil,
        sevenDayOpus: UsageBucket? = nil,
        sevenDaySonnet: UsageBucket? = nil,
        extraUsage: ExtraUsage? = nil,
        limits: [UsageLimit] = []
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.extraUsage = extraUsage
        self.limits = limits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try container.decodeIfPresent(UsageBucket.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(UsageBucket.self, forKey: .sevenDay)
        sevenDayOpus = try container.decodeIfPresent(UsageBucket.self, forKey: .sevenDayOpus)
        sevenDaySonnet = try container.decodeIfPresent(UsageBucket.self, forKey: .sevenDaySonnet)
        extraUsage = try container.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)
        limits = Self.decodeLimits(container)
    }

    /// Weekly rows. A `limits` entry with no surface replaces the legacy
    /// `seven_day_opus` / `seven_day_sonnet` field for that model. A surfaced
    /// window is a different measurement and stays beside the account row.
    func perModelWeekly() -> [PerModelUsage] {
        let weekly = limits.filter(\.isWeeklyModel)
        var rows = weekly.map(\.row)

        let superseded = Set(
            weekly
                .filter { $0.scope?.surface?.displayName?.isEmpty ?? true }
                .compactMap { $0.scope?.model?.displayName?.lowercased() }
        )

        func appendFixed(id: String, name: String, bucket: UsageBucket?) {
            guard let percent = bucket?.utilization else { return }
            guard !superseded.contains(name.lowercased()) else { return }
            rows.append(PerModelUsage(
                id: id,
                displayName: name,
                percent: percent,
                resetsAt: bucket?.resetsAt,
                group: nil
            ))
        }

        appendFixed(id: "seven_day_opus", name: "Opus", bucket: sevenDayOpus)
        appendFixed(id: "seven_day_sonnet", name: "Sonnet", bucket: sevenDaySonnet)
        return Self.disambiguate(rows)
    }

    private static func disambiguate(_ rows: [PerModelUsage]) -> [PerModelUsage] {
        let duplicated = Set(
            Dictionary(grouping: rows, by: \.displayName)
                .filter { $0.value.count > 1 }
                .map(\.key)
        )
        guard !duplicated.isEmpty else { return rows }
        return rows.map { row in
            guard duplicated.contains(row.displayName),
                  let group = row.group, !group.isEmpty else { return row }
            var copy = row
            copy.displayName = "\(row.displayName) — \(group)"
            return copy
        }
    }

    private static func decodeLimits(_ container: KeyedDecodingContainer<CodingKeys>) -> [UsageLimit] {
        guard var array = try? container.nestedUnkeyedContainer(forKey: .limits) else { return [] }
        var limits: [UsageLimit] = []
        while !array.isAtEnd {
            if let item = try? array.decode(UsageLimit.self) {
                limits.append(item)
            } else {
                _ = try? array.decode(DiscardJSON.self)
            }
        }
        return limits
    }
}

private struct DiscardJSON: Decodable {
    init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            while !unkeyed.isAtEnd {
                _ = try unkeyed.decode(DiscardJSON.self)
            }
            return
        }
        if let keyed = try? decoder.container(keyedBy: AnyKey.self) {
            for key in keyed.allKeys {
                _ = try keyed.decode(DiscardJSON.self, forKey: key)
            }
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { return }
        if (try? single.decode(Bool.self)) != nil { return }
        if (try? single.decode(Double.self)) != nil { return }
        _ = try? single.decode(String.self)
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) {
            self.stringValue = "\(intValue)"
            self.intValue = intValue
        }
    }
}

struct UsageBucket: Decodable, Equatable, Sendable {
    var utilization: Double?
    var resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(utilization: Double? = nil, resetsAt: String? = nil) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try container.decodeIfPresent(Double.self, forKey: .utilization)
        resetsAt = Self.decodeReset(container)
    }

    fileprivate static func decodeReset(_ container: KeyedDecodingContainer<CodingKeys>) -> String? {
        if let epoch = try? container.decode(Double.self, forKey: .resetsAt) {
            let seconds = epoch > 1_000_000_000_000 ? epoch / 1000 : epoch
            return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
        }
        return try? container.decodeIfPresent(String.self, forKey: .resetsAt)
    }
}

struct UsageLimit: Decodable, Equatable, Sendable {
    var kind: String?
    var group: String?
    var percent: Double?
    var resetsAt: String?
    var scope: UsageLimitScope?

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, scope
        case resetsAt = "resets_at"
    }

    var isWeeklyModel: Bool {
        kind == "weekly_scoped" && percent != nil && scope?.model?.displayName?.isEmpty == false
    }

    var row: PerModelUsage {
        let model = scope?.model?.displayName ?? ""
        let rawSurface = scope?.surface?.displayName
        let surface = (rawSurface?.isEmpty == false) ? rawSurface : nil
        return PerModelUsage(
            id: [kind, group, model, surface].map { $0 ?? "" }.joined(separator: "\u{1F}"),
            displayName: surface.map { "\(model) (\($0))" } ?? model,
            percent: percent ?? 0,
            resetsAt: resetsAt,
            group: group
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        percent = try container.decodeIfPresent(Double.self, forKey: .percent)
        scope = try container.decodeIfPresent(UsageLimitScope.self, forKey: .scope)
        if let epoch = try? container.decode(Double.self, forKey: .resetsAt) {
            let seconds = epoch > 1_000_000_000_000 ? epoch / 1000 : epoch
            resetsAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
        } else {
            resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt)
        }
    }
}

struct UsageLimitScope: Decodable, Equatable, Sendable {
    var model: UsageName?
    var surface: UsageName?
}

struct UsageName: Decodable, Equatable, Sendable {
    var displayName: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

struct ExtraUsage: Decodable, Equatable, Sendable {
    var isEnabled: Bool
    var utilization: Double?
    var usedCredits: Double?
    var monthlyLimit: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case utilization
        case usedCredits = "used_credits"
        case monthlyLimit = "monthly_limit"
    }

    /// API credits are cents.
    var usedUSD: Double? { usedCredits.map { $0 / 100 } }
    var monthlyUSD: Double? { monthlyLimit.map { $0 / 100 } }
}

struct PerModelUsage: Identifiable, Equatable, Sendable {
    var id: String
    var displayName: String
    var percent: Double
    var resetsAt: String?
    var group: String?
    var live: Bool = false
}

enum ResetClock {
    static func hourMinute(_ iso: String?, timeZone: TimeZone = .current) -> String? {
        guard let iso, let date = parse(iso) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func parse(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
