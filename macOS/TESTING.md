# macOS 验证记录

远程固件阶段新增 HTTP Range、ZIP / ZIP64 / Deflate / CRC、Payload 在线提取、metadata 版本详情、ROM 入口，以及固定源码 ZSTD type 14。未执行编译、测试或线上固件读取。仅下载官方 ZSTD 源码、记录来源散列并转写 Windows 机型表；这不是运行验证。本地 Payload 解析 / 写入改为共享实现，旧通过记录也不能证明重构后的本地提取正确。恢复验证时需回归原本地样本，并新增服务端忽略 Range / 错误范围 / 身份变化 / 重定向 / 429、ZIP64 / 损坏目录 / CRC / 安全路径、Deflate 与 ZSTD、大操作、取消和半成品处理，见 `REMOTE_FIRMWARE.md`。

新增联想 SN / MTM / Y700 查询、降级助手加密协议 / HTTP 查询、APK 安装编排、流式 MD5、稳定副本推送与安装请求源码。按当前暂停安排，未执行编译、网络查询、协议向量、模拟服务或真机操作；现有测试数量不覆盖这些分支。后续应核对 Windows 协议互操作、连接分片 / 断开 / 超时 / 取消、端口清理、设备与版本绑定、摘要失败和安装请求不可重试边界，详见 `DOWNGRADE_PORT.md`。

2026-10-28 用户要求暂不需要验证测试。已暂停后续测试运行、编译与界面验收，继续功能移植；本文既有结果只对应当时实现。之后加入的 RawProgram 完整镜像导入、分区表镜像匹配、计划步骤调整尚未验收。后续可用设备为一加 13，已解锁 Bootloader、有 Root，尚未连接开展实机验收。

随后新增的跨模式编排、动态分区、Xiaomi guard 模板、欧加四模式计划与 ARB 解析同样未编译 / 运行。旧有测试中的跨模式拒绝断言需要在恢复验证时更新；本文下面的通过数量不代表覆盖当前全部源码。

EDL 阶段仅取得固定 QDL 源码和 libusb 源码包，编写窄接口、Swift 模型 / 控制器 / 页面及构建打包脚本。未运行构建脚本、原生二进制、USB 扫描、Sahara / Firehose 或设备读写；也未运行新 stderr 行事件分支。工具可用性、协议、损坏输入、取消与全部设备行为均待恢复验收后证明，不能用既有 109 / 13 项结果代替。

随后新增 GPTEditing、EDLGPTActions、EDLExpression、EDLFlashPackage、EDLXMLActions / View，以及原生 GPT 事务 / XML / bootable 和两个 QDL 定向补丁。全部仍为源代码实现，未执行编译、补丁构建、测试或设备命令。事务读回、CRC、表达式边界、Sparse 分段、异常断线与取消语义均无新增运行证据。

## 0.4.0 开发中 · 可视分区 / GPT · 2026-10-28

- 完整 XCTest：109 项通过（95 core + 14 AppModel），带 AOSP 和原生 Root 集成环境运行。仍未达到全部 Windows 功能对齐，不作为最终交付。
- CommandRunner 新增直接写文件的二进制流式输出：8 MiB 非 UTF-8 数据、精确长度、诊断输出、取消、超时、短数据、过量生产者及防覆盖。GPT 可跳过 stdout 文本转换；分区回读不将整个镜像载入内存。
- 独立 Python `struct` / `zlib` 生成 UEFI GPT 元数据，512 / 4096 扇区均验证并导出逐字节一致；覆盖主表 / 备份表 CRC、条目 CRC、64 位溢出、GUID 重复、分区重叠、取消与超过 4 GiB 的备份位置。生成器及出处随 Fixtures 保存。
- 分区镜像预检支持 Sparse 展开容量与 Raw 容量校验、稳定副本、源文件变化 / 取消、半成品清理；外部 Fastboot fetch 输出需长度正确且 staging inode 不变才提交。
- ADB / Fastboot 分区协议、Linux 512-byte 单位到逻辑扇区换算、SCSI LUN、保护规则、Root 命令引号与有界擦除、2 TiB 分区容量字段均有测试。大小字段测试不代表已实际回读 2 TiB 文件。
- rawprogram XML 进行属性转义和偏移 / 大小换算，分区备份条目要求名称在物理 GPT 中唯一匹配且大小相同。
- 模拟 ADB 验证：确认前零写入；后续切换设备不会覆盖已审阅序列号；源文件或块路径变化时在 push 前停止；取消等待当前命令完成后不启动下一步；Sideload 不复用 shell 分区表；二进制回读不进入日志。
- 实际开发窗口：本地 GPT 3 分区显示 / 主备表导出；连接 `VIOLET_SIMULATED_ONLY` 后完成可视读表、boot_a 流式回读、GPT 主备备份及包含 PrimaryGPT / boot_a / BackupGPT 的 rawprogram XML。主备二进制逐字节匹配固定样本，XML 区域为 0+34、34+32、4063+33 sectors；模拟 boot_a 长度 16384 bytes，SHA-256 `da3562508b6ff702ff16bd554c5b9ff15e3a0d60561e464a1e6110b0dda79955`。
- 这些模拟器不会执行 Android 命令或访问 USB 硬件。未对真实手机执行本阶段写入 / 擦除；真实 UFS / eMMC、Fastboot fetch、Root 方言和设备启动仍需验收。

