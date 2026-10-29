# Windows 功能对齐工作表

目标：以当前检出的上游 Windows 源码为基线，完成 macOS 功能对齐并验证后再最终交付。**当前仍在移植，未达到最终交付条件。**

`WINDOWS_ACTIONS.json` 记录所有 XAML 的 Click / Drop / SelectionChanged / Checked / Unchecked 入口、控件文字和 C# 实现位置，使用 `python3 macOS/scripts/inventory-windows.py` 可重新生成。事件入口包含文件选择、导航、状态切换，不能当作已实现功能数量；动态绑定事件和后端流程还需人工追踪。

状态：本地验证 = 原生实现及合成样本 / 模拟命令测试通过；设备待验 = 命令已接通，尚未在真实设备验收；部分 = 尚有对应能力缺口；待移植 = 尚无完整实现。最终验收不能用编译成功替代实际结果。

2026-10-28 用户调整：先继续移植，暂不需要验证测试。因此从此记录起暂停新增测试运行、编译验收和界面验收，新增代码单独标为未验收。此前已经运行的结果仅覆盖当时的代码。用户提供的后续测试机为一加 13，Bootloader 已解锁、有 Root；最近一次只读 ADB 设备列表为空，未对手机执行写入操作。

| 功能域 | 当前状态 | 尚需对齐 / 验收 |
|---|---|---|
| 设备连接、属性、重启、槽位、无线调试 | 设备待验 | EDL 入口、检测开关、全部属性及状态迁移 |
| 投屏、截图、按键、音量 | 部分 | 已补屏幕旋转；其余 scrcpy 选项和设备实测待补 |
| 基本刷入、解锁 / 回锁、清除数据 | 部分 | 新增逻辑分区增删 / resize、跨模式步骤、OEM cdms / lock、-w，以及小米常见机型 / anti 模板；模板变体、CRC / Slot_A 配置及其余工具待补，新增代码未验收 |
| Fastboot 可视分区、GPT | 部分 / 设备待验 | 已补读表、流式回读 / 写入 / 擦除、GPT 备份及 XML；新增 RawProgram 完整镜像导入、分区表匹配、计划步骤调整，后者按用户要求暂不验收 |
| 欧加线刷：全量 / 售后 | 部分 / 未验收 | 已补本地目录、四模式计划、平台 / 目标冲突检查、COW、逻辑分区重建、QC / MTK modem 阶段和收尾、xbl_config ARB 本地 / ADB Root 分析；云端按需提取、售后专用流程、完整资源包、ARB 远程来源和运行回归待补 |
| EDL / Sahara / Firehose | 部分 / 未验收 | 新增通用后端、Loader、多 LUN / GPT / 分区操作，以及主备 GPT 恢复、A/B 切槽、启动 LUN、RawProgram / Patch / Sparse 整包；认证、云 Loader、OEM、版本信息、动态 Super 及其余流程未完成，全部新工具未编译 |
| 降级助手 | 部分 / 未验收 | 新增 APK 下载入口 / 安装、手机端加密握手、版本查询、大小 / MD5、下载 / 推送 / 安装请求及云端 metadata 详情；随包 APK、兼容与完整运行验收待补 |
| Root 模块 ZIP 批量安装 | 设备待验 | Magisk / KernelSU / APatch 实测；元数据、命令顺序、失败 / 取消已测试 |
| 隐藏环境及检测应用 | 待移植 | 资源包格式及下载、模块 / 应用安装编排、设备实测 |
| 脱机修补 | 部分 | 已有 Boot v0–v4 组件分析与导出；Mac 原生 Magisk / Alpha 流程、三种 LKM 注入已本地测试；APatch / FolkPatch 流程接通，真实内核 / 启动与自动模式待验 |
| 一加全自动 Root | 待移植 | 机型 / KMI 选择、匹配资源、修补 / 刷入 / 安装管理器及恢复流程 |
| GKI + AnyKernel3 | 待移植 | 内核 / dtb 替换、重打包、兼容性验证 |
| AVB | 部分 | RSA 校验、hash footer 签名副本已通过 AOSP 交叉验证；缺 Windows 新旧链式重建、内置方案、Hashtree 相关流程 |
| 文件管理 | 部分 | 已有收发 / 目录日志；已补可视浏览、多选、新建、重命名、删除；设备回归待验 |
| 应用管理 | 部分 | 已有独立 APK 安装 / 提取 / 冻结 / 卸载；已补多选、冻结列表、更新器快捷操作；设备回归待验 |
| Android 通用 | 部分 | 已补 OCDT 分析 / 生成、ADB 分区读写、Mac 线刷脚本生成；缺 Super 打包及部分 Root 快捷工具 |
| Payload | 部分 / 未验收 | 新增远程 Range / ZIP64 / Stored Payload、通用 ZIP 导出、metadata 与 ZSTD；本地共用解析 / 写入重构未回归，操作内存上限、缓存 / worker 和厂商链接解析待对齐；Windows 当前明确拒绝 SOURCE_* 差分 |
| OFP / OPS | 本地验证 / 部分 | 传统 QC / MTK 与 OPS MBox4/5/6 已测试；需真实包回归、明确上游格式边界 |
| Sparse / Super 分段 | 本地验证 / 部分 | 展开、CRC、分组合并已测试；缺 lpmake 分区重建及真实包回归 |
| 下载续传 | 本地验证 / 部分 | 暂停 / 续传 / 链接替换已测试；缺并发分段、全部任务管理 |
| ROM 下载专区 | 部分 | 已有主要品牌系列 / 机型 / 版本 / 链接；新增联想 SN / MTM、Y700 预设、携带请求头的在线分区 / ZIP，未验收；外部下载器、C16 / 魅族变体与线路回退待补 |
| 照片 / 视频 / 通讯录备份 | 部分 | 已有目录复制；缺缩略图选择、并发备份、联系人导出 / 导入 |
| 语言、公告、更新、帮助及工具检查 | 部分 | 中英文切换、公告、上游链接、macOS 等价系统信息入口 |

