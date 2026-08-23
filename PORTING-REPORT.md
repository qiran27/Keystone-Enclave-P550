# Keystone Enclave 移植到 HiFive Premier P550：问题与解决方案

## 1. 文档目的

本文记录将 Keystone Enclave 部署到 SiFive HiFive Premier P550 的实际移植过程，重点说明：

- 为什么不能只把 Keystone 内核驱动和用户程序复制进官方 Ubuntu；
- VisionFive 2 实现中哪些内容可以参考，哪些内容不能直接照搬；
- OpenSBI、PMP、多核中断、Linux 驱动、SDK、Eyrie 和示例程序分别遇到了什么问题；
- 每个主要问题最终采用了什么解决方法；
- 当前实现已经验证到什么程度，还有哪些安全边界。

本文对应的项目是 `keystone-p550-system`。最终实现基于 SiFive
2025.11.00-HFP550 系统来源、官方 Ubuntu 24.04 镜像和厂商 P550
bootchain，同时使用锁定的 Keystone VF2 分支作为 SM、驱动、SDK、
runtime 和 examples 的源代码基础。

## 2. 最终系统结构

Keystone 不是普通的 Ubuntu 软件包。完整系统跨越三个特权层级：

```text
U-mode    Host App / Enclave App
                     │
S-mode    Ubuntu Linux 6.12.33-1-premier
          keystone-driver.ko
                     │ SBI
M-mode    EIC7700X OpenSBI 1.6
          Keystone Security Monitor
                     │
Hardware  P550 harts / PMP / EIC7700X interrupt controller
```

因此最终交付物也分为三部分：

1. SiFive 官方 Ubuntu 镜像；
2. 包含 Keystone Security Monitor 的自定义 P550 bootloader；
3. 与精确内核和 SM 版本匹配的 Keystone payload。

官方 Ubuntu 镜像不需要重新编译。项目只编译自定义 bootchain 和
Keystone payload，再将它们与官方镜像组合为烧录目录。这显著减少了
构建时间、磁盘占用和与桌面软件包无关的下载失败。

## 3. 基线和来源选择

### 3.1 P550 平台基线

- SiFive Freedom-U-SDK：`2025.11.00-HFP550`；
- P550 官方 Ubuntu：Ubuntu 24.04 预安装镜像；
- Linux：`6.12.33-1-premier`；
- OpenSBI：SiFive/EIC7700X 定制的 OpenSBI 1.6；
- U-Boot 和 DDR/second-boot 固件：使用同一 SiFive 发布系列。

具体提交和下载哈希分别固定在：

- `sources.lock.yml`；
- `release-assets.lock.yml`。

### 3.2 Keystone 来源

官方 Keystone 仓库用于确认体系结构、SBI ABI 和预期行为；
VisionFive 2 实现用于参考实际板级集成方式。最终项目的 Keystone
SM、Linux driver、SDK、Eyrie runtime 和 examples 使用锁定的 VF2
提交：

```text
c5f7ac3977f50309ac816b54f470c4021573bf5e
```

这不是把 VisionFive 2 的整个系统原封不动复制到 P550。我们保留其
组件版本关系和 Keystone ABI，再针对 P550 的 OpenSBI 1.6、四个 hart、
八个 PMP entry、EIC7700X 中断控制器和厂商内存布局编写适配补丁。

## 4. 主要问题和解决方法

### 4.1 最初的完整 Yocto 镜像构建过大

#### 问题

直接构建 Freedom-U-SDK 的完整演示镜像会拉取和编译 XFCE、TensorFlow、
OpenCV、Rust、Boost 等大量与 Keystone 无关的组件。首次构建超过一万
个 BitBake task，消耗大量磁盘、内存和下载时间，也容易因为网络中断、
源码镜像不可用或虚拟机空间不足而失败。

日志中的：

```text
BUILD_SYS = "x86_64-linux"
```

表示构建工具运行在 x86_64 主机，并不表示目标板被编译成 x86_64。
目标包仍由 `MACHINE`、`TARGET_SYS` 和 RISC-V 交叉工具链决定。

#### 解决

项目改为混合部署方式：

- 复用 SiFive 官方预编译 Ubuntu rootfs；
- kas/Yocto 只构建 `bootchain` 目标；
- P550 payload 独立构建和发布；
- 使用 `clean-yocto-state.sh` 清理废弃的完整镜像构建状态。

