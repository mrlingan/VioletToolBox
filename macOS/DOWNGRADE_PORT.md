# 降级助手与联想查包源码移植

2026-10-28：按用户最新要求，仅继续源码实现。本阶段未编译、未运行新增测试、未访问查询服务，也未连接或写入手机。不能将以下代码范围视为设备验收通过。

## 联想

对应 Windows `RomDownload.cs`：`QueryLenovoMachineAsync`、`QueryLenovoPackageAsync`、`QueryLenovoPackageByInputAsync` 和预设机型入口。

- `LenovoROMClient.swift` 使用相同的联想 `getMachineSequenceInfo` GET 与 `getPadFlashingMachine` JSON POST；支持 8 位 SN、10 位 MTM、Y700 二至五代固定预设。
- 响应状态同时接受数字 / 数字字符串；包字段兼容 snake_case / camelCase。优先匹配逗号分隔的精确 MTM，否则显示第一个服务端候选并明确提醒核对，沿用 Windows 的候选回退。
- 展示机器、销售、产品、版本、平台、刷机方式、链接与 Windows 内置的公开解压密码；复制结果 / 链接或交给现有下载续传。无链接时不能准备下载。
- SN 只用于查询，不写入共享日志；页面提示提交给联想服务。新查询先清除旧结果，失败不继续展示旧下载项。

## ColorOS / 一加降级助手

对应 Windows `DowngradeTool.cs` 与 `MainWindow.ColorOSAssistant.cs`。新增 `DowngradeAssistant.swift`、`DowngradeFile.swift`、`DowngradeActions.swift`、`DowngradeView.swift`。

- 入口分为 APK 获取 / 选择、查询、版本选择、下载与本地包选择、推送 / 提交。APK 下载入口使用上游相同的浏览器链接；源码仓库没有内置 `OTA_113.apk`，目前使用手机已安装版本或用户选择的 APK，尚未完成随包资源准备。
- 固定所选 ADB 序列号，读取 `ro.serialno`。选择 APK 时先在私有目录复制，安装返回 Success 后检查 `com.color.otaassistant`；发送上游相同启动广播。
- 使用 `adb forward tcp:0 tcp:9527` 分配本应用的端口；清理仅移除这个端口。分配和清理使用短时独立任务，收到停止仍能取得并移除已分配端口，避免删掉其他应用的固定转发。
- 实现 `GhostPID` 24-byte 大端帧、有界 4 MiB JSON、分段收发、超时、断开和按 100 ms 轮询的停止检查；P-256 ECDH / ECDSA、SHA256(Base64(secret))、ASCII 派生 AES-256-CTR 与 Windows 相同。CTR 由 CommonCrypto 实现。
- 查询协议采用原上游 RSA 公钥、OAEP-SHA1 包装随机 AES key、AES-GCM 加密 DUID、`cipherInfo` / `deviceId` 请求头和 `query-v3` 字段；DUID、签名元数据、密钥和下载 URL 不写共享日志。
- 将结果绑定到设备身份、项目号、当前版本与 DUID，换设备清空结果；安装前重新读取设备并查询授权。以版本、大小、MD5 唯一匹配包，允许下载地址时效变化；推送较久时重新取得签名数据。发送安装指令的同一加密连接再次核对设备信息。
- 包大小与 MD5 缺失 / 错误则停止。流式复制本地包并核对 MD5，全部通过后才推送稳定副本；手机端再次核对大小和 MD5，将唯一命名 `.part` 改为正式路径。失败仅清理本任务片段，已完成包保留。
- 沿用 deviceidle 白名单、set-inactive 和 `cmd 40006` 安装参数。确认窗口列出具体手机、当前 / 目标版本、文件、摘要、手机路径与上游适用范围。`verifyResult=0` 只表示助手接受请求，界面 / 日志仍指引用户在手机本地安装，不报告系统已经降级。
- 停止在当前设备命令边界生效。安装请求开始发送后等待助手回应或超时；停止不撤回已发出的请求，超时 / 断开明确要求核对手机状态，不自动重发安装命令。

## 尚未完成

- 上述 Swift / C 新代码尚未编译；加密互操作、字节向量、分片帧 / 超时 / 取消、状态切换、下载恢复与真机全部未验收。
- 随后已接入远程 ZIP metadata 详情，用户选中版本后点击解析；字段与 Windows 机型表已转写，尚未编译或运行，见 `REMOTE_FIRMWARE.md`。上游自动选择后的读取时机与全部异常提示仍需运行对齐。
- 助手 APK 的随包资源、安装版本兼容性、厂商服务当前可用性和授权条件待核对。不能以 Bootloader 解锁 / 已 Root 推断满足降级或熔断条件。
- 本阶段未实现新的多线程下载器；复用已有单连接续传。现有 dist / QA 包没有包含本阶段代码。
