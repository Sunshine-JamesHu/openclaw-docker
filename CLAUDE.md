# OpenClaw Docker 部署包

## 项目概述

这是 OpenClaw 的离线 Docker 部署包。

基本原则：
- 本地 `build.sh` 负责构建镜像并产出 `dist/`
- 服务器 `setup.sh` 只负责 `docker load`、初始化默认配置、启动服务
- 服务器不参与源码构建

## 当前实现

### 配置文件

- `templates/.env`
  - 只放用户配置（项目名、token、端口、时区）
  - 不放版本号，版本由 `VERSION` 文件管理
- `templates/docker-compose.yml`
  - 只放编排和容器运行定义
- `templates/openclaw.json`
  - 放 OpenClaw 自身配置
  - API Key、渠道 token、模型配置都在这里

### 版本管理

- 版本号写在 `dist/VERSION` 文件中（一行纯文本）
- `build.sh` 构建时写入
- `setup.sh` 从 `VERSION` 读取，推导镜像名为 `openclaw:<version>`
- `update` 先检查该镜像是否已存在，已有则跳过 load，不存在则从 tar 加载
- 用户不需要手动传版本号

### 项目名规则

`.env` 中的 `OPENCLAW_PROJECT_NAME`：
- 只能是小写英文字母
- 用于派生实例隔离名称

派生结果：
- Compose 项目名：`openclaw-<project>`
- Gateway 容器名：`openclaw-gateway-<project>`
- CLI 容器名：`openclaw-cli-<project>`
- 宿主机目录：`/data/open-claw-<project>`

补充：
- 通过 `setup.sh` 启动时，实际注入的是 `/data/open-claw-<project>`
- `templates/docker-compose.yml` 当前保留的静态 fallback 是 `/data/open-claw`
- 如果用户绕过 `setup.sh` 直接运行 `docker compose`，且没有显式设置 `OPENCLAW_HOST_DIR`，会落到 `/data/open-claw`

### 容器运行模型

- 容器固定使用 `0:0`
- Gateway 和 CLI 默认 `privileged: true`
- 宿主机只挂载一个目录
- 容器内统一映射到 `/home/node/.openclaw`

## build.sh 约定

`build.sh` 当前会：

1. 下载指定版本源码 zip（仅构建用，不放入 dist）
2. 解压到 `.build/`
3. 基于上游 Dockerfile 打补丁
4. 先切 Debian `apt` 源到中科大
5. 再切 npm 源到 `npmmirror`
6. 再升级到最新 npm
7. 再继续镜像构建
8. 在运行镜像中预装 `codex`、`gemini`、`claude`
9. 导出 `dist/openclaw.tar`
10. 输出 `dist/VERSION`、`dist/docker-compose.yml`、`dist/.env`、`dist/openclaw.json`、`dist/tls/`、`dist/setup.sh`

说明：
- 不预装 `qqbot`
- `qqbot` 如需安装，部署后人工执行 CLI 命令

## setup.sh 约定

支持的动作只有：

```bash
./setup.sh -s install
./setup.sh -s start
./setup.sh -s stop
./setup.sh -s update
./setup.sh -s exec -- <command> [args...]
./setup.sh -s pair-list
./setup.sh -s pair-approve -i <ip>
./setup.sh -s pair-approve -r <requestId>
```

行为约束：
- `install` 无交互
- `install` 自动落包内 `openclaw.json` 和 `tls/`
- `install` 完成后不再自动改写宿主机 `openclaw.json`
- `start` 只做启动
- `stop` 默认删除容器
- `update` 根据 `VERSION` 确定目标镜像，本地已有则跳过 load，不存在则从 tar 加载并重启
- `exec` 用于在宿主机侧转发命令到运行中的 Gateway 容器
- 配对只由 `pair-list` / `pair-approve` 处理

## 当前默认值

- 默认项目名：`koala`
- 默认 token：`1234567890`
- 默认时区：`Asia/Shanghai`
- 默认模型：`zai/glm-5-turbo`

## 手工安装 qqbot

部署后按项目名进入对应容器执行：

```bash
./setup.sh -s exec -- openclaw plugins install @tencent-connect/openclaw-qqbot@latest
```

例如：

```bash
./setup.sh -s exec -- openclaw plugins install @tencent-connect/openclaw-qqbot@latest
```

## 产物要求

`build.sh` 生成的 `dist/` 至少包含：

- `openclaw.tar`
- `VERSION`
- `docker-compose.yml`
- `.env`
- `openclaw.json`
- `tls/cert.pem`
- `tls/key.pem`
- `setup.sh`
