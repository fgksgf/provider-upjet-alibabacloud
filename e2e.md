# E2E 验证方案：SharedProvider 模式

## 目标

验证 SharedProvider 模式在真实 Kubernetes 集群中的正确性和性能提升效果。

## 前提条件

| 项目 | 要求 |
|------|------|
| Kubernetes 集群 | v1.28+ (kind / minikube / 远程集群均可) |
| Crossplane | v1.15+ 已安装 |
| 阿里云凭证 | access_key + secret_key，有 VPC、OSS、RAM 权限 |
| 工具 | `kubectl`, `helm`, `docker`, `jq`, `bc` |
| **推荐环境** | **GitHub Codespaces 4-core / 16GB RAM / 32GB disk**（详见下方搭建指南） |

## 测试架构

```
┌─────────────────────────────────────────────────────┐
│              GitHub Codespace (4c/16GB)               │
│                                                     │
│  ┌───────────┐    ┌───────────────────────────────┐ │
│  │ Test      │    │     kind Cluster (v1.28+)     │ │
│  │ Runner    │────│  ┌─────────────────────────┐  │ │
│  │ (terminal)│    │  │ Crossplane + CRDs       │  │ │
│  └───────────┘    │  ├─────────────────────────┤  │ │
│                   │  │ Provider Pod             │  │ │
│  ┌───────────┐    │  │  ├─ shared mode          │  │ │
│  │ docker    │    │  │  └─ CLI mode             │  │ │
│  │ (DinD)    │    │  └─────────────────────────┘  │ │
│  └───────────┘    └───────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

测试分为两轮，对比同一负载在 **CLI 模式**（baseline）和 **SharedProvider 模式** 下的行为差异。

---

## Codespaces 环境搭建

推荐使用 GitHub Codespaces 作为 E2E 测试环境，免去本地配置 Docker / kind / Go 工具链的繁琐步骤。

### 可行性评估

| 维度 | 结论 | 说明 |
|------|:----:|------|
| 机型 | ✅ | 4-core / 16GB RAM / 32GB disk 满足基本编译和集群需求 |
| Docker | ✅ | devcontainer 内置 Docker-in-Docker feature |
| kind | ⚠️ | 已知 DinD 兼容问题（[kind#3748](https://github.com/kubernetes-sigs/kind/issues/3748), [kind#2412](https://github.com/kubernetes-sigs/kind/issues/2412)），但实测大多数场景可用。如遇启动失败可尝试重建 Codespace |
| 磁盘 | ⚠️ | 32GB 较紧张，需及时清理无用 Docker 镜像 |
| 网络 | ✅ | Codespaces 允许出站到阿里云 API，无白名单限制 |
| 成本 | ✅ | GitHub 免费额度 120 core-hours/月，4-core 可用约 30 小时；付费帐号无限制 |

### 创建 Codespace

**方式一：Web UI**

1. 打开 `https://github.com/fgksgf/provider-upjet-alibabacloud`
2. 切换到 `feat/shared-provider` 分支
3. 点击 **Code → Codespaces → New with options**
4. 机型选择 **4-core / 16GB RAM / 32GB disk**（或可用的最大机型）
5. 等待创建完成（首次约 5-8 分钟）

**方式二：CLI**

```bash
gh codespace create \
  --repo fgksgf/provider-upjet-alibabacloud \
  --branch feat/shared-provider \
  --machine standardLinux32gb \
  --display-name "e2e-shared-provider"
```

### devcontainer 配置

仓库已包含 `.devcontainer/devcontainer.json`，配置了：

- **Go 1.24** 开发环境（与项目 go.mod 一致）
- **Docker-in-Docker**（kind 依赖）
- **kubectl + helm**（集群管理）
- **postCreateCommand** 自动执行初始化脚本

初始化脚本 `.devcontainer/post-create.sh` 完成以下工作：

1. 安装 `kind` v0.25.0
2. 安装 Crossplane CLI
3. 执行 `make submodules`（初始化 build/ 子模块）
4. 预热 Go module cache（`go mod download`）

### 创建 kind 集群

Codespace 就绪后，在终端执行以下命令创建单节点 kind 集群：