这样只对真正涉及 M-mode、S-mode ABI 和 Keystone 的部分进行编译。

### 4.2 仅安装 Linux 驱动不能形成 Keystone 系统

#### 问题

官方 P550 Ubuntu 的启动链是：

```text
Ubuntu -> Linux -> vendor OpenSBI -> P550 bootchain
```

其中 stock OpenSBI 没有 Keystone SM。即使 `/dev/keystone_enclave` 因
驱动加载而出现，SM SBI extension 仍然不存在，无法建立可信执行环境。

#### 解决

通过 Yocto bbappend 将 Keystone SM 编译进 EIC7700X OpenSBI，并从
`eic770x_final_init()` 调用 `sm_init(cold_boot)`。最终烧录的是重新签装的
`bootloader_ddr5_secboot.bin`，不是官方 recovery bootloader。

相关入口：

- `meta-keystone-p550/recipes-bsp/opensbi/opensbi-sifive-hf-prem_1.6.bbappend`；
- `0001-eswin-eic770x-integrate-keystone-sm.patch`。

### 4.3 VF2 的 OpenSBI 接口与 P550 OpenSBI 1.6 不兼容

#### 问题

VF2 代码面向不同的 OpenSBI 版本。OpenSBI 1.6 已改变：

- SBI extension handler 返回结构；
- trap handler 的参数和完整寄存器上下文；
- trap 返回和 `mepc` 更新规则；
- TLB/IPI 回调接口。

直接套用 VF2 的 ecall 和 trap 代码会出现返回值被覆盖、PC 多前进一条
指令、循环 trap、非法访问或 hart 锁死。

#### 解决

- 使用 `struct sbi_ecall_return` 和 `skip_regs_update` 保留 Keystone SBI ABI；
- 使用 OpenSBI 1.6 的完整 `struct sbi_trap_context`；
- 只在正确位置推进 host `mepc`；
- 恢复 host 上下文后再发布 timer/software interrupt；
- 保持 `mtvec` 指向 OpenSBI 1.6 原生 `_trap_handler`，在 C 层按 enclave
  状态分派给 Keystone，避免使用旧版 VF2 `trap.S`。

主要补丁为 `0003`、`0004`、`0006`、`0007` 和 `0019`。

### 4.4 P550 PMP 数量和厂商布局冲突

#### 问题

P550 平台只有八个可用 PMP entry。厂商 OpenSBI 还需要保护自身、两个
DRAM hole 和 ACLINT 区域。OpenSBI Domain0 PMP 配置发生在平台 final-init
之后，并可能设置锁定位。它会覆盖或锁住 Keystone 已建立的 PMP 布局，
导致：

- EPM 无法获得执行权限；
- loader 首次取指发生 fault；
- Linux 或 enclave 错误访问保留区域；
- 多个 enclave 并发时耗尽 PMP region。

#### 解决

- 定义 P550 专用的四 hart、八 PMP entry 平台参数；
- 保留 OpenSBI、厂商 DRAM holes 和 ACLINT 的保护；
- 在 OpenSBI 标准 PMP 阶段之后把 PMP 所有权交还 Keystone；
- 对 Keystone P550 构建跳过会锁定 entry 的第二次 Domain0 布局；
- 将剩余 entry 留给 enclave EPM 和 UTM。

主要补丁为 `0012`、`0013` 和 `0022`。

四个 CPU 并不意味着可以同时创建四个 enclave。单个 enclave 需要 EPM
和 UTM entry，而平台固定保护区已经占用多数 entry。四路同时创建首先
测试到的是 PMP 容量上限，不是正常 enclave 调度能力。

### 4.5 多 hart PMP 更新发生死锁和整板卡死

#### 问题

Keystone 改变 enclave 内存权限时，必须让所有 hart 同步更新 PMP。早期
适配用一个全局 spinlock、一个共享命令和一个全局完成计数器。一个 hart
在 M-mode 持锁等待远端确认时，另一个 hart 可能也进入 PMP 操作并等待
同一把锁，无法处理前一个 hart 的 IPI，形成 AB/BA 死锁。

表现包括：

