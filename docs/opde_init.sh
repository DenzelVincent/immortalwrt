#!/bin/bash
# ImmortalWrt OPDE 容器国内环境初始化脚本
# 与 compose 启动分离：容器首次创建后手动执行一次，可重复执行
# 用法（容器内，opde 用户）：bash /home/opde/opde/opde_init.sh
# 每个步骤执行前询问，回车执行，输入 n 跳过
set -e

if [ "$(id -u)" -eq 0 ]; then
    echo "请用 opde 用户执行，不要用 root" >&2
    exit 1
fi

if [ ! -t 0 ]; then
    echo "没有交互终端，确认项无法输入；请用 docker exec -it 运行本脚本" >&2
    exit 1
fi

confirm() {
    local reply
    # 非交互环境（stdin 不可读）默认跳过，避免误执行
    read -r -p "$1 [Y/n] " reply || reply="n"
    case "$reply" in
        [nN]*) return 1 ;;
        *) return 0 ;;
    esac
}

echo "==================== 1. 安装 ImmortalWrt 官方构建依赖 ===================="
if confirm "是否运行 ImmortalWrt 官方环境初始化脚本（替换 apt 源、升级系统并安装全部编译依赖）？"; then
    # 官方脚本会重写 apt 源并 full-upgrade，需 root 执行；swig/ccache/node/yarn 等依赖由它统一安装
    sudo bash -c 'bash <(curl -s https://build-scripts.immortalwrt.org/init_build_environment.sh)'
else
    echo "已跳过"
fi

echo "==================== 2. 替换 apt 源为阿里云源 ===================="
# 上一步已把源改成腾讯镜像，这里改了不生效；仅在跳过上一步时用于换源
if confirm "是否替换 apt 源并更新索引？"; then
    if [ ! -f /etc/apt/sources.list.bak ]; then
        sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
    fi
    sudo sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g; s/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list
    sudo apt update
else
    echo "已跳过"
fi

echo "==================== 3. 安装/确认 quilt（补丁管理） ===================="
if command -v quilt &> /dev/null; then
    echo "quilt 已存在: $(quilt --version)"
elif confirm "未检测到 quilt，是否安装？"; then
    sudo apt install -y quilt
else
    echo "已跳过"
fi

echo "==================== 4. Git 全局配置 ===================="
if confirm "是否配置 Git 传输参数（压缩与 postBuffer）？"; then
    # 不再配置 github 镜像 rewrite：第三方镜像经常 TLS 失败，直连 GitHub 已验证可用
    git config --global core.compression 9
    git config --global http.postBuffer 524288000
else
    echo "已跳过"
fi

echo "==================== 5. pip 换国内源（feeds 内 python 包） ===================="
if confirm "是否写入 pip 国内源配置？"; then
    mkdir -p ~/.pip
    cat > ~/.pip/pip.conf <<EOF
[global]
index-url = https://mirrors.aliyun.com/pypi/simple
trusted-host = mirrors.aliyun.com
EOF
else
    echo "已跳过"
fi

echo "==================== 6. npm 换国内源（编译 luci 前端） ===================="
if ! command -v npm &> /dev/null; then
    echo "未安装 npm，跳过"
elif confirm "是否把 npm registry 切换到国内源？"; then
    # 用户级配置，避免 --global 的 EACCES
    npm config set registry https://registry.npmmirror.com
else
    echo "已跳过"
fi

echo "==================== 7. 编译环境小优化 ===================="
if confirm "是否写入 .bashrc 优化项（MAKEFLAGS 与自动进入工作目录）？"; then
    # .bashrc 追加做去重，重复执行不会叠加
    if ! grep -q 'MAKEFLAGS=-j' ~/.bashrc 2> /dev/null; then
        echo "export MAKEFLAGS=-j$(nproc)" >> ~/.bashrc
    fi
    if ! grep -q 'cd /home/opde/workdir' ~/.bashrc 2> /dev/null; then
        echo "cd /home/opde/workdir" >> ~/.bashrc
    fi
else
    echo "已跳过"
fi

echo "==================== 初始化结束 ===================="
echo "执行 source ~/.bashrc 使配置生效，然后即可开始编译"
