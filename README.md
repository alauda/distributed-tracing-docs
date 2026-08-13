# distributed-tracing-docs

Documentation for Alauda Distributed Tracing

## Documentation Dependencies

- Ensure that [Node.js](https://nodejs.org/en/) and [npm](https://www.npmjs.com/) are installed locally
- Use `yarn` to install dependencies

```bash
$ yarn install
```

- It's recommended to use [Visual Studio Code](https://code.visualstudio.com/) editor and install the [MDX](https://marketplace.visualstudio.com/items?itemName=unifiedjs.vscode-mdx) extension for document writing

## Documentation Quick Start

- `yarn dev`: Start the local development server, file modifications will update in real-time. (**Note:** Left navigation bar related modifications require restarting the service)
- `yarn build`: Build production environment code, static files will be generated in the `dist` directory after build completion
- `yarn serve`: Preview the built static files locally

## Jaeger 版本更新

当 Jaeger 发布新版本时，需要更新文档中的版本号和镜像 tag。`hack/` 目录提供了两个脚本来自动完成此操作。

### 更新 Jaeger 版本号

更新文档中的 Jaeger 版本引用（如 GitHub 链接中的 tag）：

```bash
# 用法: ./hack/update-jaeger-version.sh <旧版本> <新版本>
./hack/update-jaeger-version.sh v2.16.0 v2.17.0
```

### 更新 migrating-from-acp-tracing.mdx 文档

更新 [migrating-from-acp-tracing.mdx](./docs/en/migrating/migrating-from-acp-tracing.mdx) 中的 `kubectl get opentelemetrycollector -A` 命令执行示例结果为最新，包括：`VERSION` 和 `IMAGE`。

### Jaeger 新版本内容同步更新

让 AI 读取当前版本到新版本更新的内容：https://github.com/jaegertracing/jaeger/releases。
然后分析当前文档是否有需要同步更新的部分，review 后执行更新。

### sites.yaml 更新

更新 [sites.yaml](./sites.yaml) 中的最新外链站点。
