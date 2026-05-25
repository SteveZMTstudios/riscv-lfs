# 从零开始构建 RISC-V 64 Linux (LFS 13.0-systemd)

这是一个从零开始构建的 **riscv64** Linux 系统，符合 [LFS 13.0-systemd](https://www.linuxfromscratch.org/lfs/view/13.0-systemd/) 标准，并参考了 [CLFS-ng](https://www.linuxfromscratch.org/~xry111/lfs/view/clfs-ng-systemd/) 作为架构指导。此外，还添加了 BLFS 扩展以改善日常用户体验。

**作者：** [SteveZMTstudios](https://github.com/SteveZMTstudios)

**完整版本可在[发布版本](https://github.com/SteveZMTstudios/riscv-lfs/releases)中找到。** 

完整构建日志：[`stevezmt.log`](stevezmt.log)
> 这份日志可能非常冗长且包含大量编译输出，并且特别混乱，前后段落混乱并夹杂着意味不明的低语，但它确实是从零开始构建整个系统的完整记录，包含了所有的错误、警告。对于想要深入了解构建过程细节的人来说，这份日志可能会非常有价值，但是，您不应该完整地遵循所有步骤，因为其中包含了许多错误和反复试验的痕迹。相反，您应该参考下方的说明，并在构建过程中遇到问题时回顾日志以寻找线索。  
> 
> 总之，如果您计划查阅此日志，后果自负。

---

## 系统要求

| 系统要求 | 说明 |
|:--|:--|
| **主机** | Linux x86_64 |
| **QEMU** | ≥8.0（系统模式 + 用户模式） |
| **可用空间** | ≥30 GB（WSL2 ext4 分区，不允许使用 NTFS 挂载点） |
| **预计时间** |初学者大约需要 3-7 天（主要是编译等待时间）|
| **耐心** | 至少需要重启 2-3 次 |

---

## 4 个关键参考资料（请在浏览器中打开）

1. **[LFS 13.0-systemd](https://www.linuxfromscratch.org/lfs/view/13.0-systemd/)** - 主要手册。大约 80% 的步骤都在这里描述。
    > 也许您也需要它的[中文翻译](https://lfs.xry111.site/zh_CN/13.0-systemd/index.html)。
2. **[CLFS-ng](https://www.linuxfromscratch.org/~xry111/lfs/view/clfs-ng-systemd/)** — 跨架构编译的官方来源。如果您遇到与 `ARCH` 相关的问题，请参考此文档。

3. **[purofle/riscv-lfs](https://github.com/purofle/riscv-lfs)** — RISC-V 特化技术（QEMU 补丁、Flex `--build` 参数等）

4. **[BLFS 13.0-systemd](https://www.linuxfromscratch.org/blfs/view/13.0-systemd/)** — LFS 扩展包。

> **绝对不要搜索中文教程。** CSDN/php.cn 上的大部分“教程”都是 AI 生成的，版本、命令和设置都是错误的。无论您使用什么搜索引擎。请使用英文在 Google 上搜索。

--

## 步骤 0：启动前必须做的三件重要事情

### ① 您的工作目录必须位于 Linux 原生文件系统上。

在 WSL2 中，使用 `/opt/clfs`。

```bash

sudo mkdir -pv /opt/clfs
export LFS=/opt/clfs
```

### ② 设置正确的环境变量

```bash

export LFS=/opt/clfs
export LFS_TGT=riscv64-lfs-linux-gnu
export PATH=$LFS/cross-tools/bin:$LFS/tools/bin:/usr/bin
export MAKEFLAGS="-j$(nproc)"

```

**注意：`LFS_TGT=riscv64-lfs-linux-gnu` 不是 `riscv64-unknown-linux-gnu`。**

### ③ 预先下载所有源代码并检查版本

使用官方 LFS。使用 wget-list 下载。避免随意下载“最新版本”。每个软件包版本都经过特定组合的测试。更改版本可能会导致一系列连锁错误。

对于首次使用的用户，请先下载所有源代码，**切勿以任何方式对其进行更新**。将下载的源代码集中到一个目录中，并在开始构建之前验证版本和校验和是否正确。

### ④ 准备好QEMU环境

若您使用 Windows 作为主机，您可以直接下载[来自 Stefan Weil 的二进制组件](https://www.qemu.org/download/#windows)。

若您使用 Linux 作为主机，且您的发行版的软件源中没有提供足够新的 QEMU 版本，您可以拉取[官方源代码](https://www.qemu.org/download/#source)编译安装。

stevezmt.log 中包含了我编译 QEMU 11 的日志。


---

## 三个阶段概述

```
第一阶段（第五章）：在主机上构建交叉编译器
Binutils pass1 → GCC pass1 → Linux Header → Glibc → GCC pass2
输出：x86_64→riscv64 交叉编译器已构建在 $LFS/cross-tools/ 目录中

第二阶段（第六至七章）：使用交叉编译器构建临时系统
使用 QEMU 用户模式 ​​chroot 环境和 binfmt_misc 构建基本工具
输出：一个可运行的 riscv64 工具链已构建在 $LFS/tools/ 目录中

第三阶段（第八章）：在 chroot 环境中构建最终系统
软件包已完全安装到 /usr 目录中
输出：可引导的根文件系统
```

---

## 各阶段说明

### 重要提示

1. **NTFS 对 LFS 构建有害** — `/mnt/e/...` 1. 在 (WSL2 9P/NTFS 桥接) 上编译 Glibc 时，100% 会失败，并出现错误信息“未定义对 __lll_lock_wake_private 的引用”。解决方法：将所有内容迁移到 WSL2 原生 ext4 文件系统下的 `/opt/clfs` 目录。您不应在构建时使用任何 NTFS 挂载点。

2. **WSL binfmt_misc 进程随机终止** — QEMU 用户模式进程会被 WSLInterop 终止，且不记录日志。如果您遇到了`Exec format error`，您需要在主机上运行命令 `sudo systemctl restart systemd-binfmt`。

- 实际上，建议在主机上安装完整的 Linux 发行版（例如 Fedora），以保持稳定性和高性能。

3. **在 riscv64 架构上，Meson 默认使用 `/usr/lib64` 目录。** — Kmod、Systemd 和 D-Bus 会将库安装到 `/usr/lib/` 而不是 `/usr/lib64/`。解决方法：向 meson 传递 `--libdir=lib` 参数。

4. **Linux 内核架构是 `riscv`，而不是 `riscv64`。** — 在 glibc 头文件阶段环境变量泄漏会导致构建失败。在构建内核之前，务必运行 `unset ARCH`。

5. **安装每个 `.so` 文件后，必须运行 `ldconfig` 函数。** — 缺少对 `ldconfig` 的调用将导致 Python 无法导入 `_ctypes`、`_ssl` 和 `_sqlite3`，并在后续引发一系列意想不到的问题。


### Stage 1

一些常用的命令，构建头我登记在[.env](.env)里了，您可能想要在构建过程中打开它以便复制粘贴。

| 坑 | 解 |
|:--|:--|
| Binutils pass1：`--target=$LFS_TGT` **不是** `--target=riscv64-linux-gnu` | 严格用 `$LFS_TGT` |
| GCC pass1 需要 GMP/MPFR/MPC 源码放在 gcc 目录内 | `tar -xf gmp-*.tar.xz && mv gmp-* gmp`（同理 mpfr, mpc） |
| Linux headers：`make ARCH=riscv64 headers` | 这里是 `riscv64`，不是 `riscv` |
| Glibc：必须在 ext4 上构建 | 参考步骤 0 第 ① 条 |

### Stage 2

| 坑 | 解 |
|:--|:--|
| 进入 chroot 前确保 binfmt_misc 在线 | `cat /proc/sys/fs/binfmt_misc/qemu-riscv64` 应显示 `enabled` |
| chroot 命令的关键参数 | `chroot "$LFS" /usr/bin/env -i HOME=/root TERM="$TERM" PATH=/usr/bin:/usr/sbin /bin/bash --login +h` |
| Flex 可能报 `cannot guess build type` | `./configure --build=riscv64-unknown-linux-gnu` |
| 每个 `.so` 安装后跑 `ldconfig` | 忘记 = Python 等后续包编译失败 |

假若您很不幸，在运行一个构建时遇到了 `Exec format error`，请立刻`^C`，在主机上运行命令 `sudo systemctl restart systemd-binfmt` 来重启 binfmt_misc 服务，然后，重新开始您中断的构建单元。

### Stage 3

| 坑 | 解 |
|:--|:--|
| Meson 包（Kmod, Systemd, D-Bus）会把库装到 `/usr/lib64/` | 传 `--libdir=lib` |
| Coreutils 的 `check-root` 需要 `tester` 用户 | 提前创建 |
| `make check` 在 QEMU 下极慢 | 后台跑 `nohup make check &`，同时继续安装下个包 |
| Git 需要 curl → 需要 make-ca → 需要 p11-kit → 需要 libtasn1 | 按依赖顺序构建 |
| Python 的 `_ctypes`/`_ssl` 模块导入失败 | 在 OpenSSL / Libffi 安装后跑 `ldconfig`，再重编 Python |

另外，我的rootfs里的`/root/testpkg.sh`和[testpkg.sh](testpkg.sh)里保留了在chroot环境下测试安装系统关键组件的检查，验收和烟雾测试脚本，可以在构建chroot时运行它来验证系统的完整性。

在13.0-systemd的文档上，应当pass everything。

---

## QEMU 启动命令

```powershell
qemu-system-riscv64.exe `
  -machine virt `
  -cpu rv64 `
  -smp 4 `
  -accel tcg,thread=multi `
  -m 3G `
  -kernel .\boot\vmlinuz-6.18.10-lfs-13.0-systemd `
  -append "root=/dev/vda1 rw console=ttyS0" `
  -drive file=riscv64-lfs.img,format=raw,if=none,id=hd `
  -device virtio-blk-device,drive=hd `
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:22222-:22 `
  -device virtio-net-device,netdev=net0 `
  -nographic
```

Login: `root` / `000000`  SSH: `ssh -p 22222 root@localhost`

---

## 我们的版本快照 (LFS 13.0-systemd)

| 组件 | 版本 |
|:--|:--|
| GCC | 15.2.0 |
| Binutils | 2.46.0 |
| glibc | 2.43 |
| Linux | 6.18.10 |
| systemd | 259.1 |
| OpenSSL | 3.6.1 |
| Python | 3.14.3 |

BLFS 扩展：OpenSSH 10.2p1, Git 2.53.0, wget 1.25.0, curl 8.18.0, cmake 4.2.3, fastfetch 2.47.0, dhcpcd 10.2.2, screen 5.0.1, tmux 3.5a, lynx 2.9.2, net-tools 2.10, btop++ 1.4.7, make-ca 1.16.1

# 鸣谢
- [purofle/riscv-lfs](https://github.com/purofle/riscv-lfs)
- [xry111](https://xry111.site/) 的 LFS 和 CLFS-ng 文档