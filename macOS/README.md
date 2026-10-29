# 紫罗兰工具箱 macOS

基于 [Smart-Paocai/VioletToolBox](https://github.com/Smart-Paocai/VioletToolBox) 的原生 SwiftUI 客户端。原项目使用 Windows WPF，因此此目录独立实现 Mac 界面和工具调用，不改变 Windows 项目。

要求 macOS 13+。可为 Apple Silicon（arm64）和 Intel（x86_64）分别编译。当前开发版本为 **0.4.0**（完整功能对齐进行中，未最终交付），不代表 Windows 版约 110 项功能已全部迁移。

## 运行

构建后的应用位于 `macOS/dist/<架构>/VioletToolBox.app`，同目录提供 ZIP / DMG。打开 DMG 后可将应用拖入 Applications。

1. 手机上启用开发者选项和 USB 调试，通过数据线连接 Mac。
2. 在手机弹窗允许 USB 调试，在应用顶部选择目标设备。
3. 进入对应功能页。每条设备命令都绑定目标序列号；断开后不会自动切换到另一台手机。

使用 `--with-platform-tools` 构建的本地应用包含 Google 官方 macOS ADB/Fastboot 及原始 NOTICE。普通构建会搜索 Homebrew 或 Android SDK 中的工具，也可在「工具与设置」指定工具目录。

```bash
brew install --cask android-platform-tools
brew install scrcpy
```

投屏需要额外安装 scrcpy。支持 M 系列和 Intel 常见 Homebrew 路径。配置 scrcpy 所在目录时仍会继续搜索 ADB/Fastboot。

构建默认采用临时签名，未经过 Developer ID 签名和 Apple 公证；外部分发前需完成正式签名、公证和实际设备回归。

> **macOS 0.1.0 未测试开发预览**：功能仍在移植，未与 Windows 版完全对齐。此版本的当前源码尚未编译或测试，也没有真机验收；此前的测试结果不代表覆盖当前代码。请勿将其视为稳定版或最终交付。

## 已接通的功能

| 页面 | 功能 |
| --- | --- |
| 设备概览 | ADB/Fastboot 多设备识别、未授权/离线/Recovery/Sideload 状态、属性读取、系统/Recovery/Bootloader/FastbootD 重启 |
| 镜像刷写 | 自定义分区、当前/A/B 槽位刷写、临时启动镜像、读取 Fastboot 信息、切换槽位、Bootloader 解锁、Recovery OTA Sideload |
| 可视分区 / GPT | ADB Root / Fastboot 读表、镜像目录匹配、多选回读 / 写入 / 擦除、保护分区、基带备份、GPT 主备 CRC32 与布局验证、GPT / 备份 rawprogram XML、本地完整磁盘镜像分析 |
| 批量线刷 | BAT / 简单 SH / JSON 计划、RawProgram、步骤调整、机型 / anti 模板、跨模式等待、逻辑分区增删 / resize、Mac 脚本生成；本轮新增能力未验收 |
| 欧加全量线刷 | 本地目录四模式计划、QC / MTK 与槽位分流、COW / 逻辑分区重建、modem 与收尾编排、xbl_config ARB 本地 / ADB Root 分析；待验收，云端与售后专用流程继续移植 |
| EDL / 9008 | 通用后端、Loader、GPT / 分区操作、主备 GPT 恢复、切槽 / 启动 LUN、RawProgram / Patch 及 Sparse 整包；源码已接通，工具尚未构建，厂商认证与专用能力待补 |
| Boot 组件 | boot / init_boot header v0–v4 分析、原始组件与偏移清单导出 |
| 脱机修补 | Mac 原生 magiskboot / kptools / ksud；Magisk / Alpha ramdisk 修补、APatch / FolkPatch 流程、KSU / SukiSU / ReSukiSU LKM 注入，真实设备兼容性待验 |
| AVB 校验与签名 | 内嵌公钥 RSA 校验、可用分区 hash 校验、RSA PEM hash footer 签名副本；尚不包含厂商链重建 |
| Root 模块 | ZIP 元数据 / SHA-256、Magisk / KernelSU / APatch 检测、批量安装、启停 / 标记卸载 |
| 安卓通用 | OCDT 128 KiB / 8 MiB 分析与生成、项目号 / 变体 / OSIG 状态、ADB 临时目录权限修复 |
| Payload 提取 | 本地 OTA ZIP / payload.bin 分析与多选导出；新增远程 Range / ZIP64 / Stored Payload、通用 ZIP / Deflate、metadata、ZSTD 源码及共享写入层，未验收 |
| OFP / OPS 解包 | 传统高通 / 联发科 OFP，OnePlus OPS MBox 4/5/6，文件表浏览、搜索与多选导出、配置文件保留 |
| Super / Sparse | Android Sparse v1 展开、RAW / FILL / DONT_CARE / CRC32、Sparse 分段覆盖合并、Raw 分段拼接、ProFile.xml 分组映射 |
| ROM 资源 | 使用上游 ROM API 查询品牌系列、机型、版本、获取和复制下载地址；新增联想 SN / MTM / Y700、携带请求头的在线分区 / ZIP，尚未验收 |
| 降级助手 | 新增 ColorOS / 一加手机端加密握手、版本查询、云端 metadata 详情、APK 选择安装、包下载 / 大小 / MD5、推送及安装请求源码；尚未编译或验收 |
| 下载与续传 | HTTP/HTTPS 流式下载、暂停、跨启动续传、替换过期链接、Range / ETag / Last-Modified 校验、实时进度 |
| 文件与备份 | 可视目录、多选接收、新建 / 重命名 / 删除、设备 APK 安装、多文件发送、文件/目录递归接收、存储占用、DCIM/Pictures/Movies 备份 |
| 应用管理 | 第三方/全部/冻结应用查询、搜索、多选、复制包名、批量独立 APK 安装、base/split APK 提取、冻结/解冻、卸载、清除数据、小米更新器快捷操作 |
| 屏幕与投屏 | 二进制 PNG 截图、scrcpy 分辨率/帧率/音频配置、虚拟按键、通知栏控制 |
| 命令控制台 | ADB/Fastboot 参数解析、目标设备绑定、自定义命令确认、完整命令输出 |
| 工具与设置 | 工具路径、版本检查、ADB 服务启停、Android 11+ 无线配对和连接 |
| 日志 | 时间戳、错误退出码、超时、取消、日志导出 |

刷写、槽位切换、解锁、卸载等操作会在执行前显示目标设备及具体命令。Bootloader 解锁通常会清空设备；需先备份。取消刷写不会回滚已写入的数据。刷写模式、权限、分区名称和命令支持取决于具体手机。

## 尚未移植

- EDL 厂商认证与 VIP、云端 Loader、OEM / 版本查询和动态 Super；通用后端、GPT 恢复、槽位和 XML 已接入代码，尚未构建或验收，不运行 Windows 驱动和 QSaharaServer.exe。
- 欧加自动线刷/救砖、一加全自动 Root、GKI / AnyKernel3 制作、AVB 厂商链重建、隐藏环境编排。
- Payload 更大操作的流式解码、远程块缓存 / worker、完整厂商链接解析；ZSTD / Range 已新增源码，运行回归待补。当前 Windows Payload 后端也拒绝 SOURCE_* / 源摘要差分，Mac 同样明确标记。
- 加密 ZIP OFP、未知新 OFP / OPS 格式、lpmake 动态分区重建。
- 降级助手随包 APK、运行验收、多线程下载、通讯录备份。
- Windows CMD / 设备管理器入口的 Mac 等价能力。完整逐项差距见 [PORTING_STATUS.md](PORTING_STATUS.md)。

未移植功能不提供假按钮或模拟成功结果。「关于与移植进度」页面同步列出覆盖范围。

2026-10-28 起按用户要求先继续功能移植，暂停验证测试。新代码的实现状态与验收状态分开记录，详见 `PORTING_STATUS.md`；现有构建包不包含之后的全部源代码变化。

EDL 页独立选择目标，确认 Loader、序列号、UFS / eMMC 和 LUN 后发送 RAM Loader，再读几何与 GPT。分区写入 / 擦除使用物理 LBA，执行前重新核对容量和 GPT。通用路径不声称完成小米 / 欧加认证；范围与打包说明见 [EDL_NATIVE.md](EDL_NATIVE.md)。当前新增源码尚不能当作已验收的实机版本。

## 批量线刷

导入 BAT、简单 SH 或 JSON，按原顺序转换为 Fastboot 操作，显示具体镜像与目标。未知控制流和变量会阻止执行，不能将未识别部分略过。已识别的小米机型和 anti 完整模板转为前置条件，固定索引或 `images/anti_version.txt` 都纳入计划。原始 BAT / SH 不交给系统 Shell 运行。目录生成会按文件名排序，可上下移动或移除步骤；系统 / Recovery 重启需位于最后，Bootloader / FastbootD 重启支持后续阶段并等待同序列号模式响应。机型与防回滚未声明时显示给用户人工核对。

RawProgram XML 支持同一目录中多文件导入，只将文件偏移为零、镜像存在且名称唯一的条目作为完整命名分区镜像；GPT 物理条目、分段 / 重复标签、空文件与越界路径会跳过并列出原因。也可在可视分区页，将 XML 的镜像按标签精确匹配到已读出的设备分区表。此入口不执行 XML 物理扇区写入。

确认前分析全部镜像展开大小，并检查当前阶段可查询的分区容量；确认后先复制全部输入，重新检查条件，再开始命令。未来模式或重建后的容量在对应阶段、写入之前核对，确认窗口会注明。支持逻辑分区创建 / 删除 / resize、COW 清理和快照 cancel；零大小创建后的镜像会在计划审阅时补入明确 resize 步骤。每条命令绑定确认的序列号，失败后停止，取消等待当前命令返回。脚本导出保存到包目录，使用 `bash flash.command 设备序列号 --execute` 手动运行；运行前复制并核对全部镜像 SHA-256。JSON 同样保存于包目录。所有新能力仍待验收，复杂模板与厂商完整流程继续移植。

欧加页面从本地包目录或 images 子目录选择源镜像，生成标准、强力重建、AB 通刷或仅 FastbootD 计划，再到批量页面审阅。处理器平台由设备目录中的 lk / xbl 特征核对，明确区分有槽和无槽目标。强力 / AB / 仅 FastbootD 需要 my_company 和 my_preload；QC modem 在 Bootloader 刷写、MTK modem 保持 FastbootD。所有模式包含末尾 FRP 擦除，可选清数据与重启。ARB 页面读取 xbl_config ELF64 的 OEM 索引，可选本地文件或 ADB Root 回读 A / B 槽；不会更改手机分区或硬件熔丝。售后包专用模式、云端提取、完整资源准备及个别失败回退策略仍未完成。

## Payload 提取

打开本地全量 OTA ZIP 或 `payload.bin`，选择分区和输出文件夹。每次导出创建独立子目录，不覆盖已有 `.img`。ZIP 通过 macOS 系统 libarchive 解压至临时文件后分析，需要能容纳 ZIP 解压结果及导出镜像的空间；正常退出或替换来源后清理临时文件。

使用系统 libbz2 / liblzma 处理 BZip2 / XZ，无需额外安装解包工具。支持 Payload v2。源分区依赖、未知压缩类型和增量差分操作会标为不可提取；单操作解码限制 256 MiB，manifest 限制 64 MiB，以避免损坏文件导致无限内存分配。有 SHA-256 字段时分别校验压缩数据和最终分区；这不代表已验证厂商签名。

取消或失败会删除当前分区的半成品，并保留此前完成的分区。远程链接可先在下载页下载，完成后本地分析；本版尚未实现远程按需提取。

## OFP / OPS 解包

打开传统高通 / 联发科 `.ofp` 或旧版 OnePlus `.ops`，浏览和搜索文件表，多选需要的镜像，导出到自动创建的独立目录。有 `ProFile.xml` / `settings.xml` 时会同时保留配置文件，方便查看机型及 Super 映射。

OFP 使用 macOS CommonCrypto 的 AES-CFB128，OPS MBox 4、5、6 使用本机 C 实现，无需 Python、Wine 或厂商 Windows 工具。超过 1 MiB 的加密内容按流解密。未知密钥、文件表越界、重复路径冲突、路径穿越和 XML DTD / 实体声明会被拒绝。已有文件不会被覆盖，取消后保留已完成文件，删除当前半成品。

此功能不支持加密 ZIP 封装的 OFP，也不保证支持新版本厂商格式。OFP / OPS 解析只校验结构、范围、文件身份和输出长度，不验证厂商签名或每个镜像的真实性；应对真实固件另行核对已知哈希。原始资料与算法署名见 [NOTICE.md](NOTICE.md)。

## Super / Sparse

Sparse 展开支持 Android Sparse v1 的 RAW、FILL、DONT_CARE、CRC32 chunk 以及扩展头。提供 CRC32 时会校验；未提供时检查结构和范围。零填充和空洞使用文件系统稀疏文件表示，逻辑大小可大于磁盘实际占用；支持超过 4 GiB 的逻辑偏移，单镜像限制 1 TiB。

Super 合并识别 `super.0.hash.img`、`super_0.img`、`super.img.0` 等编号，要求从 0 或 1 起连续。Sparse 分段必须块大小和展开大小一致，按逻辑位置叠加，DONT_CARE 不覆盖其他段；已写区间只允许重复相同内容，数据冲突时停止。Raw 分段按编号拼接。两种格式不能混合。

同目录存在 `ProFile.xml`，且选中文件涵盖多个 `super0` / `super1` 映射分组时，界面会要求选择同一运营商 / 版本分组。没有映射时需手动选择正确分段。本页尚不包含 lpmake 分区构建，也不会刷写设备。最终文件采用独占改名，避免覆盖现有镜像。

## ROM 查询与下载

Payload 页面新增在线读取输入；ROM 地址也可直接“在线读取分区 / ZIP”，结果显示在下方。支持远程 ZIP64 目录、Stored Payload 按分区提取、普通 ZIP Stored / Deflate 文件及 metadata 版本信息。ZSTD 1.5.7 解码源码已固定并接入。上述代码与本地共享写入重构尚未编译或运行，范围和缺口见 [REMOTE_FIRMWARE.md](REMOTE_FIRMWARE.md)。

联想查询位于 ROM 资源页面，接受 8 位 SN / 10 位 MTM，或使用 Y700 预设；SN 会提交给联想服务。独立降级助手页面按 Windows 协议实现了查询、下载、校验、推送与提交请求；当前仅源码移植，未运行验证，手机端接受请求不等于系统已降级。新增范围与缺口见 [DOWNGRADE_PORT.md](DOWNGRADE_PORT.md)。

在 ROM 资源页面依次读取系列、机型、版本，再获取下载地址。「准备下载」选择保存位置后，切到下载页点击开始。API 默认与 Windows 版相同：`https://violettool.top/rom-api`；可用环境变量 `VIOLET_ROM_API_BASE` 指定兼容服务。各品牌可用数据和下载地址时效由服务器决定。

本版采用单连接 HTTP Range 续传。底部停止按钮会暂停，片段和 JSON 记录保存在目标文件旁边。应用重启后填入下载地址并选择相同最终路径即可继续；不要删除或改动 `.violet-part` 和 `.violet-part.json`。下载完成后才改为最终文件名。

新链接必须仍指向同一文件，续传会核对响应范围、ETag（或 Last-Modified）及已知总大小。服务器忽略 Range、缺少续传校验信息或文件身份发生变化时停止并保留旧片段，需选择新文件名重新下载。已有完整文件不会被覆盖。ROM 请求头仅在内存使用；手动编辑下载地址时会清除，需从 ROM 页面重新准备下载以携带服务要求的请求头。签名 URL 和请求头不写入共享运行日志；续传记录本地保存来源 URL，文件权限为当前用户可读写。

## 构建与测试

构建需要 Xcode Command Line Tools（Swift 5.9+）；运行 XCTest 需要完整 Xcode。无第三方 Swift 包依赖。网络集成测试使用本机 `/usr/bin/python3` 启动临时回环服务器；应用运行不依赖 Python。

```bash
swift build --package-path macOS
bash macOS/scripts/test.sh

# 本机架构，ZIP + DMG；下载并加入 Google 官方平台工具
bash macOS/scripts/build-app.sh --with-platform-tools --dmg

# 交叉编译 Intel 版本
ARCH=x86_64 bash macOS/scripts/build-app.sh --with-platform-tools --dmg
```

`--with-platform-tools` 首次从 Google HTTPS 下载压缩包到 `macOS/.cache/`。构建产物记录下载包 SHA-256 和上游提交。它使用官方 latest 地址，因此工具版本并不固定；要复现同一工具版本，保留缓存归档和对应校验值。默认构建不下载工具。

在 Xcode 中可直接打开 `macOS/Package.swift`。SDK 27 的 `State` 宏与传统属性包装器同名，界面通过 `ViewState` 类型别名明确使用兼容 macOS 13 的属性包装器。

核心测试覆盖设备解析、路径/参数引号、子进程、取消、超时，以及合成 Payload 的解压与校验、ZIP、异常元数据、文件保护。OFP / OPS 使用系统 OpenSSL、独立 OPS 参考实现生成的合成包和固定哈希；AES 对照 NIST CFB 向量。Sparse 测试包括超过 4 GiB 的逻辑空洞、CRC32、重叠合并与冲突检查。网络测试通过临时回环服务器验证真实 HTTP 流式传输、续传与错误响应、ROM API 及请求头传递。模型测试通过临时模拟工具检查多设备选择、拔线后不切换目标、序列号绑定和破坏性操作确认。测试不对真实设备刷写。实际设备测试清单见 [TESTING.md](TESTING.md)。

## 源码与许可证

沿用根目录 `LICENSE` 的 GPL-3.0-or-later。上游源码、品牌图标与署名保留。OPS 算法参考的作者与 MIT 声明见 [NOTICE.md](NOTICE.md)，构建时一并放入应用。Google Platform Tools 与 scrcpy 为独立工具，遵循各自条款及 NOTICE。公开分发时应同时提供本移植版本的完整对应源码，保留第三方声明，并按所用工具的许可处理分发。

## 本地镜像处理与 Root

Boot 组件、AVB、OCDT 不依赖手机。AVB 使用系统 Security / CryptoKit，支持 SHA256 / SHA512_RSA2048/4096/8192；用自己的未加密 RSA PKCS#1 / PKCS#8 PEM 生成 hash footer 副本时需填写真实分区容量及 rollback index。校验结果区分内嵌公钥签名、分区 hash、缺失分区、Hashtree 与链式描述符，不将部分验证写成完整信任验证。OCDT 生成沿用上游算法，不带有效厂商 RSA 签名。

脱机修补的原生工具构建与验证见 [NATIVE_TOOLS.md](NATIVE_TOOLS.md)。Root 模块安装需要已有 Root 的 Android 设备，先检测并在手机授权，审阅模块 id、版本、SHA-256 和目标序列号后才执行。模块脚本以 Root 权限运行；失败 / 取消停止后续模块，已安装的模块不自动回滚。取消 ADB 不保证设备端脚本立即停止。启停 / 卸载通常重启后完全生效，本应用不自动重启。

## 可视分区与 GPT

先在顶部选择设备，再读取分区表。ADB 需要 Shell Root，从 by-name 目录解析真实块路径和容量；Fastboot 解析设备返回的 partition-size / partition-type。选择镜像时可逐行指定或匹配目录，匹配结果需核对槽位。写入前重新验证目标，并检查镜像展开后大小；ADB 的 Sparse 镜像先转换为 Raw，Fastboot 使用稳定的源文件副本。

回读直接流式保存到 Mac，按分区容量检查输出长度，不将整份镜像载入内存。失败 / 取消删除当前半成品，保留已完成输出，不覆盖已有文件。Fastboot fetch 需要设备支持。批量写入 / 擦除的停止请求会等待当前命令结束，然后停止后续操作；强制退出不能回滚已写入的数据。

分区保护沿用 Windows 可视刷写规则：modemst1/2、fsg、fsc、oplusdycnvbk、oplusstanvbk；ADB 模式还保护 userdata / metadata。persist 仍可作为明确选择的写入目标；回读和备份允许读取这些分区。

GPT 备份从 UFS / eMMC 物理块设备读取主备表，校验 header / entry-array CRC32、GUID、几何范围、主备一致性和分区重叠，保存二进制区域、分区清单和设备映射。可选生成 rawprogram XML；分区备份仅在物理 GPT 中名称唯一、实际大小匹配时加入还原条目。重复 LUN 或匹配失败会明确报告，不能把不完整映射用于还原。此页不自动执行 EDL 还原。

本地分析要求含主备区域的完整磁盘镜像，按实际扇区大小选择 512 / 4096 等；单独 gpt_main 文件没有磁盘末尾备份区域。物理设备相关流程目前通过模拟 ADB 验证，仍需真实设备回归。
