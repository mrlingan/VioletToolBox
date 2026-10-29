# macOS EDL 后端（开发中，未验收）

按用户 2026-10-28 指示，当前只继续移植，未运行本阶段的编译、测试、USB 扫描、Sahara、Firehose 或实机读写。以下描述源码路径，不代表已证明硬件可用；原有分发包和此前内部构建不含这些新代码。

## 实现与对应源码

通用协议后端采用 [linux-msm/qdl](https://github.com/linux-msm/qdl/tree/d66c6efd72759be5dbb6c7199cd8bd1d9f2674ec)，固定提交 `d66c6efd72759be5dbb6c7199cd8bd1d9f2674ec`。该版本已有 macOS libusb 后端、Sahara 多镜像加载与 Firehose 通用操作。CLI 参数依据该提交的 `src/cli.c`、`src/qdl.c`、`docs/raw-io.md`、`docs/multi-programmer.md`；窄接口依据 `include/qdl.h` 与 `src/firehose.c`。

`NativeTools/VioletEDL.c` 与固定源码直接链接，提供 geometry / read / write / erase / reset 操作，避免使用 CLI 的 32 位地址解析器。物理起始位置和范围使用 64 位字段，传输缓冲为 8 MiB，erase 以 32 位扇区计数分批。总容量仍以 Loader 返回的 getstorageinfo 为依据。

后续新增 `gpt-write`、`bootable` 与 `xml-flash`：GPT 写回 / 切槽使用同一个子进程完成整组主备表、回读核对及可选启动 LUN；XML 使用已预检并规范化的 program / erase / DISK patch。仍未运行构建、测试或设备操作。

Swift 源码分工：`EDL.swift` 管理 USB 列表、Loader SHA-256、Sahara XML、私有副本、结构化几何与分区目标；`EDLActions.swift` 负责确认、执行、GPT、备份、全量输入冻结、Sparse 展开和写入 / 擦除；`EDLView.swift` 提供独立设备与分区入口。`CommandRunner.swift` 新增可选 stderr 行事件，helper 的进度标记驱动界面；普通命令不启用该观察器。

`GPTEditing.swift` 实现独立主备元数据导入、Windows A/B 优先级判断、类型 GUID 交换、属性改写与两份 CRC 更新；`EDLGPTActions.swift` 负责备份、重新确认几何 / 原表、事务与回读。`EDLExpression.swift` 处理有界无符号表达式；`EDLFlashPackage.swift`、`EDLXMLActions.swift`、`EDLXMLFlashView.swift` 接入物理 XML 整包。

## 当前代码流程

1. `qdl list` 只列出 USB 描述符，不发送 Loader。EDL 设备选择独立于 ADB / Fastboot。发送 Loader 前可使用 Sahara chipinfo。
2. 本地 ELF / MBN / BIN、CPIO programmer archive 或 `sahara_config` XML 在 Mac 上分析并计算 SHA-256。XML 使用相对路径，映射 ID 为当前 QDL 支持的 1–127；总量限制 512 MiB。
3. 确认窗口列出序列号、存储类型、LUN、Loader 字节数与摘要。确认后复制并重新核对摘要，再经 Sahara 发送 RAM Loader，读取 UFS / eMMC 几何信息，不包含 UFS provisioning。
4. GPT 使用已有原生解析器检查主备 header / entries CRC、GUID、范围和重叠。元数据按需回读，不将整个 LUN 加载到内存。
5. 分区操作以 LUN + LBA + 扇区数寻址。操作前重新探测容量、读取 GPT，匹配磁盘 GUID、分区 GUID / 名称 / 范围；映射变化会使会话记录失效。
6. 回读使用 staging 文件，长度正确且 inode 未被替换才提交。备份附带几何与目标清单，GPT 导出保存主表、备份表及 JSON。
7. 写入先预检、复制全部镜像；Sparse 先展开为 Raw，末尾按扇区补零，对齐后仍须在分区范围内。写入 / 擦除默认保护 persist 和部分校准、基带数据分区。

保护数据为独立选项，默认关闭，与 Windows 的 EdlSkipDataCheckBox 一致；启用后跳过 userdata / metadata。被保护规则排除的选项会在日志中列出，回读不受保护规则限制。
8. 固定确认的 USB 序列号，同序列号多设备时拒绝。写入 / 擦除的停止等待当前分区命令完成；回读失败 / 取消清理当前半成品，已完成输出保留。协议失败使上下文失效。
9. 操作间释放 USB 句柄、不自动 reset。用户明确重启时才发送 Firehose power reset。

## 新增 GPT / 槽位流程（未验收）

- 独立 gpt_main / gpt_backup 按目标物理扇区与容量解析，要求文件不包含可用分区数据。主备几何、条目、CRC 和 GUID 需要一致，不自动调整磁盘尺寸。
- 切槽对照 Windows `DetectSlotFromPrimaryGpt` / `SwitchPrimaryGptSlot`：boot 对优先，否则按完整 A/B 对投票；跨 LUN 冲突时停止。交换的是类型 GUID，不是分区唯一 GUID；使用 Windows 的 boot / 非 boot 属性值，并同时更新备份表。
- 确认后重新检查物理容量、已读取的原 GPT；将原表及将被覆盖的物理区域保存在用户选择的独立目录。即使当前 GPT 损坏，也能备份原始覆盖区域后恢复已验证的独立元数据。
- 原生子进程先写备份表并回读核对，再写主表并回读核对；全部 LUN 完成后才设置 UFS A=1 / B=2 或 eMMC=0 的启动值。停止等待整组命令完成，传输失败和断电仍可能留下部分更改；不声称设备写入具备真正的原子性。

## 新增 XML 流程（未验收）

- 同目录 rawprogram / patch XML，多选并可包含目录中的 patch*.xml。支持 program、erase、DISK Patch；空 filename 与文件侧 Patch 按 Windows 设备端流程跳过并列明。未知设备命令不会静默忽略。
- `NUM_DISK_SECTORS`、`SECTOR_SIZE_IN_BYTES`、十进制 / 十六进制、括号及加减乘除余数均在有界无符号解析器中处理；支持 Patch 的数值和 `CRC32(start_sector, byte_count)`，检查目标宽度和物理读写范围。未知变量 / 函数拒绝执行，不使用脚本求值。
- 支持 Raw 文件扇区偏移与 XML 指定的截断边界；Sparse 检查块 / 物理扇区对齐和 CRC，保留原始 Sparse 给 QDL 分块，DONT_CARE 不写零，因此分段叠加不会清空先前分段。所有输入在首条写入前先复制，并再次检查已复制的 Sparse 校验和。
- 普通任务按 XML 镜像 / Patch 命令分别执行，当前镜像内的 Sparse chunks 完成后才停止下一任务。GPT-only 将 GPT program 与其物理范围内的 Patch 放在同一元数据命令中。program / erase 保留原序，DISK Patch 在镜像后执行。
- GPT 和 Patch 将覆盖的原始区域在写前备份。成功后如包含 GPT，重新读取并校验。可按 Windows 的 A/B 镜像数选择 UFS 启动 LUN；仅当全部命令成功且用户开启该选项才执行。secdata 需要显式选择许可。
- 当前每个普通 XML 任务重新打开 USB，存在握手延迟；尚未完成全部厂商表达式变体、NAND / NVMe、超过单条 UInt32 扇区计数的自动拆分、完整 VIP 与实时 XML 传输进度。尚无运行证据。

## 尚需对齐

- 小米 / 欧加认证、授权服务输入、Oplus special-read、FastVIP / VIP 和完整厂商 profile。通用后端的认证拒绝作为错误返回，不能显示认证成功。
- 云端 Loader 清单、下载缓存、厂商打包资源与映射；当前选择本地文件。
- OEM、厂商版本查询、动态 Super、全部格式化与出厂流程；已新增的 GPT 恢复、XML、启动 LUN 与 A/B 槽位仍需编译和设备验收。
- 非 Qualcomm VID 的 OEM USB 身份、无序列号设备端口绑定、全部异常恢复，以及原生构建和实机验收。
- 当前 GPT Reader 使用多次窄接口调用，后续需合并会话读取以减少握手延迟。

Windows 来源为 `MainWindow.EdlFlash.cs`、`MainWindow.EdlSession.cs`、`MainWindow.EdlDynamicSuper.cs`、`SaharaProgrammerManifest.cs` 与 `WINDOWS_ACTIONS.json`。缺口完成前，不将通用后端当作全部 Windows EDL 能力交付。

## 构建与依赖打包

恢复编译验收后运行，当前阶段未执行：

```bash
python3 macOS/scripts/build-edl-tools.py --arch arm64
python3 macOS/scripts/build-edl-tools.py --arch x86_64
ARCH=arm64 VIOLET_DIST_DIR="$PWD/macOS/.cache/development-builds/arm64" \
  bash macOS/scripts/build-app.sh --with-platform-tools --with-root-tools --with-edl-tools
```

脚本使用固定 QDL 提交及官方 [libusb 1.0.29](https://github.com/libusb/libusb/releases/tag/v1.0.29) 源码，libusb archive SHA-256 为 `5977fc950f8d1395ccea9bd48c06b3f808fd3c2c961b44b0c2e6e29fc3a70a85`。该值记录下载源码身份，尚未据此运行构建或硬件测试。工具使用 macOS 13 deployment target、Apple SDK / 系统 libxml2，以及随包共享 libusb。当前禁用 QDL 自身 ZIP-container，应用已有固件解包后再交给 EDL；完整原生 ZIP 安装包支持仍需对齐。

输出 `.cache/packaged-edl/<架构>/edl-tools/`、`EDLLicenses/`、`EDLSources/` 和 `EDL_NATIVE_TOOLS.json`。清单记录源码、架构和生成文件散列；保存 QDL / libusb 源码包、helper 源码与构建步骤。`--with-edl-tools` 将这些资料一并加入 App 资源，不依赖用户的 Homebrew dylib 路径。

构建在独立派生源码目录应用两个定向补丁：`qdl-bootable-status.patch` 让 setbootablestoragedrive 的错误回传，不把 NAK 当成功；`qdl-unsigned-sector-count.patch` 使用无符号格式输出 UInt32 扇区数。保留干净的固定 checkout，打包实际修改后的对应源码、补丁及各自散列。补丁尚未应用到构建或验证。

QDL 保留 BSD-3-Clause；libusb 保留 LGPL-2.1 并以共享库提供；VioletEDL helper 使用 GPL-3.0-or-later。最终交付仍需完整应用对应源码、依赖、构建验证、设备记录，以及整个移植范围的验收。