## 0.4.0 开发中 · 第一阶段 · 2026-10-28

- 本轮 83 项 XCTest 通过：75 core + 8 AppModel。未达到全部 Windows 功能对齐，不作为最终交付。
- AOSP 官方 mkbootimg 生成的 boot v0–v4、init_boot 样本：解析、原始组件导出、坏头 / 截断 / 不正确页大小、取消及源文件变化检查。
- AOSP avbtool → 原生验证：SHA256_RSA2048 / SHA512_RSA4096、footer / 独立 vbmeta、未签名、篡改认证区 / 签名 / 公钥 / 分区内容、越界和截断。原生 RSA 2048 / 4096 签名输出 → avbtool 独立验证通过；PKCS#1 / PKCS#8、容量、取消、不覆盖检查通过。
- OCDT：6 组平台 / 变体输出逐一匹配上游 Python 的 SHA-256；覆盖旧 MTK OSIG 占位、QC 双 OSIG、standard / fill02 / geyixue_fill / mixed_projid，以及非法头 / 取消 / 防覆盖。
- Root 模块：ZIP 元数据 / SHA-256、重复条目 / id / 路径校验、管理器响应和状态解析、批量顺序、失败 / 取消后不启动下一模块、临时目录清理。AppModel 用模拟 ADB 验证审阅前不安装、确认目标序列号不会被后续设备选择覆盖。
- 文件浏览协议：含空格 / 引号 / Unicode 名称、目录优先、非法响应、重复 / 路径穿越、新建防覆盖与命令引号。应用批量操作同样用模拟 ADB 检查目标绑定及无效包名无命令执行。
- 原生 magiskboot + 官方 Magisk 31.1 APK 在 Mac 完成合成 boot 修补：保留原始内核，ramdisk 被识别为 Magisk patched，回读配置和 SHA1，原始文件字节保持。
- 原生 ksud + 官方 ksuinit，在合成 boot 分别注入 KernelSU / SukiSU_Ultra / ReSukiSU 三组 `.ko`，导出 ramdisk 后回读模块，逐字节匹配输入。
- 原生 host 工具由固定源码提交构建，Apple Silicon 和 Intel 均已交叉构建成功；依赖和散列记录见 `NATIVE_TOOLS.json`。Intel 工具尚未在 Intel 硬件运行。
- 实际开发窗口完成 Boot v2 的五组件分析和六文件导出（含清单），以及 AVB footer 镜像签名与自身分区 hash 验证。未对真实手机进行本轮 Root / 模块 / 刷写操作。
- 随后使用完整 SwiftUI「脱机修补」页面完成 Magisk 与内置 KernelSU LKM 的另存为流程；从实际界面输出重新解包，确认 Magisk patched 状态，以及 KernelSU 模块与输入逐字节相同。源镜像哈希保持。

带外部参考工具的完整测试命令（先准备 `.cache/aosp-v4/avbtool.py` 和官方测试 APK）：

```bash
VIOLET_AVBTOOL="$PWD/macOS/.cache/aosp-v4/avbtool.py" \
VIOLET_MAGISKBOOT="$PWD/macOS/.cache/packaged-tools/arm64/native-tools/magiskboot" \
VIOLET_MAGISK_APK="$PWD/macOS/.cache/native-tools/Magisk-v31.1.apk" \
VIOLET_KSUD="$PWD/macOS/.cache/packaged-tools/arm64/native-tools/ksud" \
VIOLET_KSUINIT="$PWD/macOS/.cache/packaged-tools/arm64/RootPayloads/ksuinit-aarch64" \
bash macOS/scripts/test.sh --scratch-path macOS/.build-tests
```