- `watchdog: hard LOCKUP`；
- RCU stall；
- SSH、网络和系统服务失去响应；
- Linux timeout 无法终止任务，因为 hart 卡在 M-mode。

#### 第一阶段解决：per-hart FIFO

参考 OpenSBI 自身 TLB IPI 设计，为每个 hart 建立 PMP 请求 FIFO：

- 命令复制到目标 hart 队列，避免共享可变命令；
- 完成计数保存在源 hart scratch；
- hart 等待远端确认时也处理自己的入站 PMP 请求；
- 移除全局 PMP IPI spinlock。

对应补丁：`0009-keystone-p550-queue-pmp-ipi.patch`。

#### 第二阶段解决：丢失 IPI 的定向重触发

硬件测试仍观察到顺序运行数百次后偶发锁死。故障模型是目标 FIFO 和
OpenSBI event bit 仍然存在，但 EIC7700 机器软件中断没有被目标 hart
处理，源 hart 因等待 PMP acknowledgement 永久停留在 M-mode。

最终增加平台恢复路径：等待超过 10 ms 后检查各目标 hart 的 PMP FIFO，
只对仍有排队请求的目标 hart 重新触发 raw IPI。PMP 操作仍由 OpenSBI
正常 event handler 执行，不会重复执行一条已经完成的 PMP 命令。UART
可输出限速诊断标记：

```text
[KS-P550-PMP-IPI-RETRY]
```

对应补丁：`0010-keystone-p550-retrigger-stalled-pmp-ipi.patch`。

这里的 10 ms 是 M-mode 中仅在未完成 PMP 请求存在时使用的丢失中断
检测阈值，不是 SDK 的调度延时。我们没有保留曾用于诊断的 userspace
1 ms sleep；SDK 的 RUN/RESUME 行为保持 Keystone 原实现。

### 4.6 Enclave 首次入口和中断恢复错误

#### 问题

CREATE 和 RUN 可能发生在不同 hart。旧路径对 entry PC 使用了历史性的
`-4/+4` 补偿，并假定 trap 退出不返回。在 OpenSBI 1.6 上会造成入口 PC
错误、host 指令被跳过或 timer interrupt 后立刻再次 trap。

#### 解决

- 对首次入口地址使用显式内存可见性屏障；
- 将精确 entry PC 交给 OpenSBI trap context；
- 只在 RUN 尚未切换到 enclave 且发生失败时推进 host ecall PC；
- timer/software interrupt 只在 host context 已恢复后发布。

相关补丁：`0006` 和 `0007`。

### 4.7 官方 test-fib-bench 在 rdcycle 上循环 fault

#### 问题

P550 Ubuntu 默认禁止普通用户态执行 `rdcycle`。如果直接复制 host 的
`scounteren` 到 enclave，官方 `test-fib-bench` 会在第一次 `rdcycle`
时不断 trap。

#### 解决

只在独立保存的 enclave S-mode CSR context 中启用 `scounteren.CY`，退出
enclave 时恢复 Linux 原值。这样不改变 Ubuntu 用户态的 counter 策略，
同时保持官方测试程序不修改即可运行。

对应补丁：`0008-keystone-p550-enable-enclave-cycle-counter.patch`。

### 4.8 Linux 驱动 finalize 失败后的悬空对象

#### 问题

VF2 driver 在 `FINALIZE_ENCLAVE` 的 SBI create 失败后立即释放 enclave
对象，但 IDR 和 `file->private_data` 仍指向该对象。用户态随后执行正常
DESTROY 清理时会再次访问已经释放的对象，并向 SM 发送无效 enclave ID，
表现为重复的错误码 `100005` 和 `invalid enclave id`。

#### 解决

finalize 失败时保留部分初始化对象，让正常 DESTROY ioctl 或文件
`release()` 统一从 IDR 删除对象并释放 EPM/UTM。对应补丁：

```text
scripts/patches/keystone-vf2-driver-finalize-cleanup.patch
```

driver 始终针对开发板正在运行的精确内核 headers 构建。payload installer
也只把模块安装到 `/lib/modules/$(uname -r)/extra/`。

### 4.9 Ubuntu GCC 13、CMake、PIE 与 freestanding 二进制

#### 问题

VF2 SDK/examples 在 Ubuntu 24.04 GCC 13 环境中出现多类构建或运行问题：

