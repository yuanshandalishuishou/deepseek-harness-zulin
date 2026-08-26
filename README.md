# DeepSeek Harness 租赁版（deepseek-harness-zulin）

基于 [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 的央企融资租赁
"八位专家"数字化参谋团队容器化部署方案。

- 基础镜像：`debian:trixie-slim`（含 xfce4 桌面 + xRDP + SSH）
- Node.js：v24.1.0（清华源）
- 端口：SSH 22 / Harness Web 3000 / xRDP 3389
- 镜像内**不含任何 API Key**，配置在容器首次启动时由环境变量生成

## 快速开始

```bash
# 方式一：直接使用 GitHub Actions 自动构建的镜像
docker run -d --name dsh-debian13 --restart unless-stopped \
    -p 10022:22 -p 13000:3000 -p 13389:3389 \
    -e DEEPSEEK_API_KEY=sk-xxxx \
    -v dsh-data:/root/.dsh \
    ghcr.io/yuanshandalishuishou/deepseek-harness-zulin:latest

# 方式二：一键部署脚本（优先拉取 GHCR 镜像，失败则本地构建）
curl -fsSL https://raw.githubusercontent.com/yuanshandalishuishou/deepseek-harness-zulin/main/deploy.sh -o deploy.sh
DEEPSEEK_API_KEY=sk-xxxx bash deploy.sh
```

> 私有仓库需先 `docker login ghcr.io`（使用 GitHub 用户名 + PAT，勾选 `read:packages`）。

## 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `DEEPSEEK_API_KEY` | DeepSeek 官方 API Key | 空 |
| `OPENAI_API_KEY` | OpenAI 兼容 API Key（硅基流动/百炼等） | 空 |
| `MODEL_CHOICE` | 1=DeepSeek官方 2=硅基流动 3=阿里百炼 4=DeepSeek+自定义 5=自定义OpenAI | `1` |
| `CUSTOM_MODEL_NAME` | MODEL_CHOICE=4 时的 DeepSeek 模型名 | `gpt-4o-mini` |
| `CUSTOM_OPENAI_BASE_URL` | MODEL_CHOICE=2/3/5 时的 base-url | 2/3 内置默认 |
| `CUSTOM_OPENAI_MODEL` | MODEL_CHOICE=5 时的模型名 | 空 |

## 访问方式

| 服务 | 地址 | 凭据 |
|------|------|------|
| Web UI | http://localhost:13000 | - |
| SSH | `ssh -p 10022 root@localhost` | root / deepseek |
| xRDP | localhost:13389 | root / deepseek |

数据持久化：命名卷 `dsh-data` → `/root/.dsh`（首次启动自动初始化角色与配置）。

## 内置角色（souls/）

| 专家 | ID | 职责 |
|------|-----|------|
| 纪总 | `enterprise-boss` | 总协调人（默认 persona） |
| 纪融 | `financial-expert` | 金融业务（ABS/租赁/保理/外汇/股权） |
| 纪正 | `compliance-expert` | 合规审查 |
| 纪棠 | `party-labor-discipline` | 党工纪与文书 |
| 纪衡 | `tax-expert` | 财税 |
| 纪枢 | `architect-expert` | 软件架构 |
| 纪码 | `dev-expert` | 软件开发 |
| 纪测 | `qa-expert` | 软件测试 |

## CI/CD

推送到 `main` 分支（或推送 `v*` 标签）时，GitHub Actions 自动构建镜像并推送到 GHCR：

- `main` 分支 → `ghcr.io/yuanshandalishuishou/deepseek-harness-zulin:latest`
- `v1.2.0` 标签 → `:1.2.0` 和 `:1.2`

使用内置 `GITHUB_TOKEN`，无需配置任何 Secret。固定上游版本可加 build-arg：
`docker build --build-arg DSH_REF=<commit-or-tag> .`