## 验证记录

- 2026-10-28：现有 109 项测试通过（95 core + 14 AppModel），包含 AOSP mkbootimg v0–v4 / init_boot 官方工具样本；AOSP avbtool → 原生验证，以及原生 RSA 2048 / 4096 输出 → avbtool 独立验证。新增流式二进制、GPT 512 / 4096、4 GiB 以上偏移、XML、分区保护、源文件 / 映射变化和命令边界停止验证。
- AVB 测试密钥和镜像均以 `TEST_ONLY_` 命名，仅用于测试。签名只证明与所用公钥一致，未完成厂商信任链验收。
- 目前没有真实手机 / EDL 设备验收记录；Intel 为交叉编译，macOS 13 与 Intel 硬件也需补验。

## 交付门槛

每项需有可使用的 macOS 入口、对等输入和输出、失败 / 取消行为及合理的验证证据。Windows 特有程序需实现对应 Mac 能力；不能仅提供 exe 路径或显示模拟成功。涉及真实刷写和厂商授权的功能必须如实记录设备与授权条件，尚未验证时保留未完成状态。

## 下一阶段

继续补齐复杂厂商批量脚本、欧加全量 / 售后流程、EDL 后端、AVB 链重建、GKI / AnyKernel3、降级助手剩余项、备份浏览与通讯录、远程 Payload 和并发下载。按用户最新指示，当前优先移植，暂停验证测试；不以中间包替代完整交付。

本轮新增源码（均未编译或运行验证）：

- 新增远程 HTTP Range、ZIP / ZIP64 / Deflate / CRC、Stored Payload 子范围与共享 manifest / 输出层、通用 ZIP 文件模式、ROM 在线入口及降级云端 metadata；转写 Windows 77 条机型名称。固定 ZSTD 1.5.7 纯 C 解码源码、来源散列与许可证，接入 type 14；未构建或测试。本地 Payload 写入也改用共享实现，旧测试通过不覆盖这次重构。完整范围与剩余差距见 [REMOTE_FIRMWARE.md](REMOTE_FIRMWARE.md)。

- 新增联想 SN / MTM 查询、四组 Y700 预设、机器 / 固件信息、精确 MTM 优先与候选提示、结果复制和下载衔接。新增降级助手 APK 选择 / 安装、P-256 / AES-CTR 手机握手、RSA-OAEP / AES-GCM 服务查询、版本选择、流式 MD5、副本推送与 `40006` 请求。序列号 / 当前版本绑定、授权重新查询、临时端口清理及命令边界停止已写入代码；未运行任何入口。资源准备和验收仍待补，见 [DOWNGRADE_PORT.md](DOWNGRADE_PORT.md)。

- 新增 GPT 主备元数据恢复与 A/B 切槽：按 Windows 的类型 GUID / 属性规则修改，更新双表 CRC，备份覆盖区域，再以单个原生事务完成各 LUN 写入 / 回读及启动 LUN。损坏表可走原始区域备份恢复，不把取消或失败称为自动回滚。
- 新增 EDL RawProgram / Patch 整包规划和界面：有界地址表达式、CRC32、文件偏移、Raw 截断、Sparse 校验及 DONT_CARE 叠加、保护选项、GPT-only、执行前复制全部输入。普通任务在当前镜像命令后停止，Patch 在镜像后执行；厂商变体和全部错误回退仍待补。
- 构建层加入 QDL bootable 错误回传及无符号扇区格式补丁，派生源码与补丁随包保存。未执行补丁构建、Swift 编译或任何测试，不把这些源代码状态计为验收通过。详细范围见 `EDL_NATIVE.md`。

