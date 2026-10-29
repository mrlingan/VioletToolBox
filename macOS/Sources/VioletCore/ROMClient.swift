import Foundation

public struct ROMSelection: Codable, Sendable {
    public var packageType: String
    public var brand: String
    public var series: String
    public var device: String
    public var version: String
    public init(packageType: String = "full", brand: String = "OnePlus", series: String = "", device: String = "", version: String = "") {
        self.packageType = packageType; self.brand = brand; self.series = series; self.device = device; self.version = version
    }
}

public struct ROMLink: Identifiable, Sendable, Hashable {
    public var id: String { url.absoluteString }
    public let label: String
    public let url: URL
}

public struct ROMLinks: Sendable {
    public let items: [ROMLink]
    public let headers: [String: String]
}

public struct ROMClient: Sendable {
    public let baseURL: URL
    public init(baseURL: URL = URL(string: "https://violettool.top/rom-api")!) { self.baseURL = baseURL }

    public func list(_ kind: String, selection: ROMSelection) async throws -> [String] {
        guard ["series", "devices", "versions"].contains(kind) else { throw InputError.invalid("未知 ROM 查询类型。") }
        _ = try HTTPClient.httpURL(baseURL.absoluteString)
        var components = URLComponents(url: baseURL.appendingPathComponent(kind), resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "packageType", value: selection.packageType), URLQueryItem(name: "brand", value: selection.brand)]
        if kind != "series" { query.append(URLQueryItem(name: "series", value: selection.series)) }
        if kind == "versions" { query.append(URLQueryItem(name: "device", value: selection.device)) }
        components.queryItems = query
        guard let url = components.url else { throw InputError.invalid("ROM 查询地址无效。") }
        let data = try await HTTPClient.data(for: URLRequest(url: url))
        struct Strings: Decodable { let items: [String] }
        struct Version: Decodable { let name: String }
        struct Versions: Decodable { let items: [Version] }
        let values = kind == "versions" ? try JSONDecoder().decode(Versions.self, from: data).items.map(\.name) : try JSONDecoder().decode(Strings.self, from: data).items
        var seen: Set<String> = []
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public func links(selection: ROMSelection) async throws -> ROMLinks {
        _ = try HTTPClient.httpURL(baseURL.absoluteString)
        var request = URLRequest(url: baseURL.appendingPathComponent("download-link"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(selection)
        struct Option: Decodable { let label: String?; let url: String; let isPrimary: Bool? }
        struct Response: Decodable { let links: [String]?; let linkOptions: [Option]?; let requestHeaders: [String: String]? }
        let result = try JSONDecoder().decode(Response.self, from: await HTTPClient.data(for: request))
        var items: [ROMLink] = [], seen: Set<URL> = []
        for option in (result.linkOptions ?? []).sorted(by: { ($0.isPrimary ?? false) && !($1.isPrimary ?? false) }) {
            if let url = try? HTTPClient.httpURL(option.url), seen.insert(url).inserted { items.append(ROMLink(label: option.label ?? "下载地址", url: url)) }
        }
        for link in result.links ?? [] {
            if let url = try? HTTPClient.httpURL(link), seen.insert(url).inserted { items.append(ROMLink(label: "下载地址 \(items.count + 1)", url: url)) }
        }
        guard !items.isEmpty else { throw InputError.invalid("服务没有返回有效的下载地址。") }
        return ROMLinks(items: items, headers: result.requestHeaders ?? [:])
    }
}
