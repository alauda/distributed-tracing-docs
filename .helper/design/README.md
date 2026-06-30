# 设计文档

- [从 Observability/Distributed Tracing 迁移到 Alauda Distributed Tracing](./migrate-from-observability-tracing.md) —— 新老 Jaeger 迁移方案评估
- [Span Metrics Connector 多副本（高可用）下的 SPM 部署设计](./spanmetrics-connector-ha.md) —— 前提：OTel Collector 与 Jaeger 都要多副本；两层 gateway + `routing_key: service`
- [Service Graph Connector 与 Span Metrics Connector 同时多副本的部署设计](./servicegraph-and-spanmetrics-connectors-ha.md) —— 两连接器路由 key 冲突（service vs traceID），需两套负载均衡分流
