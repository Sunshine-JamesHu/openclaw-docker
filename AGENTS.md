# OpenClaw Docker 部署包

## 项目概述

这是 OpenClaw 的离线 Docker 部署包。

- 本地 `build.sh` 负责构建镜像并导出 `openclaw.tar`
- 服务器 `setup.sh` 只负责 `docker load`、放默认配置、启动服务

## 当前部署模型

- 单一宿主机挂载目录：`OPENCLAW_HOST_DIR`
- 默认值：`/data/openclaw`
- 容器内映射：`/home/node/.openclaw`
- 容器默认运行用户：`0:0`
- Gateway 和 CLI 默认启用 `privileged: true`

因此服务器上的关键文件固定落在：

- `/data/openclaw/openclaw.json`
- `/data/openclaw/tls/cert.pem`
- `/data/openclaw/tls/key.pem`
- `/data/openclaw/workspace/`

## 主要命令

```bash
./setup.sh -s install
./setup.sh -s start
./setup.sh -s stop
./setup.sh -s update

./setup.sh -s pair-list
./setup.sh -s pair-approve -i 192.168.31.187
./setup.sh -s pair-approve -r <requestId>
```

## 设计约束

- 不要再引入多目录挂载
- `install` 必须是无交互的
- `install` 需要自动把包内 `openclaw.json` 和 `tls/` 放到固定位置
- `install` 完成后，不要再自动改写宿主机上的 `openclaw.json`
- `start` 只做启动，不做复杂向导，也不改写 `openclaw.json`
- `stop` 默认删除容器，不保留容器系统层里的临时安装内容
- `update` 根据 `VERSION` 文件确定目标镜像，本地已有则跳过 load，不存在则从 tar 加载，不需要传版本号
- 设备配对由 `pair-list` / `pair-approve` 处理
- 默认让 OpenClaw 以 root + `privileged: true` 运行，避免容器内安装类命令直接被权限拦住
- 默认模型是 `zai/glm-4.7`
- 构建出的运行镜像默认把 Debian `apt` 源切到中科大
- 构建出的运行镜像默认预装 `codex`、`gemini`、`claude`
- 默认 token 是 `1234567890`
- 默认时区是 `Asia/Shanghai`

## build.sh 输出要求

`build.sh` 生成的 `dist/` 至少包含：

- `openclaw.tar`
- `openclaw-src-<version>.zip`
- `docker-compose.yml`
- `.env`
- `openclaw.json`
- `tls/cert.pem`
- `tls/key.pem`
- `setup.sh`
