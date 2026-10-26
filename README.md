<img src="https://avatars.githubusercontent.com/u/53193414?s=200&v=4" alt="logo" width="200" height="200" align="right">

# ImmortalWrt 项目

ImmortalWrt 是 [OpenWrt](https://openwrt.org) 的分支，移植了更多软件包、支持更多设备，并为中国大陆用户默认启用了优化配置与本地化修改。<br/>
与上游相比，本项目允许使用（无法合入上游的）修改与 hack，以提供更好的功能、性能与支持。

默认登录地址：http://192.168.1.1 或 http://immortalwrt.lan，用户名 `root`，密码为空。

本仓库是 [immortalwrt/immortalwrt](https://github.com/immortalwrt/immortalwrt) 的个人 fork，在跟随上游的基础上，额外维护部分机型的构建配置与本地编译方案。

## 分支说明

| 分支 | 基础版本 | 说明 |
| --- | --- | --- |
| `master` | 上游 master | 跟随上游主线快照 |
| `24.10.6` | ImmortalWrt v24.10.6 | 维护 CMCC RAX3000M、Xiaomi AX3000T 的按机型拆分构建配置（`rax3000m.config`、`ax3000t.config`）与本地编译方案（`docs/`） |
| `25.12.2` | ImmortalWrt v25.12.2 | 跟随上游 v25.12.2，仅调整部分配置默认值 |

## 下载

预编译固件覆盖多种架构，并附带可用于 WiFi 家用路由的软件包选择。要从厂商原厂固件迁移到 ImmortalWrt，可在固件选择器中按机型查找可用的 factory 镜像。

- [ImmortalWrt 固件选择器](https://firmware-selector.immortalwrt.org/)

如果设备受支持，请点击 **Info** 链接查看安装说明，或参考下方支持资源。

## 本地编译

编译固件需要 GNU/Linux、BSD 或 macOS 系统（文件系统必须区分大小写）；不支持 Cygwin（文件系统不区分大小写）。<br/>

### 环境要求

推荐使用 Debian 11，AMD64 架构 CPU，至少 4 GB 内存和 25 GB 可用磁盘空间，并能访问互联网。

依赖安装方式二选一：

- 方式一：使用官方初始化脚本（会替换 apt 源、升级系统并安装全部编译依赖）：

  ```bash
  sudo bash -c 'bash <(curl -s https://build-scripts.immortalwrt.org/init_build_environment.sh)'
  ```

- 方式二：手动安装（Debian/Ubuntu）：

  ```bash
  sudo apt update -y
  sudo apt full-upgrade -y
  sudo apt install -y ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential \
    bzip2 ccache clang cmake cpio curl device-tree-compiler ecj fastjar flex gawk gettext gcc-multilib \
    g++-multilib git gnutls-dev gperf haveged help2man intltool lib32gcc-s1 libc6-dev-i386 libelf-dev \
    libglib2.0-dev libgmp3-dev libltdl-dev libmpc-dev libmpfr-dev libncurses-dev libpython3-dev \
    libreadline-dev libssl-dev libtool libyaml-dev libz-dev lld llvm lrzsz mkisofs msmtp nano \
    ninja-build p7zip p7zip-full patch pkgconf python3 python3-pip python3-ply python3-docutils \
    python3-pyelftools qemu-utils re2c rsync scons squashfs-tools subversion swig texinfo uglifyjs \
    upx-ucl unzip vim wget xmlto xxd zlib1g-dev zstd
  ```

注意：

- 编译时必须使用普通用户，不能用 root，也不要加 sudo。
- PATH 和工作目录不能包含空格或非 ASCII 字符。
- 使用 WSL 时，需要从 PATH 中移除 Windows 目录，参见 [Build system setup WSL](https://openwrt.org/docs/guide-developer/build-system/wsl)。
- 不建议使用 macOS 作为宿主系统。
- 更多说明参见 [Build system setup](https://openwrt.org/docs/guide-developer/build-system/install-buildsystem)。

### 本地编译方案（OPDE 容器）

`docs/` 目录提供一套基于 WSL2 + Docker 的本地编译方案，使用 `immortalwrt/opde:base` 镜像（Ubuntu 20.04 构建环境），无需在宿主机安装全套编译依赖：

| 文件 | 作用 |
| --- | --- |
| [`docs/opde-compose.yaml`](docs/opde-compose.yaml) | 容器定义：挂载脚本、源码与 ccache 目录 |
| [`docs/opde_init.sh`](docs/opde_init.sh) | 容器首次创建后的环境初始化（逐项确认，可跳过） |
| [`docs/build-firmware.sh`](docs/build-firmware.sh) | 交互式本地编译助手（运行在容器内） |
| [`docs/2026-10-20-固件构建配置说明.md`](docs/2026-10-20-固件构建配置说明.md) | 按机型 seed 的构建步骤与维护约定 |

1. 启动容器（compose 文件名非默认，需用 `-f` 指定）：

   ```bash
   docker compose -f docs/opde-compose.yaml up -d
   ```

   compose 默认把宿主机的 `~/opde-docker/opde`、`~/opde-docker/immortalwrt-src`、`~/opde-docker/immortalwrt-ccache` 分别挂载到容器内的 `/home/opde/opde`、`/home/opde/workdir`、`/home/opde/.ccache`，请按实际路径调整。宿主机挂载目录的属主需与容器内 `opde` 用户（UID/GID 1000）一致，否则源码和 ccache 无法写入。

2. 首次创建容器后初始化（容器内以 `opde` 用户执行）：

   ```bash
   docker exec -it opde-builder bash
   bash /home/opde/opde/opde_init.sh
   ```

   脚本会逐项询问并执行：官方构建依赖安装、apt/pip/npm 国内镜像、quilt、Git 传输参数、`MAKEFLAGS` 与自动进入工作目录。非交互终端会直接报错退出。

3. 在容器内运行交互式编译助手：

   ```bash
   docker exec -it opde-builder bash
   /home/opde/opde/build-firmware.sh
   ```

   脚本按提示输入源码目录（默认为 `/home/opde/workdir`）和配置文件（源码根目录唯一的 `*.config` 会自动选中），再选择编译场景。菜单覆盖清理（`make clean` / `dirclean` / `distclean`）、feeds 更新、`.config` 套用、单包清理、内核重编、APP 增删、任务队列查看、状态与日志、第三方包清单维护；选中后展示执行计划并一次跑完。

   脚本必须放在源码树之外（默认 `/home/opde/opde`），日志固定写入同目录 `build-logs/build.log`（每次执行前清空），`.config` 备份写入 `config-backups/`。套用配置后，脚本会写入 `CONFIG_DEVEL=y`、`CONFIG_CCACHE=y` 和 `CONFIG_CCACHE_DIR`，并校验 `feeds.conf` 中固定的提交与 `feeds/` 实际 HEAD 是否一致。

### 手动编译步骤

不使用交互式助手时，可在源码树内直接执行：

```bash
./scripts/feeds update -a
./scripts/feeds install -a

# 仅在 24.10.6 分支：套用按机型拆分的 seed 配置（二选一）
cp rax3000m.config .config      # CMCC RAX3000M
# cp ax3000t.config .config     # Xiaomi AX3000T

make defconfig
make download -j8
make -j$(nproc) V=s
```

产物位于 `bin/targets/mediatek/filogic/`。切换机型时重新执行 `cp <配置> .config && make defconfig`。也可以执行 `make menuconfig` 手动选择目标平台、工具链与软件包。

两份 seed 配置默认开启 ccache（`CONFIG_CCACHE=y`），缓存位于源码根目录 `.ccache`；首次编译不会加速，重复编译或切换机型时生效。OPDE 方案把 ccache 挂载到宿主机，便于长期复用。`rules.mk` 只读取 `.config` 中的 `CONFIG_CCACHE_DIR`，环境变量会被覆盖，因此由 `build-firmware.sh` 负责写入。

### 配置维护约定

- 只手动维护“目标设备 / 镜像 / 应用 / 编译工具”四类选项；内核、BusyBox、依赖包、工具链由 `make defconfig` 自动补齐。
- 所有应用及其专属编译选项集中在配置文件的“四、应用及其依赖”一节，应用专属开关紧跟所属应用。
- 新增应用后只提交 seed 配置，不要提交 menuconfig 全量输出。
- 应用的中文翻译包必须显式写在该应用下方（`CONFIG_PACKAGE_luci-i18n-<应用>-zh-cn=y`；OpenClash 主包已内置翻译）；`CONFIG_LUCI_LANG_zh_Hans` 只选择基础翻译，不会自动带入应用翻译。
- `=y` 表示编译并预装进固件；`=m` 表示只编译 ipk、不预装，刷机后需手动安装。
- 单设备构建必须保留 `# CONFIG_TARGET_MULTI_PROFILE is not set`，并使用 `CONFIG_TARGET_mediatek_filogic_DEVICE_<机型>=y`。
- 第三方 feed 由编译仓库（[ImmortalWrt-firmware-build](https://github.com/DenzelVincent/ImmortalWrt-firmware-build)）统一追加，源码仓库的 `feeds.conf.default` 只保留默认 feed。
- 详细说明见 [`docs/2026-10-20-固件构建配置说明.md`](docs/2026-10-20-固件构建配置说明.md)。

## 相关仓库

主仓库通过多个子仓库管理不同类别的软件包，所有软件包都通过 OpenWrt 的包管理器 opkg 安装。如需开发 Web 界面或移植软件包，可查看以下仓库：

- [LuCI Web 界面](https://github.com/immortalwrt/luci)：现代化、模块化的 Web 管理界面。
- [ImmortalWrt Packages](https://github.com/immortalwrt/packages)：移植软件包的社区仓库。
- [OpenWrt Routing](https://github.com/openwrt/routing)：(mesh) 路由相关软件包。
- [OpenWrt Video](https://github.com/openwrt/video)：显示服务器与客户端相关软件包（Xorg 与 Wayland）。

## 支持信息

支持的设备列表见 [OpenWrt 硬件数据库](https://openwrt.org/supported_devices)。

### 文档

- [快速入门](https://openwrt.org/docs/guide-quick-start/start)
- [用户指南](https://openwrt.org/docs/guide-user/start)
- [开发者文档](https://openwrt.org/docs/guide-developer/start)
- [技术参考](https://openwrt.org/docs/techref/start)

### 支持社区

- Telegram 群组：[@ctcgfw_openwrt_discuss](https://t.me/ctcgfw_openwrt_discuss)
- Matrix 群组：[#immortalwrt](https://matrix.to/#/#immortalwrt:matrix.org)

## 许可证

ImmortalWrt 基于 [GPL-2.0-only](https://spdx.org/licenses/GPL-2.0-only.html) 许可证授权。

## 致谢

<table>
  <tr>
    <td><a href="https://dlercloud.com/"><img src="https://user-images.githubusercontent.com/22235437/111103249-f9ec6e00-8588-11eb-9bfc-67cc55574555.png" width="183" height="52" border="0" alt="Dler Cloud"></a></td>
    <td><a href="https://www.jetbrains.com/"><img src="https://resources.jetbrains.com/storage/products/company/brand/logos/jb_square.png" width="120" height="120" border="0" alt="JetBrains Black Box Logo logo"></a></td>
    <td><a href="https://sourceforge.net/"><img src="https://sourceforge.net/sflogo.php?type=17&group_id=3663829" alt="SourceForge" width=200></a></td>
  </tr>
</table>
