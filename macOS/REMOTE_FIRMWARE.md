# 远程 OTA / ZIP / Payload 移植

2026-10-28，继续源码移植，暂停编译和运行验证。本阶段没有运行 HTTP 模拟服务、固件样本、界面或设备命令。仅获取固定版本 ZSTD 的官方源码用于依赖准备，未据此宣称功能验收通过。

## 对应的 Windows 能力

- `Payload_Dumper_C#/Core/RandomAccessReaders.cs` 的 HTTP Range / 子范围读取。
- `ZipStoredEntryLocator.cs` 的 ZIP / ZIP64 中央目录、Stored payload 与普通文件导出。
- `PayloadProcessing.cs` 的本地 / 在线分区提取、操作摘要与 ZSTD 解码，以及 Android metadata 文本读取。
- `MainWindow.Payload.cs` 的远程输入、无 Payload ZIP 文件模式和版本字段 / 机型名称。
- `RomDownload.cs` 的在线分区入口、资源请求头；降级助手的云端版本详情。

`WINDOWS_ACTIONS.json` 仍是当前 Windows XAML 事件入口清单；本阶段没有改变 Windows 文件，不重新生成它，也不把事件数当成功能数量。

## 新增代码

- `HTTPRangeSource.swift`：公开的随机读取协议、本地快照读取和 HTTP Range 源。0–0 GET 取得大小；后续每次最多 4 MiB，调用端单次最多 64 MiB。收到 200 / 错误范围 / 截断 / 多余数据 / 传输压缩均停止；不自动下载完整 ROM。大小、强 ETag 或修改时间变化停止；弱 ETag 只比较、不用于 If-Range。缺少文件标识仍可读取，但页面提醒限制，并复核目录 / manifest。
- Range 网络失败 / 超时和 429 / 502 / 503 / 504 有界重试三次，保留停止检查。重定向检查 HTTP(S) 与凭据，拒绝 HTTPS 降级；跨站清除私有自定义头、Authorization 和 Cookie，保留 Range 及公开 Referer / User-Agent。
- `RangeZIPArchive.swift`：EOCD、ZIP64 Locator / EOCD、各条目 ZIP64 extra、有界目录和文件范围检查；本地头方法 / 标志 / 原始名称复核。拒绝分卷、加密文件、符号链接、路径穿越、重复 / 大小写冲突路径。Stored / Deflate 流式导出，核对声明长度与 CRC32，独占 staging 文件提交。Deflate 使用系统 libz 的原始流接口；输入 / 输出缓冲各 1 MiB。
- `RemoteFirmwareArchive.swift`：识别 ZIP 或原始 Payload。唯一 Stored `payload.bin` 提供子范围源；压缩 Payload 显示原因，并可在 ZIP 文件模式先提取完整 payload.bin，再本地分析。支持没有 Payload 的普通 ZIP；有 Payload 的 ZIP 也可以切换文件模式。
- 本地与远程共享 Payload manifest 解析和 `PayloadImageWriter`；操作数据及最终镜像按已有 SHA-256 字段检查，独占输出避免覆盖，失败 / 停止清理当前半成品。新增 `src_sha256_hash` 标记，拒绝把需要旧镜像的差分误当完整数据。当前 Windows `ApplyOperationAsync` 同样明确拒绝这些 SOURCE_* / 源摘要分支。
- 新的共享写入代码替换了此前本地提取写入循环；此前通过的本地测试不证明这次重构正确，需要恢复验收后回归。
- `FirmwareVersionDetails`：读取 `META-INF/com/android/metadata`，Stored / Deflate 均支持，4 MiB 上限；UTF-8 / Latin-1、OEM 版本字段及标准 OTA 字段后备。`WindowsDeviceNames.swift` 从当前 Windows 表转写了 77 条机型显示名称，仅作显示，不是兼容认证。
- `RemoteFirmwareActions.swift` / `RemoteFirmwareView.swift`：远程地址输入、目录 / 分区筛选、多选、导出、版本信息、原始 metadata 保存和诊断；本地 OTA 也有独立的 metadata 读取 / 保存入口，无需先解压整个 Payload。从 ROM 资源入口携带服务端请求头打开结果。手动编辑地址清除旧请求头。签名 URL / 请求头不进入正常共享日志。
- 降级助手新增“解析云端版本详情”入口；结果绑定当前查询及包 ID，不影响实际安装授权校验。版本详情在用户点击后读取。

## ZSTD

`Sources/CZstdDecoder` 随源码提供 facebook/zstd **1.5.7** 的解码子集，固定提交 `f8745da6ff1ad1e7bab384bd1f9d742439278e99`。官方源码归档 SHA-256：

```
4b0bd1f0cfb25e61b9103c35f27395530ff5b4c0d2513a00fd745849e85ea52c
```

`UPSTREAM.json` 记录每个原样复制文件的散列。采用 BSD-3-Clause 许可选项；SwiftPM 接入纯 C 解码，禁用旧格式和汇编，不依赖 Homebrew 或私有系统 ZSTD。窄接口检查完整帧边界、256 MiB 输入 / 输出 / window 上限，拒绝外部字典，接入 Payload type 14。ARM / Intel 的编译和解码行为均未验证。未来打包脚本已加入许可证及来源清单复制，未执行打包。

## 保留的差距

- 尚未运行任何新增验证；Range 兼容性、ZIP64 边界、CRC、Deflate / ZSTD、错误重试与停止、Swift 并发 / C 链接、本地提取回归均无本阶段运行证据。
- 当前单操作输入 / 目标仍限制 256 MiB；更大操作的流式解码与上游内存边界完整对齐待做。远程读取暂为顺序连接，无 Windows 的块缓存 / 多 worker；停止的当前分区重新提取，不实现分区内部断点续传。
- 原始 payload.bin 无 ZIP metadata，版本详情不能凭空补齐。未知压缩、外部 ZSTD 字典与增量 SOURCE_* 明确不能提取，不显示成功。
- 魅族下载入口 / 资源域名自动补公开 Referer；全部入口跳转变体、C16 downloadCheck 动态解析与线路回退仍待对齐。通用 Range 不把网页当 ROM。
- 欧加全量 / 售后、EDL 版本 / 云 Loader、ARB 远程分析还需接入这层读取能力；此阶段不声称这些厂商流程全部完成。
- 现有 dist / QA 和内部检查包不含本阶段源码。仍未满足最终交付条件。
