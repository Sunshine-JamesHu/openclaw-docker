# OpenClaw Docker 部署包

这是 OpenClaw 的离线 Docker 部署包。

目标很简单：
- 本地只负责构建镜像和产出 `dist/`
- 服务器只负责 `docker load`、初始化默认配置、启动服务

## 目录结构

```text
.
├── build.sh
├── setup.sh
├── templates/
│   ├── .env
│   ├── docker-compose.yml
│   └── openclaw.json
├── CLAUDE.md
├── AGENTS.md
└── dist/
    ├── openclaw.tar
    ├── openclaw-src-<version>.zip
    ├── docker-compose.yml
    ├── .env
    ├── openclaw.json
    ├── tls/
    │   ├── cert.pem
    │   └── key.pem
    └── setup.sh
```

## 当前部署模型

- 宿主机只挂载一个目录
- 容器内固定映射到 `/home/node/.openclaw`
- 容器固定以 `0:0` 运行
- Gateway 和 CLI 默认启用 `privileged: true`
- 运行镜像默认预装 `codex`、`gemini`、`claude`
- `.env` 只放编排参数
- OpenClaw 自身的密钥、渠道 token 放在 `openclaw.json` 的 `env` 里

### 项目名派生规则

`.env` 中的 `OPENCLAW_PROJECT_NAME` 只能使用小写英文字母。

`setup.sh` 会基于它自动派生：
- Compose 项目名：`openclaw-<project>`
- Gateway 容器名：`openclaw-gateway-<project>`
- CLI 容器名：`openclaw-cli-<project>`
- 宿主机目录：`/data/openclaw-<project>`

例如 `OPENCLAW_PROJECT_NAME=koala` 时：
- Gateway 容器：`openclaw-gateway-koala`
- CLI 容器：`openclaw-cli-koala`
- 宿主机目录：`/data/openclaw-koala`

这就是同一台机器部署多个实例的隔离方式。除了项目名以外，还要给每个实例分配不同的端口。

补充说明：
- 通过 `./setup.sh` 启动时，脚本会实际注入 `/data/openclaw-<project>`
- 当前 `docker-compose.yml` 自身的静态 fallback 是 `/data/openclaw`
- 如果你绕过 `setup.sh` 直接执行 `docker compose`，又没有显式设置 `OPENCLAW_HOST_DIR`，就会使用 `/data/openclaw`

## 本地构建

```bash
./build.sh
```

`build.sh` 会做这些事：

1. 下载 OpenClaw release 源码 zip 到 `dist/`
2. 解压到临时目录 `.build/`
3. 基于上游 Dockerfile 打补丁并构建镜像
4. 先把 Debian `apt` 源切到中科大镜像
5. 再把 npm 源切到 `https://registry.npmmirror.com/`
6. 再升级到最新 npm
7. 再继续执行后续构建和全局 CLI 安装
8. 运行镜像默认预装 `codex`、`gemini`、`claude`
9. 导出 `dist/openclaw.tar`
10. 将 `templates/` 渲染/复制到 `dist/`
11. 生成自签名证书到 `dist/tls/`

说明：
- 现在不再预装 `qqbot`
- 如果后面要装 qqbot，部署完成后手工执行即可

## 服务器部署

```bash
scp -r dist/ user@server:/opt/openclaw/
ssh user@server
cd /opt/openclaw
./setup.sh -s install
```

### 可用命令

```bash
./setup.sh -s install
./setup.sh -s start
./setup.sh -s stop
./setup.sh -s update
./setup.sh -s exec -- <command> [args...]

./setup.sh -s pair-list
./setup.sh -s pair-approve -i 192.168.31.187
./setup.sh -s pair-approve -r <requestId>
```

### 各命令语义

- `install`
  - `docker load -i openclaw.tar`
  - 创建宿主机目录
  - 如果宿主机上还没有 `openclaw.json` / TLS 文件，则放入包内默认文件
  - 启动 Gateway
- `start`
  - 只负责启动
  - 不改写 `openclaw.json`
- `stop`
  - 停止并删除容器
- `update`
  - 读取 `VERSION` 确定目标镜像
  - 如果镜像已存在则跳过加载，不存在则从 `openclaw.tar` 加载
  - 加载后验证镜像是否可用
  - 重启容器
  - 不改写 `openclaw.json`
- `exec`
  - 在当前项目对应的 Gateway 容器里执行任意命令
  - 容器必须已经启动
- `pair-list` / `pair-approve`
  - 处理设备配对

## `.env`

`.env` 只给编排层使用，默认内容类似：

```env
OPENCLAW_PROJECT_NAME=koala
OPENCLAW_VERSION=2026.3.24
OPENCLAW_IMAGE=openclaw:2026.3.24
OPENCLAW_GATEWAY_TOKEN=1234567890
OPENCLAW_GATEWAY_PORT=18789
OPENCLAW_BRIDGE_PORT=18790
OPENCLAW_TZ=Asia/Shanghai
```

关键点：
- 不再在 `.env` 中放 API Key 和渠道 token
- 如果要一机多开，改 `OPENCLAW_PROJECT_NAME`
- 如果要同机并行运行多个实例，还要同时改端口
- 如果要固定宿主机目录，也可以自行补充 `OPENCLAW_HOST_DIR=/data/xxx`

## `openclaw.json`

OpenClaw 自身配置放在 `openclaw.json`。

当前模板里默认包含：
- TLS 配置
- `env` 下的各类 API Key / token 占位
- 默认模型 `zai/glm-5-turbo`

示例：

```json
{
  "env": {
    "ZAI_API_KEY": "",
    "OPENAI_API_KEY": "",
    "ANTHROPIC_API_KEY": "",
    "GEMINI_API_KEY": "",
    "TELEGRAM_BOT_TOKEN": "",
    "DISCORD_BOT_TOKEN": "",
    "SLACK_BOT_TOKEN": ""
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "zai/glm-5-turbo"
      }
    }
  }
}
```

## 手工安装 qqbot

当前部署包不会自动预装 qqbot。

部署完成后如果要安装，可以在服务器上执行：

```bash
./setup.sh -s exec -- openclaw plugins install @tencent-connect/openclaw-qqbot@latest
```

例如：

```bash
./setup.sh -s exec -- openclaw plugins install @tencent-connect/openclaw-qqbot@latest
```

通用范式：

```bash
./setup.sh -s exec -- <容器内命令> [参数...]
./setup.sh -s exec -- bash -lc 'npm config get registry'
```

## HTTPS

默认启用 TLS，配置文件路径固定为：
- `/home/node/.openclaw/tls/cert.pem`
- `/home/node/.openclaw/tls/key.pem`

包内默认附带的是自签名证书。你也可以直接替换服务器上的：
- `/data/openclaw-<project>/tls/cert.pem`
- `/data/openclaw-<project>/tls/key.pem`

## 镜像内源配置

构建后的运行镜像默认做了这些处理：

- `apt` 源切到中科大
  - `https://mirrors.ustc.edu.cn/debian`
  - `https://mirrors.ustc.edu.cn/debian-security`
- npm 源切到淘宝镜像
  - `https://registry.npmmirror.com/`
- npm 升级到最新版本

## 兼容旧布局

如果旧版本把数据放在：
- `/data/openclaw-<project>/config`
- `/data/openclaw-<project>/workspace`

新的 `setup.sh` 会尝试把 `config/` 下的内容迁移到新的单目录布局中。
