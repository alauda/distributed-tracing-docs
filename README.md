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

### 更新 Jaeger 镜像 tag

更新文档中 `build-harbor.alauda.cn` 镜像的 tag：

```bash
# 用法: ./hack/update-jaeger-image-tag.sh <新tag>
./hack/update-jaeger-image-tag.sh 2.17.0-r0
```