不设置参考工具环境变量时，相关 3 项集成测试会明确 skip，不可称其通过。APatch / FolkPatch 的可修补真实 GKI、Root 后设备启动、模块实际运行、Intel 与 macOS 13 硬件验收及其余 Windows 对齐项仍待完成。

## 0.3.0 · 2026-10-27

本机 Apple Silicon / macOS 27.0.1 / Swift 6.4：

- 46 项核心测试 + 5 项应用模型测试通过，共 51 项，无失败。
- AES-CFB128 对照 NIST SP 800-38A 向量，覆盖整块、非整块及分次更新。
- OPS 对照 B. Kerler 原始参考算法生成的 MBox 4/5/6 固定向量，包含 7、16、17、32、4096 字节；合成包中包含超过 1 MiB 的加密文件，验证流式上下文跨块连续。
- 7 个独立加密的合成固件包（3 个 OPS、2 个 MTK OFP、2 个高通 OFP）全部提取文件的长度和 SHA-256 与固定清单一致。OFP 加密夹具由系统 OpenSSL 生成，包含非 16 字节对齐的加密前缀、512 / 4096 页及不同密钥。
- 覆盖不安全路径、冲突文件名、源文件变化、符号链接、XML 实体声明、越界、取消和已有文件保护。
- Sparse 覆盖 RAW / FILL / DONT_CARE / CRC32、扩展头、4 GiB + 4096 字节逻辑空洞及独立 CRC32 期望值、分段排序、混合格式和布局拒绝、相同重叠重用与不同内容冲突、ProFile.xml 分组。
- 实际 0.3.0 窗口已导出 OPS 合成包的 5 个文件，逐个比对固定哈希；也完成 Sparse 展开和两段 Sparse Super 合并，逐字节复核输出一致。
- 修复后台设备扫描期间本地文件任务偶发不能启动的问题，并添加模型回归测试。
- Apple Silicon 已打开运行；Intel 为交叉编译，仍需对应硬件回归。macOS 13 最低系统未实测。
- 未使用真实厂商 OFP / OPS 做兼容性回归，未连接手机或进行真实刷写。加密 ZIP OFP、新版未知密钥、lpmake 重建、EDL / 自动救砖仍未覆盖。

## 0.2.0 · 2026-10-27

本机 Apple Silicon / macOS 27.0.1 / Swift 6.4：

- 29 项核心测试 + 4 项应用模型测试通过，共 33 项，无失败。
- 合成 Payload 测试包含 REPLACE、BZip2、XZ、ZERO、DISCARD、非连续 extents、尾块填零、操作及最终镜像 SHA-256、增量操作拒绝、越界/路径/重叠检查、中途取消及文件保护。
- 原生系统 libarchive 实测通过普通 ZIP 和强制 ZIP64 元数据的 OTA 夹具。
- 回环 HTTP 服务器验证完整下载、断点恢复、替换链接、If-Range、ETag 变化、服务端忽略 Range、错误范围、截断响应、取消、空片段、完整片段的 416 响应，以及 ROM 查询/请求头传递。网络测试无需访问外网。
- 在实际 0.2.0 窗口中打开合成 OTA ZIP，导出两份测试分区，并逐字节及 SHA-256 复核输出正确；这些为合成测试数据，不可用于刷机。
- 在实际窗口中完成 1 MiB 回环下载并校验内容一致。
- 在实际窗口中调用上游公开 ROM 服务，成功读取 OnePlus 系列、机型、版本及下载地址；未下载大型真实 ROM。
- Apple Silicon 与 Intel Release 应用均已编译打包。Intel 仍未在对应硬件上运行，macOS 13 最低系统也未实测。
- 未连接真实 Android 设备，未进行真实刷写。没有用真实、多 GB 的厂商 OTA 做提取回归；增量 / ZSTD / 远程按需 Payload 仍不支持。

## 0.1.0 · 2026-10-27

2026-10-27，本机 Apple Silicon / macOS 27.0.1 / Swift 6.4：

