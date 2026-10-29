import Foundation

public struct RemoteFile: Identifiable, Sendable {
    public enum Kind: String, Sendable { case directory = "d", file = "f", link = "l", other = "o" }
    public let path: String
    public let name: String
    public let kind: Kind
    public let size: UInt64
    public var id: String { path }
}

public enum RemoteFiles {
    public static func path(_ value: String, allowRoot: Bool = true) throws -> String {
        guard value.hasPrefix("/"), value.utf8.count <= 4096,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw InputError.invalid("设备路径必须为不含控制字符的绝对路径。") }
        let parts = value.split(separator: "/")
        guard !parts.contains(".."), !parts.contains(".") else { throw InputError.invalid("设备路径不能包含 . 或 ..。") }
        let path = "/" + parts.joined(separator: "/")
        guard allowRoot || path != "/" else { throw InputError.invalid("此操作不能以设备根目录为目标。") }
        return path
    }
    public static func child(_ name: String, in directory: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), name.utf8.count <= 255 else { throw InputError.invalid("名称不能为空，不能包含斜杠或超过 255 bytes。") }
        return try path(path(directory) + "/" + name, allowRoot: false)
    }
    public static func list(_ directory: String) throws -> String {
        let directory = try path(directory)
        return """
        dir=\(Input.remoteQuote(directory))
        [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || exit 73
        printf 'VIOLET_FILES_V1\\n'
        count=0
        for item in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
          [ -e "$item" ] || [ -L "$item" ] || continue
          count=$((count+1)); [ "$count" -le 10000 ] || exit 74
          kind=o; size=0
          if [ -L "$item" ]; then kind=l
          elif [ -d "$item" ]; then kind=d
          elif [ -f "$item" ]; then kind=f; size=$(stat -c %s "$item") || exit 75
          fi
          printf '%s\\t%s\\t' "$kind" "$size"
          printf '%s' "${item##*/}" | base64 | tr -d '\\r\\n'; printf '\\n'
        done
        """
    }
    public static func parse(_ response: String, directory: String) throws -> [RemoteFile] {
        guard response.utf8.count <= 16 * 1024 * 1024 else { throw InputError.invalid("文件列表过大。") }
        let lines = response.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.first == "VIOLET_FILES_V1", lines.count <= 10001 else { throw InputError.invalid("设备目录不可读或文件列表无效。") }
        var files: [RemoteFile] = [], names: Set<String> = []
        for line in lines.dropFirst() {
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 3, let kind = RemoteFile.Kind(rawValue: fields[0]), let size = UInt64(fields[1]),
                  let data = Data(base64Encoded: fields[2]), let name = String(data: data, encoding: .utf8), names.insert(name).inserted else { throw InputError.invalid("文件列表字段无效或重名。") }
            files.append(RemoteFile(path: try child(name, in: directory), name: name, kind: kind, size: size))
        }
        return files.sorted { lhs, rhs in
            if (lhs.kind == .directory) != (rhs.kind == .directory) { return lhs.kind == .directory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
    public static func create(name: String, directory: String, folder: Bool) throws -> String {
        let target = try child(name, in: directory)
        return folder ? "mkdir -- " + Input.remoteQuote(target) : "set -C; : > " + Input.remoteQuote(target)
    }
    public static func rename(source: String, name: String) throws -> String {
        let source = try path(source, allowRoot: false)
        let directory = (source as NSString).deletingLastPathComponent
        let target = try child(name, in: directory)
        guard source != target else { throw InputError.invalid("新旧名称相同。") }
        return "[ ! -e \(Input.remoteQuote(target)) ] && [ ! -L \(Input.remoteQuote(target)) ] && mv -- \(Input.remoteQuote(source)) \(Input.remoteQuote(target))"
    }
    public static func delete(_ paths: [String]) throws -> String {
        guard !paths.isEmpty, paths.count <= 1000 else { throw InputError.invalid("请选择 1–1000 个文件。") }
        return "rm -rf -- " + (try paths.map { Input.remoteQuote(try path($0, allowRoot: false)) }).joined(separator: " ")
    }
}