- 公共 ABI header 缺少标准整数和大小类型声明；
- Eyrie 嵌套 CMake flags 被错误拆分或包含字面引号；
- Ubuntu 默认 PIE、stack protector 和 build-ID 不适合 freestanding
  loader/runtime；
- loader 出现 GOT 依赖；
- runtime ELF entry 与第一个 load address 不一致；
- `hello-native` 和 attestation 缺少适合 P550 的明确入口或内存参数。

#### 解决

所有调整只应用到 `artifacts/build-p550` 下的可丢弃源码副本，不直接
修改锁定的 Keystone checkout：

- `keystone-vf2-sdk-stdint.patch`；
- `keystone-vf2-sdk-eyrie-cmake-flags.patch`；
- `keystone-vf2-sdk-eyrie-nopie.patch`；
- `keystone-vf2-examples-native-gcc.patch`；
- `keystone-vf2-examples-p550.patch`。

构建脚本还检查 GOT、GNU build-ID、ELF entry 和 load address，发现不安全
结果时直接停止，而不是把可能首次取指 fault 的文件打进 payload。

### 4.10 Attestation 参考 SM 必须与 bootchain 完全一致

#### 问题

attestation example 需要比较预期 SM measurement。只更新 bootloader 而
继续使用旧 payload，会让 `attestor.ke` 内嵌的 `fw_payload.bin` 与实际
OpenSBI/SM 不匹配。

#### 解决

- bootchain 同时输出 `bootloader_ddr5_secboot.bin`、`fw_payload.bin` 和
  `bootchain-manifest.txt`；
- payload 构建时把精确的 `fw_payload.bin` 打入 `attestor.ke`；
- `PAYLOAD-MANIFEST.txt` 记录 SM reference SHA-256；
- flash bundle 强制要求三个 bootchain 文件位于同一目录；
- GitHub Release 脚本用 `hardware-validation.txt` 再次核对三项核心制品。

当前 attestation 使用 Keystone 公开测试 key 和测试随机源，只能验证
签名/measurement/nonce 数据流，不能作为生产设备身份或 root of trust。

### 4.11 merged-/usr 安装和 examples 路径

#### 问题

Ubuntu 24.04 的 `/lib` 是指向 `/usr/lib` 的符号链接。直接把合成 rootfs
复制到 `/` 会尝试用目录覆盖 `/lib`，导致安装失败。早期还误用了单数
目录 `/usr/share/keystone/example/`。

#### 解决

installer 分别安装内核模块、modules-load 配置和 `/usr/share/keystone`
内容，不整体覆盖根目录。所有官方示例统一放在：

```text
/usr/share/keystone/examples/
```

其中包括 `hello.ke`、`hello-native.ke`、`attestor.ke` 和 `tests.ke`。

### 4.12 开发板无网络、系统时间和构建环境问题

#### 问题

- P550 没有网络，不能直接 apt 安装依赖；
- Ubuntu 镜像的 RTC/系统时间可能落后于源码时间，导致 clock-skew；
- Ubuntu 18.04 和 22.04 的包名不同，例如 `lz4`/`liblz4-tool`；
- Windows/共享文件系统可能丢失 Git executable bit；
- DNS 或 GitHub 中断会留下不完整 BitBake/Git 下载缓存。

#### 解决

- 在 P550 生成离线依赖请求，在联网 Ubuntu 主机下载对应 `riscv64`
  deb，再回到板上离线安装；
- 固定 Ubuntu archive snapshot，避免旧版本包从在线镜像消失；
- 构建前检查并修正系统时间；
- `restore-source-modes.sh` 根据 Git index 恢复可执行权限；
- 所有源码固定 commit，并由 `verify-sources.sh` 检查；
- 构建和下载缓存均可恢复，不要求失败后从头开始。

## 5. 被否定或限制使用的方案

### 5.1 原封不动复制 VisionFive 2 系统

不可行。VF2 和 P550 的 SoC、hart 数量、PMP 布局、OpenSBI ABI、内存图和
启动链不同。VF2 只作为 Keystone 组件组合和代码路径参考。

### 5.2 只替换 Linux 或只安装 keystone-driver.ko

不可行。Keystone SM 必须位于实际启动的 M-mode OpenSBI 中。

