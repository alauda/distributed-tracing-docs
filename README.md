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

当 Jaeger 发布新版本时，可以使用 `hack/update-jaeger-version.sh` 更新相关 MDX 文档中的版本号。

### 更新 Jaeger 版本号

脚本接收旧版本和新版本两个参数，推荐使用不带 `v` 的 `x.y.z` 格式（同时兼容带 `v` 的格式）：

```bash
# 用法: ./hack/update-jaeger-version.sh <旧版本> <新版本>
./hack/update-jaeger-version.sh 2.20.0 2.24.0
```

脚本只更新以下内容：

- `docs/en/**/*.mdx` 中以 `https://github.com/alauda-mesh/jaeger/tree/v<旧版本>/` 开头的链接；
- [migrating-from-acp-tracing.mdx](./docs/en/migrating/migrating-from-acp-tracing.mdx) 中出现的旧版本，包括正文、表格以及命令输出示例中的镜像 tag。

其他 MDX 文档中的版本说明不会被修改，以免覆盖与特定 Jaeger 版本相关的历史或行为说明。

### Jaeger 新版本内容同步更新

让 AI 读取当前版本到新版本更新的内容：https://github.com/jaegertracing/jaeger/releases。
然后分析当前文档是否有需要同步更新的部分，review 后执行更新。

### sites.yaml 更新

更新 [sites.yaml](./sites.yaml) 中的最新外链站点。
