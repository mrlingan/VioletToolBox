import Foundation
import CryptoKit

extension FlashPlan {
    /// Export a standalone macOS script alongside the images. No device command
    /// runs during export. The caller must explicitly run it with a serial and
    /// --execute; execution validates every input before starting the plan.
    public func exportShell(to destination: URL, control: WorkControl = WorkControl()) throws -> URL {
        try validate()
        guard destination.deletingLastPathComponent().standardizedFileURL == root else { throw InputError.invalid("脚本必须保存到镜像包目录。") }
        let q = Input.remoteQuote
        var checks: [String] = []
        if let product = document.product { checks.append("[ \"$(variable product)\" = \(q(product)) ] || die '机型不符，停止。'") }
        if let anti = document.maximumAnti {
            checks += ["anti=$(variable anti)", "case \"$anti\" in ''|*[!0-9]*) die '防回滚响应无效。';; esac", "[ ${#anti} -le 10 ] && [ \"$((10#$anti))\" -le \(anti) ] || die '防回滚检查未通过。'"]
        }
        var script = #"""
        #!/bin/bash
        set -euo pipefail
        export LC_ALL=C
        die() { printf '%s\n' "$*" >&2; exit 1; }
        serial=${1:-}
        [ -n "$serial" ] && [ "${2:-}" = --execute ] || die '用法：bash flash.command 设备序列号 --execute；会覆盖计划中的分区。'
        root="$(cd -- "$(dirname -- "$0")" && pwd -P)"
        fastboot=${VIOLET_FASTBOOT:-fastboot}
        fb() {
          local file pid watchdog status=0 limit=3600 interrupted=0
          [ "$stop_requested" -eq 0 ] || return 130
          trap 'interrupted=1' INT TERM HUP
          [ "${1:-}" != getvar ] || limit=8
          file=$(mktemp "$work/fb.XXXXXXXX")
          "$fastboot" -s "$serial" "$@" >"$file" 2>&1 & pid=$!
          (
            sleeper=''
            trap '[ -z "$sleeper" ] || kill "$sleeper" 2>/dev/null || :; exit 0' TERM INT HUP
            sleep "$limit" & sleeper=$!; wait "$sleeper" || exit 0; sleeper=''
            kill -TERM "$pid" 2>/dev/null || :
            sleep 2 & sleeper=$!; wait "$sleeper" || exit 0; sleeper=''
            kill -KILL "$pid" 2>/dev/null || :
          ) & watchdog=$!
          while :; do
            if wait "$pid"; then status=0; else status=$?; fi
            kill -0 "$pid" 2>/dev/null || break
          done
          kill "$watchdog" 2>/dev/null || :
          wait "$watchdog" 2>/dev/null || :
          if [ "$limit" -eq 8 ] && [ "$(/usr/bin/stat -f %z "$file")" -gt 4194304 ]; then
            printf '%s\n' 'Fastboot 查询输出超过限制。' >&2; status=1
          else cat "$file"; fi
          rm -f -- "$file"
          [ "$interrupted" -eq 0 ] || return 130
          return "$status"
        }
        variable() {
          local out value
          out=$(fb getvar "$1" 2>&1) || die "无法读取 $1：$out"
          value=$(printf '%s\n' "$out" | /usr/bin/awk -v key="$1:" '
            { sub(/^[ \t]*\(bootloader\)[ \t]*/, ""); sub(/^INFO[ \t]*/, ""); sub(/^[ \t]+/, "");
              if (index($0,key)==1) { v=substr($0,length(key)+1); sub(/^[ \t]+/, "",v); sub(/[ \t\r]+$/, "",v); n++; } }
            END { if(n!=1 || v=="") exit 1; print v; }') || die "设备未返回唯一 $1"
          printf '%s\n' "$value"
        }
        partition() {
          local name=$1 slot=$2 has
          case "$name" in *_a|*_b) printf '%s\n' "$name"; return;; esac
          has=$(variable "has-slot:$name") || exit 1
          case "$has" in
            no) printf '%s\n' "$name";;
            yes) [ -n "$slot" ] || slot=$(variable current-slot) || exit 1
                 case "$slot" in a|b) printf '%s_%s\n' "$name" "$slot";; *) die '当前槽位无效。';; esac;;
            *) die 'has-slot 响应无效。';;
          esac
        }
        capacity() {
          local hex
          hex=$(variable "partition-size:$1") || exit 1
          hex=${hex#0x}; hex=${hex#0X}
          case "$hex" in ''|*[!0-9a-fA-F]*) die '分区容量响应无效。';; esac
          while [ ${#hex} -gt 1 ] && [ "${hex:0:1}" = 0 ]; do hex=${hex:1}; done
          [ ${#hex} -le 16 ] || die '分区容量溢出。'
          if [ ${#hex} -eq 16 ]; then [[ "$hex" < 8000000000000000 ]] || die '分区容量溢出。'; fi
          [ "$((16#$hex))" -gt 0 ] || die '分区容量为空。'
          printf '%s\n' "$((16#$hex))"
        }
        run() {
          local out
          [ "$stop_requested" -eq 0 ] || die '已停止后续步骤。'
          out=$(fb "$@" 2>&1) || { printf '%s\n' "$out" >&2; die '命令失败，停止后续步骤。'; }
          printf '%s\n' "$out"
          if printf '%s\n' "$out" | /usr/bin/grep -Eq '^[[:space:]]*(FAILED|fastboot: error:)'; then die '设备返回失败，停止后续步骤。'; fi
        }
        userspace() { [ "$(variable is-userspace)" = yes ] || die '此操作需要 FastbootD。'; }
        wait_mode() {
          local wanted=$1 deadline mode matches=0
          deadline=$(( $(date +%s) + 120 ))
          while [ "$(date +%s)" -lt "$deadline" ]; do
            mode=$(variable is-userspace) || mode=unknown
            if [ "$mode" = "$wanted" ]; then matches=$((matches+1)); else matches=0; fi
            [ "$matches" -lt 2 ] || return 0
            sleep 1
          done
          die '等待原序列号切换 Fastboot 模式超时。'
        }
        delete_optional() {
          local out status=0
          out=$(fb delete-logical-partition "$1" 2>&1) || status=$?
          if [ "$status" -ne 0 ] || printf '%s\n' "$out" | /usr/bin/grep -Eq '^[[:space:]]*(FAILED|fastboot: error:)'; then
            if printf '%s\n' "$out" | /usr/bin/grep -Eiq "partition not found|partition does not exist|no such partition|unknown partition|partition doesn't exist"; then
              printf '%s\n' "逻辑分区已不存在：$1"; return 0
            fi
            printf '%s\n' "$out" >&2; die '删除逻辑分区失败。'
          fi
          printf '%s\n' "$out"
        }
        cleanup_cow() {
          local out names
          userspace
          out=$(fb getvar all 2>&1) || die '读取 COW 目录失败。'
          names=$(printf '%s\n' "$out" | /usr/bin/awk '
            /partition-size:/ { s=$0; sub(/^.*partition-size:/,"",s); sub(/:.*/,"",s); gsub(/^[ \t]+|[ \t]+$/,"",s);
              if(s !~ /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/ || ++n>16384) { bad=1; exit 1; }
              if(tolower(s) ~ /cow/) print s; }
            END { if(n<1 || bad) exit 1; }') || die 'COW 名称或设备分区目录无效。'
          if [ -n "$names" ]; then
            printf '%s\n' "$names" | while IFS= read -r name; do
              [ "$(variable "is-logical:$name")" = yes ] || die 'COW 候选不是逻辑分区。'
              delete_optional "$name"
            done
          fi
        }
        work=$(mktemp -d "${TMPDIR:-/tmp}/violet-flash.XXXXXXXX")
        stop_requested=0
        trap 'rm -rf -- "$work"' EXIT
        trap 'stop_requested=1' INT TERM HUP
        plan_slot=''
        """# + "\n" + checks.joined(separator: "\n") + "\n"
        var images: [String: (index: Int, size: UInt64, digest: String)] = [:]
        var logicalSizes: [String: UInt64] = [:], initialCapacity: Set<Int> = [], expectedSizes: [Int: UInt64] = [:], autoResize: [Int: UInt64] = [:], managed: Set<Int> = []
        var changedEnvironment = false
        let knownSlotless: Set<String> = ["super","userdata","metadata","persist","misc","frp","ocdt","crclist","sparsecrclist"]
        for (index, step) in document.steps.enumerated() {
            try control.check()
            if step.operation == .setActive { script += "plan_slot=\(q(step.target))\n" }
            if step.operation == .reboot && ["bootloader","fastboot"].contains(step.target) { changedEnvironment = true }
            if step.operation == .createLogical || step.operation == .resizeLogical { logicalSizes[step.target] = step.size! }
            if step.operation == .deleteLogical { logicalSizes.removeValue(forKey: step.target) }
            guard step.operation == .flash || step.operation == .erase else { continue }
            let isManaged = logicalSizes[step.target] != nil
            let exact = step.exactTarget == true || step.target.hasSuffix("_a") || step.target.hasSuffix("_b") || knownSlotless.contains(step.target) || isManaged
            guard !changedEnvironment || exact else { throw InputError.invalid("跨模式脚本中的 \(step.target) 需声明明确槽位或精确分区目标。") }
            script += exact ? "target\(index)=\(q(step.target))\n" : "target\(index)=$(partition \(q(step.target)) \"$plan_slot\")\n"
            if !changedEnvironment && !isManaged {
                initialCapacity.insert(index)
                script += "capacity\(index)=$(capacity \"$target\(index)\")\n"
            }
            if isManaged { managed.insert(index) }
            if let image = step.image {
                var metadata = images[image]
                if metadata == nil {
                    let url = try imageURL(image), partition = try DevicePartition(name: step.target, size: UInt64(Int64.max))
                    let input = try PartitionImageInput.open(url, for: partition, control: control)
                    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                    var hash = SHA256()
                    while true {
                        try control.check(); let bytes = try handle.read(upToCount: 1024 * 1024) ?? Data()
                        if bytes.isEmpty { break }; hash.update(data: bytes)
                    }
                    try input.validate()
                    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                    metadata = (index, input.expandedSize, digest); images[image] = metadata
                    script += "cp \"$root/\"\(q(image)) \"$work/\(index).img\"\nactual=$(/usr/bin/shasum -a 256 \"$work/\(index).img\")\n[ \"${actual%% *}\" = \(q(digest)) ] || die \(q("镜像摘要变化：" + image))\n"
                }
                if logicalSizes[step.target] == 0 {
                    guard metadata!.size <= UInt64(Int64.max) - 4095 else { throw InputError.invalid("逻辑分区大小溢出。") }
                    let aligned = (metadata!.size + 4095) / 4096 * 4096
                    logicalSizes[step.target] = aligned; autoResize[index] = aligned
                }
                if initialCapacity.contains(index) {
                    script += "[ \(metadata!.size) -le \"$capacity\(index)\" ] || die \(q("镜像大于目标容量：" + step.target))\n"
                }
                if let declared = logicalSizes[step.target] {
                    guard metadata!.size <= declared else { throw InputError.invalid("\(step.target) 的计划容量小于镜像展开大小。") }
                }
            }
            if let declared = logicalSizes[step.target], declared > 0 { expectedSizes[index] = declared }
            if step.operation == .flash && step.target == "super" { changedEnvironment = true; logicalSizes = [:] }
        }
        script += checks.joined(separator: "\n") + "\n"
        for index in initialCapacity.sorted() {
            script += "[ \"$(capacity \"$target\(index)\")\" = \"$capacity\(index)\" ] || die '容量变化，停止。'\n"
        }
        for (index, step) in document.steps.enumerated() {
            if step.operation == .requireFastbootd { script += "userspace\n"; continue }
            if step.operation == .cleanupCow { script += "cleanup_cow\n"; continue }
            if [.createLogical,.deleteLogical,.resizeLogical,.snapshotCancel].contains(step.operation) || managed.contains(index) { script += "userspace\n" }
            if managed.contains(index) { script += "[ \"$(variable \"is-logical:$target\(index)\")\" = yes ] || die '目标不是逻辑分区。'\n" }
            if let resize = autoResize[index] { script += "run resize-logical-partition \"$target\(index)\" \(resize)\n" }
            if step.operation == .flash || step.operation == .erase {
                script += "actual_capacity=$(capacity \"$target\(index)\")\n"
                if initialCapacity.contains(index) { script += "[ \"$actual_capacity\" = \"$capacity\(index)\" ] || die '分区容量与审阅时不符。'\n" }
                if let expected = expectedSizes[index] { script += "[ \"$actual_capacity\" = \(expected) ] || die '逻辑分区容量与计划不符。'\n" }
                if let image = step.image, let metadata = images[image] { script += "[ \(metadata.size) -le \"$actual_capacity\" ] || die '镜像大于分区容量。'\n" }
            }
            let args: [String]
            switch step.operation {
            case .flash:
                guard let image = step.image, let input = images[image] else { throw InputError.invalid("缺少镜像信息。") }
                args = step.options.map(q) + ["flash", "\"$target\(index)\"", "\"$work/\(input.index).img\""]
            case .erase: args = ["erase", "\"$target\(index)\""]
            default: args = try step.arguments().map(q)
            }
            script += "printf '%s\\n' \(q("\(index+1)/\(document.steps.count) " + step.summary))\n"
            if step.operation == .deleteLogical && step.allowMissing == true { script += "delete_optional \(q(step.target))\n" }
            else { script += "run " + args.joined(separator: " ") + "\n" }
            if step.operation == .reboot && ["bootloader","fastboot"].contains(step.target) {
                script += "wait_mode \(step.target == "fastboot" ? "yes" : "no")\n"
                if let product = document.product { script += "[ \"$(variable product)\" = \(q(product)) ] || die '模式切换后的机型不符。'\n" }
            }
        }
        script += "printf '%s\\n' '所有命令已成功返回，请检查设备状态。'\n"
        try control.check(); try validate()
        let output = try AtomicOutput(destination); try output.handle.write(contentsOf: Data(script.utf8))
        return try output.commit()
    }
}