### 5.3 在 SDK resume 循环中加入 1 ms sleep

未保留。它可能降低故障概率，但会改变官方执行行为、增加延迟并掩盖
firmware 中断问题。最终修复放在 OpenSBI/PMP IPI 路径。

### 5.4 用四个并发 enclave 创建者验证四核

不作为正常稳定性测试。P550 只有八个 PMP entry，并发四个 enclave 会
首先耗尽固定 PMP region。四核验证采用在每个 CPU 上分别运行官方示例，
以及跨 CPU 的顺序重复 create/run/destroy。

### 5.5 为了 Keystone 重建整个 Ubuntu 桌面系统

没有必要。官方 Ubuntu rootfs 可以保持不变；安全边界相关部分是
bootchain、内核驱动和匹配 payload。

## 6. 最终验证结果

硬件验证日期：2026-08-23。

验证环境：

```text
board=hifive-premier-p550
architecture=riscv64
kernel=6.12.33-1-premier
cpus=4
```

通过项目：

- `/dev/keystone_enclave` 正常创建；
- `hello.ke` 和 `hello-native.ke` 在四个 CPU 上分别成功；
- attestation signature、SM/enclave measurement 和 nonce 成功；
- `tests.ke` 中九个官方测试全部成功；
- `hello.ke` 跨 CPU 顺序运行 1000 次成功；
- 测试期间未匹配到 bus error、watchdog lockup、RCU stall、invalid EID
  或 SBI trap error。

核心制品 SHA-256：

```text
bootloader_ddr5_secboot.bin
b59e492d8951ea9aa1beafd171d1f61b298e5b1eaaedf4243b7987188d9df65c

fw_payload.bin
1cda3ad4cbeecd8ba4682b471ac78b6fd1e1bad1b79822d7caf6d44884d88d51

keystone-p550-payload.tar.zst
e170549877cec30743c6fda7b6b5aebbea7cd574eb4d0623faaa24a430c5c9d9
```

Linux `dmesg` 无法保存 OpenSBI 的全部 UART 输出，因此本次记录没有证明
1000 次测试中一定实际触发过 `[KS-P550-PMP-IPI-RETRY]`。测试结果证明新
bootchain 在此前可复现故障边界之外保持运行，但平台恢复路径是否被触发
仍应在后续 release 的完整 UART 日志中记录。

## 7. 当前部署模型

### 维护者

1. 在 x86_64 Ubuntu 编译机生成 bootchain；
2. 在一块运行精确官方内核的 P550 上生成 payload；
3. 烧录并完成硬件验证；
4. 发布 bootloader、SM reference、payload、manifests 和 checksums。

### 相同开发板和系统的使用者

如果目标也是 HiFive Premier P550，并运行相同 Ubuntu 发布和
`6.12.33-1-premier` 内核，不修改 Keystone 底层源码，就不需要再次在
P550 上编译 payload。直接烧录已验证 bootloader/Ubuntu 镜像并安装发布的
payload 即可。

只有改变内核、Keystone revision、SM ABI、driver、SDK、runtime 或
examples 时，才需要重新构建并验证匹配的一组制品。

## 8. 仍未覆盖的生产安全工作

当前结果是功能性开发移植，不是生产安全认证。后续仍需要：

- P550 设备唯一 root key 的安全注入和存储；
- 硬件真随机源及失败处理；
- secure boot key、固件签名和回滚策略审计；
- PMP、IOMMU/DMA、缓存一致性和物理攻击面的独立安全评审；
- 多块开发板、冷启动、热重启、长时间负载和异常注入验证；
- 将 P550/OpenSBI 平台补丁整理后提交上游评审。

## 9. 关键项目文件

```text
README.md
PORTING-REPORT.md
docs/FLASHING.md
docs/PORTING.md
docs/VALIDATION.md
docs/RELEASING.md
kas/p550-keystone.yml
meta-keystone-p550/recipes-bsp/opensbi/
scripts/build-keystone-bootchain.sh
scripts/build-keystone-payload-on-board.sh
scripts/validate-keystone-on-board.sh
prepare-flash-assets.sh
publish-github.sh
publish-release-assets.sh
```

README 提供构建和部署入口；本文解释移植决策和故障原因；`docs/` 下的
文件分别给出烧录、验证和发布细节。
