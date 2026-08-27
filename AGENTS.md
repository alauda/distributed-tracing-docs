# AGENTS.md

## Alauda Distributed Tracing 架构

- Alauda Distributed Tracing 基于 Jaeger v2 和 Alauda Build of OpenTelemetry v2
- 使用 OpenTelemetry Operator 部署 Jaeger 实例
- 后端存储支持 Elasticsearch 和 Opensearch。

## MDX 文档约束

- 内链引用其他文档时，需要添加 anchor，例如 `[Upgrade Notes](../about/release-notes/v2-1-0.mdx#upgrade-notes)` 引用 `## Upgrade Notes \{#upgrade-notes}`，否则 yarn lint 报错。
