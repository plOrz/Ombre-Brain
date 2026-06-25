#!/bin/sh
# entrypoint.sh — 容器启动入口
#
# 职责：确保 config 文件是一个可用的文件再启动服务。
# 不做其他事（不改业务逻辑）。
#
# 问题背景（Windows/WSL2 fresh install 崩溃重启）：
#   旧 compose 用单文件 bind mount `./config.yaml:/app/config.yaml`。若宿主
#   ./config.yaml 不存在，Docker（尤其 Windows/WSL2）会把它当成目录创建并挂进来，
#   /app/config.yaml 于是是个**目录**而非文件，应用读它直接 IsADirectoryError 崩溃。
#   更糟的是：bind mount 的挂载点在容器内**删不掉**（rm 报 "Device or resource busy"），
#   所以靠 entrypoint `rm` 自救是行不通的 —— 根治办法是不再单文件挂载 config，
#   改用 $OMBRE_CONFIG_PATH 把配置放进已经是目录挂载的数据卷里（见 docker-compose.user.yml）。
#
# 本脚本逻辑：
#   1. 配置路径取 $OMBRE_CONFIG_PATH，未设则退回 /app/config.yaml（老行为，兼容现有部署）。
#   2. 确保其父目录存在。
#   3. 若该路径是目录：
#        - 能删就删掉再从默认模板初始化（数据卷里的普通目录，删得掉）；
#        - 删不掉（是个 bind mount 挂载点，Device busy）→ 打印清晰指引并退出，
#          让用户去掉 compose 里的单文件挂载，而不是无限重启刷一样的报错。
#   4. 若不存在 → 从内置默认模板初始化。
#   5. 若已是正常文件 → 不干预。

CONFIG="${OMBRE_CONFIG_PATH:-/app/config.yaml}"
DEFAULT=/app/config.default.yaml

# 父目录（数据卷挂载点本身已存在；这里兜底自建路径不存在的中间层）
mkdir -p "$(dirname "$CONFIG")" 2>/dev/null || true

if [ -d "$CONFIG" ]; then
    echo "[entrypoint] '$CONFIG' is a directory (Docker created it because the host file was missing)."
    if rmdir "$CONFIG" 2>/dev/null || rm -rf "$CONFIG" 2>/dev/null; then
        echo "[entrypoint] Removed the stray directory, initializing from defaults..."
        cp "$DEFAULT" "$CONFIG"
        echo "[entrypoint] config initialized at '$CONFIG'."
    else
        echo "[entrypoint] FATAL: cannot remove '$CONFIG' — it is an active bind mount (Device or resource busy)."
        echo "[entrypoint] This happens when compose single-file-mounts a missing config, e.g."
        echo "[entrypoint]     volumes:  - ./config.yaml:/app/config.yaml"
        echo "[entrypoint] Fix: remove that line and let config live in the data volume instead"
        echo "[entrypoint]   (set OMBRE_CONFIG_PATH=/app/buckets/config.yaml and mount ./buckets:/app/buckets)."
        echo "[entrypoint] See deploy/docker-compose.user.yml for the corrected layout."
        exit 1
    fi
elif [ ! -f "$CONFIG" ]; then
    echo "[entrypoint] config not found at '$CONFIG', initializing from defaults..."
    cp "$DEFAULT" "$CONFIG"
    echo "[entrypoint] config initialized at '$CONFIG'."
fi

exec python src/server.py