- EDL 新增 `NativeTools/VioletEDL.c`、`EDL.swift`、`EDLActions.swift`、`EDLView.swift` 和固定源码的 `build-edl-tools.py`。使用 QDL 的真实 macOS USB / Sahara / Firehose 实现，不提供模拟设备成功路径；本阶段未运行设备入口。缺口与后续构建方式见 [EDL_NATIVE.md](EDL_NATIVE.md)。
- 固定序列号并拒绝同序列号多设备；确认 Loader 摘要，按实际几何与通过 CRC 验证的 GPT 定位；写入输入先稳定复制 / Sparse 展开，再复核目标。失败使上下文失效，输出通过 staging 提交，停止按分区命令边界处理。这是代码路径，尚非运行证据。
- 新增依赖、许可证 / 源码打包入口 `--with-edl-tools`，未执行构建；原有 dist 与内部构建未覆盖本轮源码。USB / 协议 / 设备 / ARM 与 Intel 验收继续暂停。

- `FlashPlan` JSON v2，兼容读取 v1：逻辑分区 create / delete / resize、COW 清理、FastbootD 要求、快照 cancel、OEM cdms / lock、-w；系统 / Recovery 重启末尾约束，Bootloader / FastbootD 可作为中间阶段。全部源镜像先复制；未来阶段的实际容量到达对应模式后再核对，确认窗口会注明。
- `XiaomiBatchGuards` 只转换完整匹配的已知机型 / anti 四段模板，支持固定索引或 `images/anti_version.txt`。外部索引文件纳入源变化检查；其他条件、变量与模板保留为阻止执行的诊断。未支持 CRC 选择、完整 Slot_A 精简逻辑和所有厂商模板。
- `OujiaFlashPlanner` 根据本地镜像与设备目录，生成标准 / 强力重建 / AB 通刷 / 仅 FastbootD 计划。区分高通 xbl / 联发科 lk、槽位与无槽分区；处理 my_company / my_preload、COW、目标逻辑分区重建、QC modem Bootloader 阶段与 MTK FastbootD 阶段。FRP 与清数据动作明确列在计划中。个别失败继续 / 回退策略、完整资源准备与实时传输进度仍需对齐，不能视为全量功能完成。
- `XBLARBImage` 对照 Windows ELF64 / 最后非空 PT_NULL / HASH metadata 算法读取 Major / Minor / ARB 索引；HASH 前缀与 OEM 数据按界限和偏移读取，不整段载入内存。新增本地文件与 ADB Root 回读入口；结果不代表直接读取硬件熔丝。
- `FlashPlanShell` 同步新增模式等待、分阶段容量检查、动态分区、COW、可忽略的分区不存在响应、查询超时与输出限制；信号停止等待当前命令结束。由于用户暂停测试，这些新分支及此前“跨模式应拒绝”的旧测试断言尚未运行 / 调整，不声称现有套件已覆盖本轮。

原有 `dist/` 0.3.0 应用保留；此前开发验证使用 `.cache/VioletToolBox-QA.app`（独立 bundle id `org.violettoolbox.macos.qa`），避免覆盖用户正在使用的应用。此前完整构建的内部检查包使用 `VIOLET_DIST_DIR` 指向 `.cache/development-builds/<arch>`。用户已提供一加 13、已解锁、有 Root 的条件，系统版本未提供；当前先继续编码，暂停测试与验收。

- 批量计划开发：BAT / 简单 SH / JSON 转声明式 Fastboot 步骤，未知控制流阻止执行；产品与防回滚条件、容量 / Sparse 展开检查、全部镜像先复制、固定序列号、失败停止和命令边界取消。Mac 脚本包含全部输入 SHA-256 校验。用户暂停验证前，8 项核心与 5 项模型专项测试已通过；随后新增的 RawProgram 导入、镜像匹配与步骤调整尚未编译或测试，不计入已验证功能。

- 2026-10-28：新增 Magisk 官方 APK 原生修补集成测试，以及三组 LKM 模块注入后回读字节验证；核心 host 工具的构建脚本已固定源码提交和 Rust 版本。真实 GKI / APatch、设备启动及完整功能对齐继续进行。
- 2026-10-28：实际开发窗口完成 GPT 三分区分析 / 导出，逐字节核对主备区域；仅连接 `VIOLET_SIMULATED_ONLY` 模拟器，完成可视读表、分区流式回读、GPT 备份及三条 rawprogram 区域生成，文件长度、内容、GUID 和扇区范围均已复核。未对真实手机执行分区写入。
