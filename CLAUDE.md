# OpenClaw Docker 部署包

## 项目概述

OpenClaw 的离线 Docker 部署包。构建和部署完全分离：
- 本地 `build.sh` 构建 Docker 镜像并导出 tar
- 服务器 `setup.sh` 只做 `docker load` + compose 部署，零 build

## 项目结构

```
├── build.sh         # 本地构建脚本 — 下载源码、构建镜像、导出 tar、打包 dist/
├── setup.sh         # 服务器部署脚本 — 会被复制到 dist/ 中
├── CLAUDE.md
└── dist/            # 构建产物, 整体 scp 到服务器
    ├── openclaw.tar             # Docker 镜像 (docker save, ~950MB)
    ├── openclaw-src-{版本号}.zip # 源码备份 (GitHub Release)
    ├── openclaw.json            # 配置文件 (含 TLS, :ro 挂载到容器)
    ├── docker-compose.yml       # Compose 编排
    ├── .env                     # 运行配置
    ├── tls/cert.pem             # TLS 证书 (自签名, 可替换为正式证书)
    ├── tls/key.pem              # TLS 私钥
    └── setup.sh                 # 部署脚本
```

> 注: 根目录无 Dockerfile / .dockerignore，构建使用源码自带的官方 Dockerfile。

## 构建流程

`build.sh` 使用 OpenClaw 官方 Dockerfile 从源码构建：
1. 从 GitHub API 获取最新 release tag（或手动指定 `-v`）
2. 下载源码 zip 到 `dist/openclaw-src-{版本号}.zip`（已有则跳过）
3. 解压到 `.build/` 临时目录
4. 移除 Dockerfile 中的 `# syntax=docker/dockerfile:1.7`（避免额外拉取 BuildKit 前端）
5. 使用官方多阶段 Dockerfile 构建（pnpm + bun，基于 node:24-bookworm）
6. `docker save` 导出 tar，生成 docker-compose.yml / .env
7. 生成自签名 TLS 证书到 `dist/tls/`
8. 生成 `openclaw.json`（含 TLS 配置）到 `dist/`
9. 清理 `.build/` 临时目录

## 工作流

### 构建 (本地开发机)

```bash
./build.sh              # 自动从 GitHub API 获取最新版本
./build.sh -v 2026.3.14 # 手动指定版本
```

构建产物输出到 `dist/` 目录。

### 部署 (服务器, 无需 build)

```bash
scp -r dist/ user@server:/opt/openclaw/
ssh user@server
cd /opt/openclaw
./setup.sh -s install   # 首次部署
./setup.sh -s start     # 启动
./setup.sh -s stop      # 停止
./setup.sh -s update    # 更新 (替换 tar 后)
./setup.sh -s update -v 2026.3.23  # 更新并指定版本号
./setup.sh -s status    # 状态
./setup.sh -s logs      # 日志
./setup.sh -s cli       # CLI 交互
./setup.sh -s token     # 重新生成 Token
```

## 关键设计决策

- **数据持久化**: 通过宿主机目录挂载 (默认 `/data/openclaw`)，容器重建不影响数据。`openclaw.json` 和 TLS 证书从包内只读挂载，identity/agents/workspace 从宿主机持久化
- **权限**: 容器内以 node 用户 (uid 1000) 运行，`setup.sh -s install` 自动 chown 宿主机目录
- **无 build 依赖**: 服务器只需要 Docker + Compose V2，不需要 Node.js/npm/git 源码
- **版本自动获取**: `build.sh` 默认从 GitHub API 查询 `openclaw/openclaw` 最新 release tag
- **源码构建**: 使用官方多阶段 Dockerfile 从源码编译，入口为 `node dist/index.js`
- **无需 syntax 指令**: 构建时自动移除 `# syntax=docker/dockerfile:1.7`，使用 Docker 内置 BuildKit 前端

## .env 关键变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| OPENCLAW_VERSION | 版本号 (build.sh 自动写入) | - |
| OPENCLAW_IMAGE | 镜像 tag | openclaw:${OPENCLAW_VERSION} |
| OPENCLAW_GATEWAY_TOKEN | 网关认证 Token | 自动生成 |
| OPENCLAW_HOST_DATA_DIR | 宿主机数据目录 (identity/agents/workspace 的父目录) | /data/openclaw |
| OPENCLAW_GATEWAY_PORT | Gateway HTTPS 端口 | 18789 |
| OPENCLAW_BRIDGE_PORT | Bridge 端口 | 18790 |
| OPENCLAW_TZ | 时区 | UTC |
| OPENCLAW_ALLOW_INSECURE_PRIVATE_WS | 允许不安全的私有 WebSocket | (空) |
| CLAUDE_AI_SESSION_KEY | Claude AI 会话密钥 | (空) |
| CLAUDE_WEB_SESSION_KEY | Claude Web 会话密钥 | (空) |
| CLAUDE_WEB_COOKIE | Claude Web Cookie | (空) |

## 更新流程

```bash
# 本地: 构建新版本
./build.sh

# 只传 tar 到服务器 (其余文件不变则不用传)
scp dist/openclaw.tar user@server:/opt/openclaw/

# 服务器: 执行更新
ssh user@server "cd /opt/openclaw && ./setup.sh -s update -v 版本号"
```
