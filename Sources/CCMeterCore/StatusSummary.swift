import Foundation

/// The subset of an Atlassian Statuspage `summary.json` we use. Lenient: absent `components`
/// or `incidents` decode to empty arrays, and unknown status/impact strings are just carried
/// as-is (the evaluator maps unknown values to the safe bucket).
public struct StatusSummary: Decodable, Equatable {
    public struct Indicator: Decodable, Equatable {
        public let indicator: String
        public let description: String?
    }
    public struct Component: Decodable, Equatable {
        public let name: String
        public let status: String
    }
    public struct Incident: Decodable, Equatable {
        public let name: String
        public let impact: String
        public let status: String
        public let shortlink: String?
    }

    public let status: Indicator
    public let components: [Component]
    public let incidents: [Incident]

    private enum CodingKeys: String, CodingKey { case status, components, incidents }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(Indicator.self, forKey: .status)
        components = try c.decodeIfPresent([Component].self, forKey: .components) ?? []
        incidents = try c.decodeIfPresent([Incident].self, forKey: .incidents) ?? []
    }
}
