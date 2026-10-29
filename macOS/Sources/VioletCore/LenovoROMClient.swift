import Foundation

public struct LenovoMachine: Sendable {
    public let serial: String
    public let mtm: String
    public let name: String
    public let productDate: String
    public let scanDate: String
    public let packingLot: String
    public let saleOrder: String
    public let saleArea: String
    public let series: String
}

public struct LenovoFirmware: Sendable {
    public let productName: String
    public let marketName: String
    public let version: String
    public let serverFilename: String
    public let model: String
    public let platform: String
    public let flashingMethod: String
    public let downloadURL: URL?
    public let mtm: String
    public let exactMTMMatch: Bool
}

public struct LenovoROMResult: Sendable {
    public let input: String
    public let mtm: String
    public let machine: LenovoMachine?
    public let firmware: LenovoFirmware?
    public let message: String
    public var summary: String {
        func text(_ value: String) -> String { value.isEmpty ? "-" : value }
        var lines = ["输入类型：\(input.count == 8 ? "SN" : "MTM")", "解析 MTM：\(text(mtm))"]
        if let m = machine {
            lines += ["机器名称：\(text(m.name))", "序列号：\(text(m.serial))", "销售区域：\(text(m.saleArea))", "产品系列：\(text(m.series))", "生产日期：\(text(m.productDate))", "扫描日期：\(text(m.scanDate))", "装箱批次：\(text(m.packingLot))", "销售订单：\(text(m.saleOrder))"]
        }
        if let p = firmware {
            lines += ["产品名称：\(text(p.productName))", "市场名称：\(text(p.marketName))", "产品型号：\(text(p.model))", "最新版本：\(text(p.version))", "服务端文件名：\(text(p.serverFilename))", "平台：\(text(p.platform))", "刷机方式：\(text(p.flashingMethod))", "下载链接：\(p.downloadURL?.absoluteString ?? "-")", "解压密码：\(LenovoROMClient.archivePassword)"]
            if !p.exactMTMMatch { lines.append("服务端未返回精确 MTM 匹配，显示其首个候选包，请核对产品型号。") }
        }
        if !message.isEmpty { lines.append(message) }
        return lines.joined(separator: "\n")
    }
}

public struct LenovoROMClient: Sendable {
    public struct Preset: Identifiable, Sendable {
        public let name: String
        public let mtm: String
        public var id: String { mtm }
    }
    public static let presets = [Preset(name: "Y700二代", mtm: "ZACW0006CN"), Preset(name: "Y700三代", mtm: "ZAEF0029CN"), Preset(name: "Y700四代", mtm: "ZAG40005CN"), Preset(name: "Y700五代", mtm: "ZAH20097CN")]
    // Public archive password shipped by the Windows client, not an account secret.
    public static let archivePassword = "FC(fv:SknR"
    public let baseURL: URL
    public init(baseURL: URL = URL(string: "https://ptstpd.lenovo.com.cn/home/ConfigurationQuery")!) { self.baseURL = baseURL }

    public static func normalizedInput(_ value: String) throws -> String {
        let input = clean(value).uppercased()
        guard [8,10].contains(input.utf8.count), input.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else { throw InputError.invalid("请输入 8 位字母 / 数字 SN 或 10 位 MTM。") }
        return input
    }
    public func query(_ value: String) async throws -> LenovoROMResult {
        let input = try Self.normalizedInput(value)
        _ = try HTTPClient.httpURL(baseURL.absoluteString)
        var machine: LenovoMachine?
        var mtm = input
        if input.count == 8 {
            var components = URLComponents(url: baseURL.appendingPathComponent("getMachineSequenceInfo"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "MachineNo", value: input)]
            guard let url = components.url else { throw InputError.invalid("联想查询地址无效。") }
            let root = try await object(URLRequest(url: url))
            guard number(root["StatusCode"]) == 200, let data = root["data"] as? [String: Any] else { return LenovoROMResult(input: input, mtm: "", machine: nil, firmware: nil, message: "未找到机器信息。") }
            machine = LenovoMachine(serial: string(data,"SN"), mtm: string(data,"MTM"), name: string(data,"MachineName"), productDate: string(data,"ProductDate"), scanDate: string(data,"ScanDate"), packingLot: string(data,"PackingLotNo"), saleOrder: string(data,"SaleOrder"), saleArea: string(data,"SaleArea"), series: string(data,"ProductSeries"))
            mtm = machine!.mtm.uppercased()
            guard (try? Self.normalizedInput(mtm))?.count == 10 else { return LenovoROMResult(input: input, mtm: mtm, machine: machine, firmware: nil, message: "已找到机器信息，但未返回有效 MTM。") }
        }
        try Task.checkCancellation()
        var request = URLRequest(url: baseURL.appendingPathComponent("getPadFlashingMachine"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["mtm":mtm])
        let root = try await object(request)
        guard number(root["code"]) == 200, let list = root["data"] as? [[String: Any]], !list.isEmpty else { return LenovoROMResult(input: input, mtm: mtm, machine: machine, firmware: nil, message: "未找到刷机包。") }
        let match = list.first { string($0,"mtm","MTM").uppercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.contains(mtm) }
        let item = match ?? list[0]
        let firmware = LenovoFirmware(productName: string(item,"product_name","productName"), marketName: string(item,"market_name","marketName"), version: string(item,"latest_version","latestVersion"), serverFilename: string(item,"server_version_name","serverVersionName"), model: string(item,"product_model","productModel"), platform: string(item,"platform"), flashingMethod: string(item,"flashing_machine_method","flashingMachineMethod"), downloadURL: try? HTTPClient.httpURL(string(item,"download_url","downloadUrl")), mtm: match == nil ? string(item,"mtm","MTM") : mtm, exactMTMMatch: match != nil)
        return LenovoROMResult(input: input, mtm: mtm, machine: machine, firmware: firmware, message: firmware.downloadURL == nil ? "服务端未返回有效 HTTP / HTTPS 下载地址。" : "")
    }
    private func object(_ request: URLRequest) async throws -> [String: Any] {
        let data = try await HTTPClient.data(for: request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw InputError.invalid("联想查询返回格式无效。") }
        return object
    }
    private func number(_ value: Any?) -> Int? {
        if let value = value as? String { return Int(value) }
        return (value as? NSNumber)?.intValue
    }
    private func string(_ object: [String: Any], _ keys: String...) -> String {
        for key in keys { if let raw = object[key] as? String { let value = Self.clean(raw); if !value.isEmpty { return value } } }
        return ""
    }
    private static func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "`\"' ")).trimmingCharacters(in: .whitespacesAndNewlines) }
}
