# 1. Go 依赖整理 & 编译检查
go mod tidy
go build ./cmd/copytrading/

# 2. Helm 模板渲染验证（无 K8s 集群也可跑）
helm template copytrading k8s/helm/ --debug > /dev/null && echo "✅ Helm 语法正确"

# 3. k6 本地冒烟测试
k6 run monitoring/k6-loadtest.js
