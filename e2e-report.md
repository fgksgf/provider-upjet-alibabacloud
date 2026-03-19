# E2E 测试报告：SharedProvider 模式

**测试日期**: 2026-03-19
**测试环境**: GCP VM (8-core / 32GB RAM / 96GB disk, Linux 6.14.0-1017-gcp)
**集群**: kind v0.29.0, Kubernetes v1.33.1, Crossplane v2.2.0
**Provider 镜像**: `provider-alibabacloud:shared-test` (monolith, 本地构建)
**阿里云区域**: ap-southeast-1
**资源组**: rg-aek3vwnwrvq2uiq

---

## 测试资源

| 资源类型 | CR 名称 | 说明 |
|----------|---------|------|
| VPC | e2e-shared-vpc | CIDR 172.16.0.0/16 |
| OSS Bucket | e2e-sp-bkt-\<random\>-shared | 随机名称避免冲突 |

> 原计划包含 RAM Role，因资源组不支持 RAM 服务而移除。

---

## 发现的 Bug 与修复

### Bug: SharedProvider 模式 "no supported plugins for protocol 4"

**现象**: SharedProvider 正确 fork 了 native provider 进程，但 Terraform CLI 1.5.7 在使用 `TF_REATTACH_PROVIDERS` 连接时报错 `no supported plugins for protocol 4`。

**根因**: `terraform-provider-alicloud` v1.261.0 使用 Plugin SDK v1，默认以 netrpc/protocol 4 模式启动。Terraform CLI 1.5.7 的 `TF_REATTACH_PROVIDERS` 机制仅支持 gRPC (protocol 5/6)。

**修复**: 在 `vendor/github.com/crossplane/upjet/pkg/terraform/provider_runner.go` 中，启动 native provider 时添加 `PLUGIN_PROTOCOL_VERSIONS=5` 环境变量，强制 provider 以 gRPC/protocol 5 模式运行：

```go
cmd.SetEnv(append(os.Environ(),
    fmt.Sprintf(fmtSetEnv, envMagicCookie, valMagicCookie),
    "PLUGIN_PROTOCOL_VERSIONS=5",
))
```

**效果**: 修复后 SharedProvider 模式完全正常工作。

---

## 测试结果

### 资源消耗对比

| 指标 | CLI 模式 (创建前) | CLI 模式 (创建后) | Shared 模式 (创建前) | Shared 模式 (创建后) |
|------|:-:|:-:|:-:|:-:|
| kubectl top CPU | 9m | 693m | 5m | 407m |
| kubectl top Memory | 73Mi | 184Mi | 60Mi | 166Mi |
| VmRSS (kB) | 127,400 | 130,788 | 114,000 | 126,392 |
| Threads | 15 | 15 | 14 | 15 |
| terraform-provider 进程数 | 0 | 0* | 0 | 1 |

> \* CLI 模式下 terraform-provider 进程为临时启动，操作完成后退出，因此采样时为 0。

### 功能对比

| 测试项 | CLI 模式 | Shared 模式 | 通过？ |
|--------|:-:|:-:|:-:|
| VPC Create → Ready | ~60s | ~60s | PASS |
| Bucket Create → Ready | ~13s | ~17s | PASS |
| VPC Update (patch description) | N/A | Synced=True | PASS |
| 资源全部删除 | 1s | 1s | PASS |
| 10 并发 VPC 全部 Ready | N/A | 217s | PASS |
| SharedProvider 进程数恒 = 1 | N/A | Yes | PASS |
| 无 OOM / restart | Yes | Yes | PASS |
| 回退 CLI 正常 | N/A | Yes | PASS |

### 并发压力测试详情 (SharedProvider 模式, 10 VPC)

| 时间 | terraform-provider 进程数 | VmRSS (kB) | Ready 数 | Restarts |
|------|:-:|:-:|:-:|:-:|
| +15s | 1 | 134,132 | 0/10 | 0 |
| +30s | 1 | 137,076 | 2/10 | 0 |
| +60s | 1 | 137,588 | 4/10 | 0 |
| +90s | 1 | 138,100 | 5/10 | 0 |
| +120s | 1 | 138,484 | 6/10 | 0 |
| +150s | 1 | 138,484 | 8/10 | 0 |
| +180s | 1 | 138,740 | 9/10 | 0 |
| +195s | 1 | 138,740 | 10/10 | 0 |

**关键观察**:
- terraform-provider 进程数在整个过程中始终为 **1**
- 内存增长平稳（134MB → 138MB），无泄漏迹象
- 无 OOM kill 或 pod restart

---

## 判定标准

### P0 必须通过

- [x] SharedProvider 模式下 VPC 和 OSS Bucket CRUD 全部成功
- [x] SharedProvider 日志中出现 `Forked new native provider`（进程复用确认）
- [x] terraform-provider 进程数在并发测试中保持为 1
- [x] 无 panic、OOM kill 或 pod restart
- [x] 回退 CLI 模式功能正常

### P1 应该通过

- [ ] Shared 模式内存低于 CLI 模式 — **未明显低于**（两者接近，创建后均约 126-130MB RSS）
- [x] 10 并发 VPC 全部 Ready 且无 timeout
- [x] Update 操作在 Shared 模式下正常同步

### P2 最好通过

- [ ] Shared 模式首次 Ready 时间 ≤ CLI 模式 — **基本持平**
- [ ] 持续运行 30 分钟无内存泄漏 — **未执行长时间测试**

---

## SharedProvider 日志关键行

```
Provider runner not yet started. Will fork a new native provider.
Forked new native provider.
Shared gRPC server is running...  reattachConfig={"registry.terraform.io/aliyun/alicloud":{"Protocol":"grpc","ProtocolVersion":5,...}}
Reusing the provider runner  invocationCount=1 inUse=1
```

SharedProvider TTL 机制观察：
- `Forked new native provider` 在整个测试过程中出现 19 次，说明 TTL 到期后进程被回收，下次请求时重新 fork
- 但任一时刻最多只有 **1 个** terraform-provider 进程

---

## 遗留问题

1. **OSS Bucket 名称冲突**: Bucket 名称全局唯一，之前移除 finalizer 强制删除 CR 导致云上资源残留。后续测试应使用唯一随机名称并确保正常删除流程
2. **内存改善不明显**: 在只有 2 种资源类型的测试中，Shared 模式相比 CLI 模式内存优势不大。预期在大量资源并发场景下差异更显著
3. **SharedProvider TTL 过短**: 默认 5 分钟 TTL 导致空闲时频繁重启 native provider 进程，可能影响 poll 间隔较长时的性能。建议根据实际场景调整

---

## 结论

SharedProvider 模式在修复 `PLUGIN_PROTOCOL_VERSIONS=5` 后 **功能验证通过**。核心优势在于并发场景下 terraform-provider 进程数恒定为 1（不随资源数增长），避免了 CLI 模式下多进程带来的内存开销。回退 CLI 模式兼容性正常。
