# OpenClaw Docker Deployment Bundle

这个仓库是 OpenClaw 的离线 Docker 部署包。

目标只有一件事：本地构建一次镜像，服务器上只做 `docker load`、放默认配置、启动服务。

## 结构

```text
.
├── build.sh
├── setup.sh
├── dist/
│   ├── openclaw.tar
│   ├── openclaw-src-<version>.zip
│   ├── docker-compose.yml
│   ├── .env
│   ├── openclaw.json
│   ├── tls/
│   │   ├── cert.pem
│   │   └── key.pem
│   └── setup.sh
└── AGENTS.md
```

## 部署模型

- 宿主机只挂载一个目录：`OPENCLAW_HOST_DIR`
- 默认值：`/data/openclaw`
- 容器内固定映射到：`/home/node/.openclaw`
- 容器默认运行用户：`0:0`，也就是 root
- Gateway 和 CLI 容器默认启用 `privileged: true`
- 运行镜像默认预装：`codex`、`gemini`、`claude`
- 默认配置文件位置：`/data/openclaw/openclaw.json`
- 默认 TLS 证书位置：`/data/openclaw/tls/`
- 工作区位置：`/data/openclaw/workspace/`

这意味着包里的 `openclaw.json`、`tls/` 会在安装时被放到固定位置，后续 OpenClaw 运行时产生的数据也都落在同一个目录下。默认以 root + `privileged: true` 运行，是为了让 OpenClaw 自己在容器里执行安装和系统级命令时不要先被权限模型拦住。

## 本地构建

```bash
./build.sh
./build.sh -v 2026.3.23
```

`build.sh` 会：

1. 获取最新 release tag，或使用 `-v`
2. 下载源码 zip 到 `dist/`
3. 用上游 Dockerfile 构建镜像
4. 导出 `dist/openclaw.tar`
5. 生成部署用的 `docker-compose.yml`、`.env`、`openclaw.json`、`tls/`、`setup.sh`
6. 运行镜像默认预装 `codex`、`gemini`、`claude`
6. 构建时把镜像内的 Debian `apt` 源改成中科大镜像

## 服务器部署

```bash
scp -r dist/ user@server:/opt/openclaw/
ssh user@server
cd /opt/openclaw
./setup.sh -s install
```

`install` 会完成这些动作：

1. `docker load -i openclaw.tar`
2. 创建固定挂载目录，默认是 `/data/openclaw`
3. 将包里的 `openclaw.json` 放到 `/data/openclaw/openclaw.json`
4. 将包里的 `tls/` 放到 `/data/openclaw/tls/`
5. 修正宿主机目录权限
6. 启动 OpenClaw

`install` 初始化完成后，后续 `start` / `update` 不会再改写 `openclaw.json`。

## 运行命令

```bash
./setup.sh -s install
./setup.sh -s start
./setup.sh -s stop
./setup.sh -s update

./setup.sh -s pair-list
./setup.sh -s pair-approve -i 192.168.31.187
./setup.sh -s pair-approve -r <requestId>
```

说明：

- `install`：首次部署，放默认配置并启动
- `start`：启动服务，不改写 `openclaw.json`，也不重复输出访问引导
- `stop`：停止服务，并删除容器
- `update`：重新加载当前目录里的 `openclaw.tar` 并重启，不改写 `openclaw.json`，也不重复输出访问引导
- `pair-list`：查看待批准设备和已配对设备
- `pair-approve -i <ip>`：按 `pair-list` 里显示的 IP 批准最新待处理请求
- `pair-approve -r <requestId>`：按 request id 批准

## 首次访问和配对

部署成功后，脚本会直接打印带 token 的 HTTPS 链接，例如：

```text
https://192.168.31.88:18789/#token=1111-1111
```

如果浏览器第一次打开时出现 `pairing required`：

```bash
./setup.sh -s pair-list
./setup.sh -s pair-approve -i <pair-list里显示的IP>
```

然后刷新浏览器即可。

## `.env`

默认生成的关键变量：

```env
OPENCLAW_VERSION=2026.3.23
OPENCLAW_IMAGE=openclaw:2026.3.23
OPENCLAW_HOST_DIR=/data/openclaw
OPENCLAW_CONTAINER_USER=0:0
OPENCLAW_GATEWAY_TOKEN=1111-1111
OPENCLAW_GATEWAY_PORT=18789
OPENCLAW_BRIDGE_PORT=18790
OPENCLAW_TZ=Asia/Shanghai

# 默认模型
# ZAI_API_KEY=
```

默认模型在 `openclaw.json` 里已经设置为：

```json
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "zai/glm-4.7"
      }
    }
  }
}
```

如果你后面想收紧权限，也可以把 `.env` 里的 `OPENCLAW_CONTAINER_USER` 改成 `1000:1000`，再重启容器。

## HTTPS

这个部署包默认在 `openclaw.json` 里启用了 TLS：

```json
{
  "gateway": {
    "tls": {
      "enabled": true,
      "certPath": "/home/node/.openclaw/tls/cert.pem",
      "keyPath": "/home/node/.openclaw/tls/key.pem"
    }
  }
}
```

默认附带的是自签名证书。你也可以直接替换 `dist/tls/` 或服务器上的 `/data/openclaw/tls/`。

## APT 源

构建后的运行镜像默认把 Debian `apt` 源切到中科大：

```text
https://mirrors.ustc.edu.cn/debian
https://mirrors.ustc.edu.cn/debian-security
```

## 预装组件

运行镜像默认预装这三个终端组件：

- `codex`（OpenAI Codex CLI）
- `gemini`（Google Gemini CLI）
- `claude`（Anthropic Claude Code）

## 兼容旧布局

如果旧版本把数据放在：

- `/data/openclaw/config`
- `/data/openclaw/workspace`

新的 `setup.sh` 会尝试把 `config/` 下的内容迁移到新的单目录布局中。