- 原生应用已编译并实际打开，检查设备概览、镜像刷写和工具设置页面。
- 应用界面已实际执行 ADB / Fastboot 版本查询，返回 Platform Tools 37.0.1。
- 13 项核心测试 + 4 项应用模型测试通过，共 17 项，无失败。
- Apple Silicon 与 Intel 均已完成 Release 编译和 `.app` / ZIP / DMG 打包。
- 未连接真实 Android 设备；未进行真实安装、传输、投屏或刷写。Intel 版本为交叉编译，未在 Intel 硬件运行；macOS 13 最低版本尚未实测。

## 自动验证

运行 `bash macOS/scripts/test.sh`，覆盖真实子进程执行、取消、超时、二进制截图数据传输基础、输入解析、设备状态等。应用模型测试使用临时模拟 ADB/Fastboot，验证多设备选择、目标绑定和操作确认。脚本会为当前命令选择已安装的完整 Xcode，不修改系统 xcode-select 设置。

运行 `bash macOS/scripts/build-app.sh --with-platform-tools --dmg` 后，检查：

```bash
codesign --verify --deep --strict macOS/dist/arm64/VioletToolBox.app
macOS/dist/arm64/VioletToolBox.app/Contents/Resources/platform-tools/adb version
macOS/dist/arm64/VioletToolBox.app/Contents/Resources/platform-tools/fastboot --version
open macOS/dist/arm64/VioletToolBox.app
```

## 实际手机回归清单

以下需要测试人员连接自己的测试设备。未连接真实手机时不能据此宣称验证通过。

- [ ] USB 未授权 → 手机允许 → 属性读取。
- [ ] 两台 ADB 设备：只向选中的设备执行命令。
- [ ] 当前设备拔线：不切换到另一台手机，不允许继续执行设备操作。
- [ ] ADB → Bootloader → FastbootD → 系统，各状态重新选取目标。
- [ ] 中文、空格、单引号路径发送/接收，递归目录接收。
- [ ] 截图 PNG 可打开，像素与设备一致。
- [ ] APK 安装、列表查询、冻结/解冻、base/split APK 提取。
- [ ] scrcpy 启停、保持唤醒、音频、帧率，并行使用 ADB 按键。
- [ ] 无线配对和连接分别使用正确端口；错误配对码和超时有提示。
- [ ] Sideload 使用测试机对应的签名 OTA，核实设备端实际安装结果。
- [ ] 仅在可恢复的测试机上刷写已验证的镜像；核对序列号、分区和槽位。
- [ ] 测试 Intel Mac 与 macOS 13 最低系统版本的启动、工具动态库加载。
- [ ] 使用多个厂商的真实全量 OTA，分别核对 boot / init_boot / vendor_boot 等导出镜像的哈希。
- [ ] 使用大于 4 GiB 的真实 ZIP64 OTA 检查磁盘空间、进度、取消与临时文件清理。
- [ ] 使用实际过期的 CDN 链接替换续传，确认服务器的文件校验字段保持一致。
- [ ] 使用真实厂商高通 / MTK OFP、旧版 OPS 对照官方已知镜像哈希，验证文件表和加密前缀兼容性。
- [ ] 使用真实多运营商 Super 分段与 ProFile.xml，确认分组、合并结果及存储占用。
- [ ] 在目标外置文件系统验证稀疏输出、独占改名、磁盘满时清理。

## 已知限制

- 命令输出在子进程结束后写入日志，长时间传输期间只显示活动状态，暂未显示逐字节进度。
- Payload 和下载有实时字节/百分比进度；上条限制仅适用于 ADB / Fastboot 子进程。
- OFP / OPS 解包与 Sparse / Super 处理也有字节进度和取消功能；固件头分析阶段显示活动状态。
- Sideload 仅报告 ADB 传送结果，设备端签名校验和安装结果需在 Recovery 上确认。
- 停止仅结束本机客户端进程，不回滚设备已完成的操作。
- 应用采用本地临时签名，尚未公证。Windows 特有及其他未移植模块参见 README。
- Payload 校验遵循 manifest 提供的 SHA-256；不验证厂商签名。ZIP 需要先解压完整 payload 到临时目录。
- 下载为单连接，缺少有效续传校验字段的服务器需要重新下载；签名来源 URL 会保存在权限为 0600 的本地续传记录中。
- OFP / OPS 不验证厂商签名，也不校验未提供的镜像哈希；Sparse 仅在格式提供时验证 CRC32。请对真实镜像另行核对已知哈希。