```bash
# kind 集群配置（单节点，减少资源占用）
cat > /tmp/kind-config.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
EOF

# 创建集群
kind create cluster --name e2e --config /tmp/kind-config.yaml --wait 120s

# 验证集群
kubectl cluster-info --context kind-e2e
```

### 安装 Crossplane 和依赖

```bash
# 安装 Crossplane
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system --create-namespace \
  --wait --timeout 120s

# 安装 metrics-server（支持 kubectl top）
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
# metrics-server 在 kind 中需要跳过 TLS 验证
kubectl patch deployment metrics-server -n kube-system \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# 等待就绪
kubectl wait --for=condition=Available deployment/crossplane \
  -n crossplane-system --timeout=120s
echo "Crossplane 安装完成"
```

### 构建并加载 Provider 镜像

```bash
# 编译 monolith 二进制（约 3-5 分钟）
make build-provider.monolith

# 构建 Docker 镜像
docker build \
  -t provider-alibabacloud:shared-test \
  --build-arg TARGETOS=linux \
  --build-arg TARGETARCH=amd64 \
  -f cluster/images/provider-alibabacloud/Dockerfile .

# 加载到 kind 集群
kind load docker-image provider-alibabacloud:shared-test --name e2e
```

> 构建完成后继续执行 [Phase 0: 环境准备](#phase-0-环境准备) 中的 0.1 和 0.3 步骤（0.2 已在此完成）。

### 注意事项

- **内存管理**：建议先完成 `make build` 再创建 kind 集群，避免编译期和集群启动的内存峰值叠加
- **kind 启动失败**：在 Codespaces DinD 环境中偶尔发生，可尝试 `kind delete cluster --name e2e` 后重试，或直接重建 Codespace
- **Codespace 空闲超时**：默认 30 分钟无活动后会暂停，需 `gh codespace start` 恢复。长时间测试建议保持终端活跃
- **磁盘空间**：如编译过程报磁盘不足，执行 `docker system prune -f` 清理无用镜像

---

## Phase 0: 环境准备

### 0.1 创建凭证 Secret

```bash
# 替换为真实凭证
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: example-creds
  namespace: crossplane-system
type: Opaque
stringData:
  credentials: |
    {
      "access_key": "<YOUR_ACCESS_KEY>",
      "secret_key": "<YOUR_SECRET_KEY>",
      "region": "cn-beijing"
    }
EOF
```

### 0.2 构建 Provider 镜像

```bash
# 在 provider-upjet-alibabacloud 目录下
make submodules
make generate

# 构建 monolith 镜像（使用本地 tag）
docker build \
  -t provider-alibabacloud:shared-test \
  --build-arg TARGETOS=linux \
  --build-arg TARGETARCH=amd64 \
  -f cluster/images/provider-alibabacloud/Dockerfile .

# 如果用 kind 集群，加载镜像
kind load docker-image provider-alibabacloud:shared-test
```

### 0.3 安装 ProviderConfig

```bash
kubectl apply -f examples/providerconfig/providerconfig.yaml
```

### 0.4 准备测试资源清单

创建一个统一的测试 manifest 文件 `e2e-resources.yaml`，覆盖 3 种服务（VPC、OSS、RAM）以验证跨 resource group 的 SharedProvider 调度：

```yaml
# e2e-resources.yaml
---
apiVersion: vpc.alibabacloud.crossplane.io/v1alpha1
kind: VPC
metadata:
  name: e2e-shared-vpc
spec:
  forProvider:
    cidrBlock: 172.16.0.0/16
    vpcName: e2e-shared-provider-test
    description: "SharedProvider e2e test"
---
apiVersion: oss.alibabacloud.crossplane.io/v1alpha1
kind: Bucket
metadata:
  name: e2e-shared-bucket
spec:
  forProvider:
    bucket: e2e-shared-provider-test-bucket
---
apiVersion: ram.alibabacloud.crossplane.io/v1alpha1
kind: Role
metadata:
  name: e2e-shared-role
spec:
  forProvider:
    name: e2e-shared-provider-test-role
    description: "SharedProvider e2e test role"
    document: |
      {
        "Statement": [
          {
            "Action": "sts:AssumeRole",
            "Effect": "Allow",
            "Principal": {
              "Service": ["ecs.aliyuncs.com"]
            }
          }
        ],
        "Version": "1"
      }
```

---

## Phase 1: Baseline 测试（CLI 模式）

### 1.1 部署 Provider（不设置 TERRAFORM_NATIVE_PROVIDER_PATH）

```bash
# 部署 monolith provider，覆盖环境变量使 nativeProviderPath 为空
cat <<'EOF' | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1alpha1
kind: ControllerConfig
metadata:
  name: alibabacloud-cli-mode
spec:
  image: provider-alibabacloud:shared-test
  args:
    - --debug
    - --max-reconcile-rate=5
  env:
    - name: TERRAFORM_NATIVE_PROVIDER_PATH
      value: ""   # 空值 = CLI 模式
EOF
```

> **注意**：根据实际的 Provider 部署方式（DeploymentRuntimeConfig 或 ControllerConfig），调整上述 YAML。核心是确保 `TERRAFORM_NATIVE_PROVIDER_PATH` 为空。

### 1.2 等待 Provider 就绪

```bash
kubectl wait --for=condition=healthy provider/provider-alibabacloud \
  --timeout=120s 2>/dev/null || \
kubectl get pods -n crossplane-system -l app=provider-alibabacloud -o wide
```

### 1.3 记录 Baseline 指标（创建资源前）

```bash
PROVIDER_POD=$(kubectl get pods -n crossplane-system \
  -l app=provider-alibabacloud -o jsonpath='{.items[0].metadata.name}')

echo "=== Baseline Before Create ==="
echo "Pod: $PROVIDER_POD"
kubectl top pod "$PROVIDER_POD" -n crossplane-system 2>/dev/null || \
  echo "(metrics-server not available, use next command)"

# 精确获取容器 RSS 内存
kubectl exec -n crossplane-system "$PROVIDER_POD" -- \
  cat /proc/1/status 2>/dev/null | grep -E "VmRSS|Threads" || true

# 统计 terraform 进程数
kubectl exec -n crossplane-system "$PROVIDER_POD" -- \
  sh -c 'ps aux 2>/dev/null | grep -c terraform-provider || echo 0'

# 记录时间戳
date -u +"%Y-%m-%dT%H:%M:%SZ"
```

将结果记录到表格 [Result Sheet](#result-sheet)。

### 1.4 创建测试资源

```bash
kubectl apply -f e2e-resources.yaml
APPLY_TIME=$(date +%s)
```

### 1.5 等待资源就绪 & 计时

```bash
# 等待所有资源 Ready（最多 10 分钟）
for RESOURCE in "vpc/e2e-shared-vpc" "bucket/e2e-shared-bucket" "role/e2e-shared-role"; do
  KIND=$(echo "$RESOURCE" | cut -d/ -f1)
  NAME=$(echo "$RESOURCE" | cut -d/ -f2)
  echo "Waiting for $RESOURCE..."
  kubectl wait --for=condition=Ready "$RESOURCE" --timeout=600s 2>/dev/null || \
    echo "WARN: $RESOURCE not ready, check manually"
done
READY_TIME=$(date +%s)
echo "Time to all Ready: $((READY_TIME - APPLY_TIME))s"
```

### 1.6 记录 Baseline 指标（创建资源后）

```bash
echo "=== Baseline After Create ==="
kubectl top pod "$PROVIDER_POD" -n crossplane-system 2>/dev/null

kubectl exec -n crossplane-system "$PROVIDER_POD" -- \
  cat /proc/1/status 2>/dev/null | grep -E "VmRSS|Threads" || true

kubectl exec -n crossplane-system "$PROVIDER_POD" -- \
  sh -c 'ps aux 2>/dev/null | grep -c terraform-provider || echo 0'
```

### 1.7 验证资源状态

```bash
echo "=== Resource Status (CLI Mode) ==="
kubectl get vpc e2e-shared-vpc -o jsonpath='{.status.conditions}' | jq .
kubectl get bucket e2e-shared-bucket -o jsonpath='{.status.conditions}' | jq .
kubectl get role e2e-shared-role -o jsonpath='{.status.conditions}' | jq .
```

**通过标准：** 3 个资源全部 `Ready=True` 且 `Synced=True`。

### 1.8 清理 Baseline 测试资源

```bash
kubectl delete -f e2e-resources.yaml
# 等待资源完全删除
kubectl wait --for=delete vpc/e2e-shared-vpc --timeout=300s 2>/dev/null
kubectl wait --for=delete bucket/e2e-shared-bucket --timeout=300s 2>/dev/null
kubectl wait --for=delete role/e2e-shared-role --timeout=300s 2>/dev/null
```

### 1.9 卸载 CLI 模式 Provider

```bash
# 删除 provider 和 controller config
kubectl delete controllerconfig alibabacloud-cli-mode 2>/dev/null || true
# 根据实际部署方式删除 provider
```

---

## Phase 2: SharedProvider 模式测试

### 2.1 部署 Provider（设置 TERRAFORM_NATIVE_PROVIDER_PATH）

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1alpha1
kind: ControllerConfig
metadata:
  name: alibabacloud-shared-mode
spec:
  image: provider-alibabacloud:shared-test
  args:
    - --debug
    - --max-reconcile-rate=5
  # 不设置 TERRAFORM_NATIVE_PROVIDER_PATH env override
  # Dockerfile 中已设置默认值，SharedProvider 自动启用
EOF
```

> Dockerfile 中 `ENV TERRAFORM_NATIVE_PROVIDER_PATH=...` 已设置路径，provider 启动时将自动进入 SharedProvider 模式。

### 2.2 验证 SharedProvider 启动

```bash
PROVIDER_POD=$(kubectl get pods -n crossplane-system \
  -l app=provider-alibabacloud -o jsonpath='{.items[0].metadata.name}')

# 查看日志确认 SharedProvider 启动
kubectl logs -n crossplane-system "$PROVIDER_POD" 2>&1 | head -50

# 关键日志行（应出现）：
# "Provider runner not yet started. Will fork a new native provider."
# "Forked new native provider."
```

**通过标准：** 日志中出现 `Forked new native provider` 且无 panic/error。

### 2.3 记录 SharedProvider 指标（创建资源前）

```bash
echo "=== SharedProvider Before Create ==="
kubectl top pod "$PROVIDER_POD" -n crossplane-system 2>/dev/null

kubectl exec -n crossplane-system "$PROVIDER_POD" -- \
  cat /proc/1/status 2>/dev/null | grep -E "VmRSS|Threads" || true

# 统计 terraform-provider 进程（shared 模式应为 1）
kubectl exec -n crossplane-system "$PROVIDER_POD" -- \
  sh -c 'ps aux 2>/dev/null | grep -c terraform-provider || echo 0'
```

### 2.4 创建测试资源 & 计时

```bash
kubectl apply -f e2e-resources.yaml
APPLY_TIME=$(date +%s)

# 等待就绪
for RESOURCE in "vpc/e2e-shared-vpc" "bucket/e2e-shared-bucket" "role/e2e-shared-role"; do
  echo "Waiting for $RESOURCE..."
  kubectl wait --for=condition=Ready "$RESOURCE" --timeout=600s 2>/dev/null || \
    echo "WARN: $RESOURCE not ready, check manually"
done
READY_TIME=$(date +%s)
echo "Time to all Ready: $((READY_TIME - APPLY_TIME))s"
```

### 2.5 记录 SharedProvider 指标（创建资源后）

```bash
echo "=== SharedProvider After Create ==="
kubectl top pod "$PROVIDER_POD" -n crossplane-system 2>/dev/null

kubectl exec -n crossplane-system "$PROVIDER_POD" -- \
  cat /proc/1/status 2>/dev/null | grep -E "VmRSS|Threads" || true

# 统计进程数（shared 模式应仍为 1，不会随资源数增长）
kubectl exec -n crossplane-system "$PROVIDER_POD" -- \
  sh -c 'ps aux 2>/dev/null | grep -c terraform-provider || echo 0'

# 查看 provider 进程是否使用了 TF_REATTACH_PROVIDERS
kubectl logs -n crossplane-system "$PROVIDER_POD" 2>&1 | \
  grep -c "reattachConfig" || echo "0 reattach logs found"
```

### 2.6 验证资源状态

```bash
echo "=== Resource Status (Shared Mode) ==="
kubectl get vpc e2e-shared-vpc -o jsonpath='{.status.conditions}' | jq .
kubectl get bucket e2e-shared-bucket -o jsonpath='{.status.conditions}' | jq .
kubectl get role e2e-shared-role -o jsonpath='{.status.conditions}' | jq .
```

**通过标准：** 3 个资源全部 `Ready=True` 且 `Synced=True`。

### 2.7 验证更新操作

```bash
# 修改 VPC description 触发 Update
kubectl patch vpc e2e-shared-vpc --type=merge \
  -p '{"spec":{"forProvider":{"description":"updated by e2e test"}}}'

# 等待同步完成
sleep 30
kubectl get vpc e2e-shared-vpc \
  -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}'
# 期望输出: True
```

**通过标准：** Update 操作完成，Synced=True。

### 2.8 验证删除操作

```bash
kubectl delete -f e2e-resources.yaml
DELETE_TIME=$(date +%s)

kubectl wait --for=delete vpc/e2e-shared-vpc --timeout=300s
kubectl wait --for=delete bucket/e2e-shared-bucket --timeout=300s
kubectl wait --for=delete role/e2e-shared-role --timeout=300s
DELETED_TIME=$(date +%s)
echo "Time to all Deleted: $((DELETED_TIME - DELETE_TIME))s"
```

**通过标准：** 3 个资源全部删除成功，无残留。

---

## Phase 3: 并发压力测试（SharedProvider 模式）

验证 SharedProvider 在多资源并发 reconcile 时的稳定性。

### 3.1 生成批量资源

```bash
# 生成 10 个 RAM Role 并发创建
for i in $(seq 1 10); do
cat <<EOF
---
apiVersion: ram.alibabacloud.crossplane.io/v1alpha1
kind: Role
metadata:
  name: e2e-concurrent-role-${i}
spec:
  forProvider:
    name: e2e-concurrent-role-${i}
    description: "Concurrent test role ${i}"
    document: |
      {
        "Statement": [
          {
            "Action": "sts:AssumeRole",
            "Effect": "Allow",
            "Principal": {
              "Service": ["ecs.aliyuncs.com"]
            }
          }
        ],
        "Version": "1"
      }
EOF
done > e2e-concurrent.yaml
```

### 3.2 并发创建 & 监控

```bash
kubectl apply -f e2e-concurrent.yaml
APPLY_TIME=$(date +%s)

# 每 10 秒采样一次进程数和内存，持续 3 分钟
for i in $(seq 1 18); do
  sleep 10
  PROCS=$(kubectl exec -n crossplane-system "$PROVIDER_POD" -- \
    sh -c 'ps aux 2>/dev/null | grep -c terraform-provider || echo 0')
  MEM=$(kubectl exec -n crossplane-system "$PROVIDER_POD" -- \
    sh -c 'grep VmRSS /proc/1/status 2>/dev/null | awk "{print \$2}"' || echo "N/A")
  READY=$(kubectl get roles.ram.alibabacloud.crossplane.io \
    -l '!testing.crossplane.io/example-name' \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c True || echo 0)
  echo "$(date +%H:%M:%S) | procs=$PROCS | mem=${MEM}kB | ready=$READY/10"
done

READY_TIME=$(date +%s)
echo "Total time: $((READY_TIME - APPLY_TIME))s"
```

**通过标准：**
- SharedProvider 进程数在整个过程中始终保持为 **1**（不随资源数增长）
- 10 个资源全部 Ready
- 无 OOM kill 或 crash restart

### 3.3 清理并发测试资源

```bash
kubectl delete -f e2e-concurrent.yaml
for i in $(seq 1 10); do
  kubectl wait --for=delete role/e2e-concurrent-role-${i} --timeout=300s 2>/dev/null
done
```

---

## Phase 4: 回退兼容性验证

验证清除 `TERRAFORM_NATIVE_PROVIDER_PATH` 后 provider 自动降级回 CLI 模式。

### 4.1 部署 CLI 降级模式

```bash
# 通过覆盖环境变量为空来禁用 SharedProvider
kubectl set env deployment/provider-alibabacloud \
  -n crossplane-system TERRAFORM_NATIVE_PROVIDER_PATH=""

# 等待 pod 重启
kubectl rollout status deployment/provider-alibabacloud \
  -n crossplane-system --timeout=120s
```

### 4.2 验证 CLI 模式功能

```bash
kubectl apply -f e2e-resources.yaml

for RESOURCE in "vpc/e2e-shared-vpc" "bucket/e2e-shared-bucket" "role/e2e-shared-role"; do
  kubectl wait --for=condition=Ready "$RESOURCE" --timeout=600s 2>/dev/null || \
    echo "WARN: $RESOURCE not ready"
done

# 确认日志中无 SharedProvider 相关日志
kubectl logs -n crossplane-system "$PROVIDER_POD" 2>&1 | \
  grep "Forked new native provider" && echo "FAIL: shared mode active" || echo "PASS: CLI mode"
```

**通过标准：** 资源 CRUD 正常工作，日志中无 SharedProvider 相关输出。

### 4.3 清理

```bash
kubectl delete -f e2e-resources.yaml
```

---

## Result Sheet

在测试过程中填写以下对比表：

### 资源消耗对比

| 指标 | CLI 模式 (创建前) | CLI 模式 (创建后) | Shared 模式 (创建前) | Shared 模式 (创建后) |
|------|:-:|:-:|:-:|:-:|
| VmRSS (kB) | | | | |
| Threads | | | | |
| terraform-provider 进程数 | | | | |
| kubectl top CPU | | | | |
| kubectl top Memory | | | | |

### 功能对比

| 测试项 | CLI 模式 | Shared 模式 | 通过？ |
|--------|:-:|:-:|:-:|
| VPC Create → Ready | \_\_s | \_\_s | |
| Bucket Create → Ready | \_\_s | \_\_s | |
| RAM Role Create → Ready | \_\_s | \_\_s | |
| VPC Update (patch) | N/A | \_\_s | |
| 资源全部删除 | \_\_s | \_\_s | |
| 10 并发 Role 全部 Ready | N/A | \_\_s | |
| SharedProvider 进程数恒 = 1 | N/A | ☐ Yes / ☐ No | |
| 无 OOM / restart | ☐ | ☐ | |
| 回退 CLI 正常 | N/A | ☐ | |

### 预期改善

| 指标 | 预期 |
|------|------|
| terraform-provider 进程数 | CLI: N 个（每资源 1 个） → Shared: 固定 1 个 |
| 内存 (VmRSS) | Shared 模式应显著低于 CLI 模式（预估减少 50%+） |
| 首次 Ready 时间 | Shared 模式可能略快（省去 terraform init） |

---

## 判定标准

### 必须通过（P0）

- [ ] SharedProvider 模式下 3 种资源（VPC、OSS Bucket、RAM Role）CRUD 全部成功
- [ ] SharedProvider 日志中出现 `Forked new native provider` 且仅出现 1 次（证明进程复用）
- [ ] terraform-provider 进程数在并发测试中保持 ≤ `max-reconcile-rate` 值
- [ ] 无 panic、OOM kill 或 pod restart
- [ ] 回退 CLI 模式功能正常

### 应该通过（P1）

- [ ] Shared 模式内存低于 CLI 模式
- [ ] 10 并发 Role 全部 Ready 且无 timeout
- [ ] Update 操作在 Shared 模式下正常同步

### 最好通过（P2）

- [ ] Shared 模式首次 Ready 时间 ≤ CLI 模式
- [ ] 持续运行 30 分钟无内存泄漏（VmRSS 稳定）

---

## 故障排查

### SharedProvider 未启动

```bash
# 检查环境变量是否正确传递
kubectl exec -n crossplane-system "$PROVIDER_POD" -- env | grep TERRAFORM

# 检查 provider binary 路径是否存在
kubectl exec -n crossplane-system "$PROVIDER_POD" -- ls -la \
  /terraform/provider-mirror/registry.terraform.io/aliyun/alicloud/1.261.0/linux_amd64/
```

### 资源卡在 Creating 状态

```bash
# 查看详细事件
kubectl describe vpc e2e-shared-vpc

# 查看 provider 日志中的错误
kubectl logs -n crossplane-system "$PROVIDER_POD" 2>&1 | grep -i error | tail -20
```

### 进程数异常增长

```bash
# 查看所有 terraform 相关进程
kubectl exec -n crossplane-system "$PROVIDER_POD" -- ps aux | grep terraform

# 检查 TTL rotation 日志
kubectl logs -n crossplane-system "$PROVIDER_POD" 2>&1 | grep -i "ttl\|rotation\|stop"
```
