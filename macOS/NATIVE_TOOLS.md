# Mac 原生修补工具

完整功能对齐仍在进行，当前工具链用于开发和验证。不是 Windows 最终等价版交付。

`python3 macOS/scripts/build-native-tools.py --arch arm64`（或 `x86_64`）从固定源码提交构建三个 Mac 原生 CLI：

| 工具 | 源码与固定提交 | 许可 |
|---|---|---|
| magiskboot 31.1 | [topjohnwu/Magisk](https://github.com/topjohnwu/Magisk/tree/0972f67d97f9b6302b67c5171283330c74114b4a) | GPL-3.0 |
| kptools | [bmax121/KernelPatch](https://github.com/bmax121/KernelPatch/tree/406c85ce79a5e1c19b53be34c04baadc1ec68bc5) | GPL-2.0-or-later |
| ksud | [tiann/KernelSU](https://github.com/tiann/KernelSU/tree/75e179d378d7aaa0de8946358a3384444c3e36b0) | GPL-3.0 |

构建使用 Rust nightly-2026-10-27、Xcode clang、macOS 13 deployment target。Rust 安装在本项目 `.cache/native-tools`，不会修改系统 Rust 或 shell 配置。源码及依赖首次需联网下载；后续使用缓存。构建脚本与固定提交共同记录生成 flags.h 和 preset.h 的步骤。

输出为 `.cache/packaged-tools/<架构>/native-tools`、`RootPayloads` 和 `NATIVE_TOOLS.json`。应用打包增加 `--with-root-tools` 即可包含对应架构的程序。未构建工具时，可以在应用设置中指定你自己的原生工具目录。

RootPayloads 的 `akpimg` / `fkpimg` 与三种 LKM `.ko` 沿用上游 VioletToolBox 现有资源，保持其字节；`ksuinit-aarch64` 来自 [KernelSU v3.3.1](https://github.com/tiann/KernelSU/releases/tag/v3.3.1)，SHA-256 固定为 `365c66e5435a9ecdb3dbb23ceda2d9253568defeee3682af95220087094eff5d`。这些是 Android 目标文件，不作为 Mac 程序执行。不要把 Mac 架构与 Android 设备架构混为一谈。

## 验证范围

Magisk / Alpha 修补使用所选管理器 APK 的 magiskinit、magisk、init-ld，兼容包含 / 不包含 stub.apk 的封装；不执行 APK 中的 shell 安装脚本。单独的临时工作目录、严格退出码、源文件变化检查、取消和原子另存为保护原始文件。输出再次解析 Boot header，Magisk 还检查 ramdisk 修补状态。

已用官方 Magisk 31.1 APK 与含有效 newc ramdisk 的合成镜像验证完整修补，核对原始内核保持、ramdisk 状态和配置。三种上游 LKM 分支分别注入合成镜像并提取回读 `.ko`，逐字节比对一致。这些验证不代表真实设备启动成功，也不代表模块、ksuinit 与任意固件兼容。APatch / FolkPatch 仍需真实可修补 GKI 内核验证。自动 Root、厂商 AVB 信任链和刷入后恢复流程也仍未完成。

最终公开分发时需同时提供对应源码、依赖锁、构建步骤及各工具许可证；不能只分发二进制或丢失署名。当前最终交付门槛见 [PORTING_STATUS.md](PORTING_STATUS.md)。

## EDL 工具（尚未构建）

EDL 使用独立 `scripts/build-edl-tools.py`，固定 QDL 提交和 libusb 源码身份，输出 qdl、violet-edl、共享 libusb、许可、源码包与清单。`build-app.sh --with-edl-tools` 加入对应架构资料。用户目前暂停编译和测试，本阶段只编写构建与打包代码，没有生成 EDL 工具或声称 ARM / Intel 已通过；详见 [EDL_NATIVE.md](EDL_NATIVE.md)。
