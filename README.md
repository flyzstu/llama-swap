![llama-swap 头图](docs/assets/hero3.webp)
![GitHub 下载量](https://img.shields.io/github/downloads/mostlygeek/llama-swap/total)
![GitHub Actions 状态](https://img.shields.io/github/actions/workflow/status/flyzstu/llama-swap/go-ci.yml)
![GitHub Stars](https://img.shields.io/github/stars/flyzstu/llama-swap)

# llama-swap

在一台机器上运行多个生成式 AI 模型，并按需在它们之间热切换。llama-swap 可以配合任何兼容 OpenAI 或 Anthropic API 的服务使用，为本地 AI 工作流提供统一入口。

llama-swap 使用 Go 编写，注重性能和简单性。程序没有外部运行时依赖，只需要一个二进制文件和一个配置文件即可启动。

## 功能

- ✅ 部署和配置简单：一个二进制文件、一个配置文件，无外部依赖
- ✅ 按需切换模型
- ✅ 支持任意兼容 OpenAI API 的本地服务，例如 llama.cpp、vLLM、tabbyAPI 和 stable-diffusion.cpp
- ✅ 支持以下 OpenAI API 端点：
  - `v1/completions`
  - `v1/chat/completions`
  - `v1/responses`
  - `v1/embeddings`
  - `v1/models`：列出可用模型
  - `v1/audio/speech`（[#36](https://github.com/mostlygeek/llama-swap/issues/36)）
  - `v1/audio/transcriptions`（[说明](https://github.com/mostlygeek/llama-swap/issues/41#issuecomment-2722637867)）
  - `v1/audio/voices`
  - `v1/images/generations`
  - `v1/images/edits`
- ✅ 支持以下 Anthropic API 端点：
  - `v1/messages`
  - `v1/messages/count_tokens`
- ✅ 支持 llama-server（llama.cpp）端点：
  - `v1/rerank`、`v1/reranking`、`/rerank`
  - `/infill`：代码补全
  - `/completion`：文本补全
- ✅ 通过 [stable-diffusion.cpp server](https://github.com/leejet/stable-diffusion.cpp/tree/master/examples/server) 支持 SDAPI：
  - `/sdapi/v1/txt2img`
  - `/sdapi/v1/img2img`
  - `/sdapi/v1/loras`：请求体中需要包含 `model`，以获取正确的 LoRA
- ✅ llama-swap API：
  - `/ui`：Web UI
  - `/upstream/:model_id`：直接访问上游服务（[示例](https://github.com/mostlygeek/llama-swap/pull/31)）
  - `/running`：列出当前运行的模型（[#61](https://github.com/mostlygeek/llama-swap/issues/61)）
  - `POST /api/models/unload`：手动卸载所有运行中的模型（[#58](https://github.com/mostlygeek/llama-swap/issues/58)）
  - `POST /api/models/unload/:model_id`：卸载指定模型
  - `/logs`：远程日志监控
    - `GET /logs` 返回缓冲区内的纯文本日志
    - 使用 `Accept: text/html` 请求时，`/logs` 会重定向到 `/ui/`
    - `GET /logs/stream` 保持连接并实时输出日志
    - 流式端点默认先发送历史日志；添加 `?no-history` 后仅发送新日志
    - `GET /logs/stream/proxy` 仅输出代理日志
    - `GET /logs/stream/upstream` 仅输出上游进程日志
    - `GET /logs/stream/{model_id}` 输出指定模型的日志，支持 `author/model` 形式的 ID
  - `/health`：返回 `OK`
  - `/metrics`：提供 Prometheus 格式的系统和 GPU 指标
- ✅ 支持 API Key，可限制 API 端点访问
- ✅ 可扩展配置：
  - 使用自定义 DSL 交换矩阵并发运行模型（[#643](https://github.com/mostlygeek/llama-swap/issues/643)）
  - 通过 `ttl` 在超时后自动卸载模型
  - 组合使用 `cmd` 和 `cmdStop` 管理 Docker 或 Podman 容器
  - 通过 `hooks` 在启动时预加载模型（[#235](https://github.com/mostlygeek/llama-swap/pull/235)）
  - 使用 `stripParams`、`setParams` 和 `setParamsByID` 过滤或修改请求

### Web UI

llama-swap 提供实时 Web 界面和 Playground，可用于测试不同类型的本地模型。

模型交互：

<img width="1125" height="876" alt="模型交互界面" src="https://github.com/user-attachments/assets/8ee41947-97af-463d-b0f0-8e9c478fac07" />

Token 指标：

<img width="1111" height="515" alt="Token 指标界面" src="https://github.com/user-attachments/assets/64bfb280-d7a3-4126-971a-a128fd40410c" />

请求和响应检查：

<img width="1111" height="720" alt="请求和响应界面" src="https://github.com/user-attachments/assets/24fe4aca-1448-4d7c-b9e8-a967589bda6c" />

手动加载和卸载模型：

<img width="1109" height="719" alt="模型管理界面" src="https://github.com/user-attachments/assets/02b1e1f2-abd0-4050-84ae-facd66ff01c4" />

实时日志：

<img width="1107" height="559" alt="实时日志界面" src="https://github.com/user-attachments/assets/39669a10-cff2-409e-836a-5bad8bd0140c" />

## 安装

支持以下安装方式：

1. Docker
2. Homebrew（macOS 和 Linux）
3. MacPorts（macOS）
4. WinGet（Windows）
5. 预编译二进制文件
6. 源码构建

### Docker

#### 统一镜像（推荐）

统一镜像包含以下组件：

- `llama-server`：使用 llama.cpp 最新正式稳定版
- `ik-llama-server`：使用 `ik_llama.cpp/main`，因为该项目目前没有正式稳定版
- `stable-diffusion.cpp`：使用最新正式稳定版
- `whisper.cpp`：使用最新正式稳定版
- `llama-swap`：使用最新正式稳定版

GitHub Actions 每天检查一次各组件版本，但不会每天拉取默认分支并重复构建。只有上述任一源码提交发生变化时，才会重新构建并推送镜像。

镜像发布到：

```text
ghcr.io/flyzstu/llama-swap
```

CUDA 镜像：

```shell
docker pull ghcr.io/flyzstu/llama-swap:unified-cuda

docker run -it --rm --runtime nvidia -p 9292:8080 \
  -v /path/to/models:/models \
  -v /path/to/custom/config.yaml:/etc/llama-swap/config/config.yaml \
  ghcr.io/flyzstu/llama-swap:unified-cuda
```

无 root 用户镜像：

```shell
docker pull ghcr.io/flyzstu/llama-swap:unified-cuda-rootless
```

#### 镜像 Tag

每次发布会推送滚动 tag 和不可变的版本组合 tag：

```text
unified-cuda
unified-cuda-rootless
unified-cuda-<版本组合哈希>
unified-cuda-<版本组合哈希>-rootless
```

版本组合哈希由后端类型和各组件的源码提交 SHA 生成。定时任务发现对应版本组合 tag 已存在时，会跳过构建和推送。

#### GHCR 权限

工作流默认使用 GitHub Actions 自动提供的 `GITHUB_TOKEN`，仓库工作流已配置 `packages: write` 权限。通常不需要手动提供 token。

如果仓库或 GHCR 包权限配置导致 `GITHUB_TOKEN` 无法推送，可以创建具有 `write:packages` 权限的 Personal Access Token，并将其保存为仓库 Secret：

```text
GHCR_TOKEN
```

工作流会优先使用 `GHCR_TOKEN`，未配置时回退到 `GITHUB_TOKEN`。

### Homebrew（macOS/Linux）

```shell
brew tap mostlygeek/llama-swap
brew install llama-swap
llama-swap --config path/to/config.yaml --listen localhost:8080
```

### MacPorts（macOS）

> [!NOTE]
> 该软件包由 MacPorts 社区维护，参见 [llama-swap port](https://ports.macports.org/port/llama-swap)，不属于 llama-swap 官方发布内容。

```shell
sudo port install llama-swap
llama-swap --config path/to/config.yaml --listen localhost:8080
```

### WinGet（Windows）

> [!NOTE]
> WinGet 软件包由社区贡献者 [Dvd-Znf](https://github.com/Dvd-Znf) 维护（[#327](https://github.com/mostlygeek/llama-swap/issues/327)），不属于 llama-swap 官方发布内容。

```shell
# 安装
C:\> winget install llama-swap

# 升级
C:\> winget upgrade llama-swap
```

### 预编译二进制文件

Linux、macOS、Windows 和 FreeBSD 的二进制文件可从上游 [Releases](https://github.com/mostlygeek/llama-swap/releases) 页面下载。

### 从源码构建

1. 安装 Go 和 Node.js，Node.js 用于构建 UI。
2. 克隆代码：

   ```shell
   git clone https://github.com/flyzstu/llama-swap.git
   cd llama-swap
   ```

3. 构建：

   ```shell
   make clean all
   ```

4. 构建完成后，二进制文件位于 `build/` 目录。

## 配置

最小可用配置：

```yaml
models:
  model1:
    cmd: llama-server --port ${PORT} --model /path/to/model.gguf
```

其中：

1. `models` 保存所有模型配置。
2. `model1` 是 API 请求中使用的模型 ID。
3. `cmd` 是启动推理服务的命令。
4. `${PORT}` 是 llama-swap 自动分配的端口。

大多数配置项都是可选的，可以按需逐步添加：

- 高级功能：
  - `matrix`：使用自定义交换逻辑 DSL 并发运行模型
  - `hooks`：启动时执行操作
  - `macros`：定义可复用配置片段
- 模型配置：
  - `ttl`：自动卸载超时模型
  - `aliases`：使用熟悉的模型名称，例如 `gpt-4o-mini`
  - `env`：向推理服务传递环境变量
  - `cmdStop`：优雅停止 Docker 或 Podman 容器
  - `useModelName`：覆盖发送给上游服务的模型名称
  - `${PORT}`：动态分配端口
  - `filters`：将请求发送到上游前重写部分内容

完整选项参见[配置文档](docs/configuration.md)。

## 工作原理

收到兼容 OpenAI API 的请求后，llama-swap 会读取请求中的 `model` 字段，并加载对应的服务配置。如果当前运行的上游服务与请求模型不匹配，llama-swap 会停止当前服务并启动正确的服务，这就是 “swap” 的含义。

最基础的配置一次只运行一个模型。高级场景可以使用 `matrix` 同时加载多个模型，并精确控制系统资源的使用方式。

## nginx 反向代理配置

如果在 nginx 后面部署 llama-swap，需要为流式端点关闭响应缓冲。nginx 默认缓冲响应，这会影响 Server-Sent Events（SSE）和流式聊天补全（[#236](https://github.com/mostlygeek/llama-swap/issues/236)）。

推荐配置：

```nginx
# UI 事件和日志使用的 SSE
location /api/events {
    proxy_pass http://your-llama-swap-backend;
    proxy_buffering off;
    proxy_cache off;
}

# 流式聊天补全（stream=true）
location /v1/chat/completions {
    proxy_pass http://your-llama-swap-backend;
    proxy_buffering off;
    proxy_cache off;
}
```

llama-swap 也会在 SSE 响应中设置 `X-Accel-Buffering: no`，但仍建议在反向代理中显式关闭 `proxy_buffering`。

## 使用命令行查看日志

```sh
# 返回最多最近 10 KB 的日志
curl http://host/logs

# 实时输出全部日志
curl -Ns http://host/logs/stream

# 仅输出 llama-swap 代理状态日志
curl -Ns http://host/logs/stream/proxy

# 仅输出 llama-swap 启动的上游进程日志
curl -Ns http://host/logs/stream/upstream

# 仅输出指定模型的日志
curl -Ns http://host/logs/stream/{model_id}

# 使用 Linux 管道过滤日志
curl -Ns http://host/logs/stream | grep 'eval time'

# 不先发送缓冲区中的历史日志
curl -Ns 'http://host/logs/stream?no-history'
```

## 是否必须使用 llama-server？

不需要。任何兼容 OpenAI API 的服务都可以使用。llama-swap 最初为 llama-server 设计，因此对它的支持最完整。

对于 vLLM、tabbyAPI 等 Python 推理服务，建议通过 Podman 或 Docker 运行。这可以隔离运行环境，并确保服务能正确响应 `SIGTERM` 信号以完成优雅关闭。

## Star 历史

> [!NOTE]
> 感谢所有为本项目点亮 ⭐️ 的用户。

[![Star History Chart](https://api.star-history.com/svg?repos=flyzstu/llama-swap&type=Date)](https://www.star-history.com/#flyzstu/llama-swap&Date)
