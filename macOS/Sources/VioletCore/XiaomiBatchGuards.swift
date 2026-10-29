import Foundation

/// Recognizes whole guard templates, never individual control-flow fragments.
/// Unrecognized statements remain in the script and block plan execution.
enum XiaomiBatchGuards {
    struct Result {
        var text: String
        var product: String?
        var maximumAnti: UInt32?
        var dependencies: [FileSnapshot] = []
    }
    static func translate(_ source: String, root: URL) throws -> Result {
        var result = Result(text: source.replacingOccurrences(of: "\r\n", with: "\n"))
        let product = #"(?im)^[\t ]*fastboot(?:\.exe)?(?: %\*)? getvar product 2>&1 \| findstr /r /c:"\^product: \*([A-Za-z0-9_.-]+)" \|\| (?:exit /b 1|echo Missmatching image and device)[\t ]*$"#
        let productMatches = try matches(product, result.text)
        for match in productMatches {
            let name = value(match, 1, result.text)
            if let existing = result.product, existing != name { throw InputError.invalid("脚本机型检查存在冲突。") }
            result.product = name
        }
        result.text = replacing(productMatches, in: result.text)
        // The complete four-part anti sequence is needed: package index,
        // getvar extraction, empty fallback and greater-than failure branch.
        let declaration = #"(?:set CURRENT_ANTI_VER=([0-9]+)|for /f "delims==" %%a in \(%~dp0images[\\/]anti_version\.txt\) do set CURRENT_ANTI_VER=%%a)"#
        let query = #"for /f "tokens=2 delims=: " %%i in \('fastboot(?:\.exe)?(?: %\*)? getvar anti 2\^>\^&1 \^\| findstr /r /c:"anti:"'\) do \(set version=%%i\)"#
        let fallback = #"if \[%version%\] EQU \[\] set version=0"#
        let failure = #"(?:\([\t ]*\n[\t ]*echo [^\n&|<>%]+\n[\t ]*exit /b 1[\t ]*\n[\t ]*\)|\(echo [^\n&|<>%]+ & exit /b 1\))"#
        let anti = "(?im)^[\\t ]*" + declaration + "[\\t ]*\\n[\\t \\n]*" + query + "[\\t ]*\\n[\\t \\n]*" + fallback + "[\\t ]*\\n[\\t \\n]*if %version% GTR %CURRENT_ANTI_VER% " + failure + "[\\t ]*$"
        let antiMatches = try matches(anti, result.text)
        for match in antiMatches {
            let literal = value(match, 1, result.text), index: UInt32
            if literal.isEmpty {
                let file = root.appendingPathComponent("images/anti_version.txt").resolvingSymlinksInPath()
                guard file.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw InputError.invalid("anti_version.txt 指向包目录之外。") }
                let snapshot = try FileSnapshot(file)
                guard snapshot.size <= 64, let value = UInt32(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) else { throw InputError.invalid("anti_version.txt 未包含唯一有效防回滚索引。") }
                try snapshot.validate(); result.dependencies.append(snapshot); index = value
            } else {
                guard let value = UInt32(literal) else { throw InputError.invalid("脚本防回滚索引溢出。") }
                index = value
            }
            if let previous = result.maximumAnti, previous != index { throw InputError.invalid("脚本防回滚检查存在冲突。") }
            result.maximumAnti = index
        }
        result.text = replacing(antiMatches, in: result.text)
        return result
    }
    private static func matches(_ pattern: String, _ text: String) throws -> [NSTextCheckingResult] {
        try NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func value(_ match: NSTextCheckingResult, _ group: Int, _ text: String) -> String {
        guard let range = Range(match.range(at: group), in: text) else { return "" }; return String(text[range])
    }
    private static func replacing(_ matches: [NSTextCheckingResult], in text: String) -> String {
        var result = text
        // Keep line numbers stable for diagnostics in the remaining parser.
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let newlines = result[range].filter { $0 == "\n" }
            result.replaceSubrange(range, with: newlines)
        }
        return result
    }
}
