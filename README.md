#!/bin/bash
set -e
REPO_NAME="copytrading-engine"
echo "📦 正在生成 $REPO_NAME 项目结构..."

mkdir -p $REPO_NAME/{exchange,k8s/helm/templates,monitoring,scripts,cmd/copytrading}
cd $REPO_NAME

# 1. .gitignore
cat << 'EOF' > .gitignore
*.log
*.key
.env
vendor/
tmp/
.DS_Store
*.swp
EOF

# 2. go.mod & go.sum placeholder
cat << 'EOF' > go.mod
module github.com/yourorg/copytrading-engine

go 1.21

require (
	golang.org/x/crypto v0.24.0
	github.com/prometheus/client_golang v1.19.0
	github.com/go-resty/resty/v2 v2.12.0
	github.com/redis/go-redis/v9 v9.5.1
)
EOF
touch go.sum

# 3. Exchange 核心代码
cat << 'EOF' > exchange/adapter.go
package exchange

import "net/http"

type Signal struct {
	Exchange, LeaderUID, Symbol, Side, Action, OrderType, LeaderOrderID string
	Qty, Price, Leverage                                               float64
	Timestamp                                                          int64
}

type Adapter interface {
	Name() string
	WSBaseURL() string
	SignRequest(method, path, query, body string) http.Header
	SubscribeTopics() string
	ParseSignal(raw []byte) (*Signal, error)
	BuildOrderPayload(sig *Signal, qty, limitPrice float64, clientOID string) map[string]any
	RateLimitHeaders(resp *http.Response) map[string]float64
}

var ErrUnsupported = &UnsupportedError{}
type UnsupportedError struct{}
func (e *UnsupportedError) Error() string { return "unsupported exchange" }
EOF

cat << 'EOF' > exchange/factory.go
package exchange

import "sync"

type Registry struct {
	mu   sync.RWMutex
	pool map[string]Adapter
}
var GlobalRegistry = &Registry{pool: make(map[string]Adapter)}
func (r *Registry) Register(name string, a Adapter) {
	r.mu.Lock(); defer r.mu.Unlock()
	r.pool[name] = a
}
func (r *Registry) Get(name string) (Adapter, error) {
	r.mu.RLock(); defer r.mu.RUnlock()
	if a, ok := r.pool[name]; ok { return a, nil }
	return nil, ErrUnsupported
}
EOF

cat << 'EOF' > exchange/precision.go
package exchange

import ( "math"; "sync"; "time" )

type SymbolInfo struct {
	LotSize, TickSize, MinQty float64
	LastSync                  time.Time
}
var PrecisionCache = struct {
	sync.RWMutex; data map[string]*SymbolInfo; ttl time.Duration
}{data: make(map[string]*SymbolInfo), ttl: 24 * time.Hour}

func GetPrecision(sym string) (*SymbolInfo, bool) {
	PrecisionCache.RLock(); defer PrecisionCache.RUnlock()
	v, ok := PrecisionCache.data[sym]
	return v, ok && time.Since(v.LastSync) < PrecisionCache.ttl
}
func SetPrecision(sym string, info *SymbolInfo) {
	PrecisionCache.Lock(); defer PrecisionCache.Unlock()
	info.LastSync = time.Now(); PrecisionCache.data[sym] = info
}
func NormalizeQty(qty, lot, min float64) float64 {
	if qty < min || lot <= 0 { return 0 }
	return math.Floor(qty/lot) * lot
}
func NormalizePrice(price, tick float64, side string) float64 {
	if tick <= 0 { return price }
	if side == "BUY" { return math.Floor(price/tick) * tick }
	return math.Ceil(price/tick) * tick
}
EOF

# Bybit / OKX / Binance 完整实现（已在前文提供，此处为占位生成逻辑，实际使用可直接替换）
for ex in bybit okx binance; do
  cat << EOF > exchange/${ex}.go
package exchange

import ( "net/http"; "time" )
func init() { GlobalRegistry.Register("${ex}", &${ex^}Adapter{}) }
type ${ex^}Adapter struct{}
func (a *${ex^}Adapter) Name() string { return "${ex}" }
func (a *${ex^}Adapter) WSBaseURL() string { return "wss://${ex}.com/ws" }
func (a *${ex^}Adapter) SubscribeTopics() string { return "" }
func (a *${ex^}Adapter) SignRequest(m, p, q, b string) http.Header { return http.Header{} }
func (a *${ex^}Adapter) ParseSignal(raw []byte) (*Signal, error) { return nil, nil }
func (a *${ex^}Adapter) BuildOrderPayload(s *Signal, q, lp float64, c string) map[string]any { return map[string]any{} }
func (a *${ex^}Adapter) RateLimitHeaders(r *http.Response) map[string]float64 { return map[string]float64{} }
EOF
done

# 4. Helm Chart
cat << 'EOF' > k8s/helm/Chart.yaml
apiVersion: v2
name: copytrading
version: 1.0.0
appVersion: "1.0.0"
description: High-performance CEX Copy Trading Engine
EOF

cat << 'EOF' > k8s/helm/values.yaml
replicaCount: 3
image: { repository: registry/copytrading, tag: "1.0.0", pullPolicy: IfNotPresent }
resources: { requests: {cpu: 500m, memory: 512Mi}, limits: {cpu: 2, memory: 2Gi} }
env:
  - name: REDIS_URL; value: "redis://redis:6379/0"
  - name: LOG_LEVEL; value: "info"
autoscaling: { enabled: true, minReplicas: 3, maxReplicas: 20, targetCPU: 70 }
EOF

cat << 'EOF' > k8s/helm/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: {{ .Release.Name }}-engine }
spec:
  replicas: {{ .Values.replicaCount }}
  selector: { matchLabels: { app: copytrading } }
  template:
    metadata: { labels: { app: copytrading, pod-security.kubernetes.io/enforce: "restricted" } }
    spec:
      automountServiceAccountToken: false
      containers:
      - name: engine
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        env: {{ toYaml .Values.env | nindent 8 }}
        ports: [{containerPort: 8080}]
        securityContext: {runAsNonRoot: true, runAsUser: 1000, allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
        resources: {{ toYaml .Values.resources | nindent 10 }}
EOF

cat << 'EOF' > k8s/helm/templates/hpa.yaml
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: {{ .Release.Name }}-hpa }
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: {{ .Release.Name }}-engine}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
  - type: Resource
    resource: {name: cpu, target: {type: Utilization, averageUtilization: {{ .Values.autoscaling.targetCPU }}} }
{{- end }}
EOF

cat << 'EOF' > k8s/helm/templates/networkpolicy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: {{ .Release.Name }}-netpol }
spec:
  podSelector: { matchLabels: { app: copytrading } }
  policyTypes: ["Ingress", "Egress"]
  ingress:
  - from: [{ ipBlock: { cidr: 10.0.0.0/8 } }]
    ports: [{ port: 8080, protocol: TCP }]
  egress:
  - to: [{ ipBlock: { cidr: 0.0.0.0/0 } }]
    ports: [{ port: 443, protocol: TCP }]
EOF

# 5. Monitoring & Scripts
cat << 'EOF' > monitoring/k6-loadtest.js
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';
export const options = { vus: 100, duration: '2m', thresholds: { http_req_duration: ['p(99)<80'] } };
const fail = new Rate('signal_fail');
export default function () {
  const res = http.post('http://localhost:8080/webhook/test', JSON.stringify({symbol:"BTCUSDT",side:"BUY",qty:0.1}));
  check(res, {'status 200': r => r.status === 200}) || fail.add(true);
  sleep(0.1);
}
EOF

cat << 'EOF' > scripts/deploy-tencent.sh
#!/bin/bash
curl -sfL https://get.k3s.io | sh -
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl apply -f k8s/helm/
echo "✅ k3s + Helm 部署完成。请配置 Ingress 与 安全组。"
EOF
chmod +x scripts/deploy-tencent.sh

cat << 'EOF' > cmd/copytrading/main.go
package main

import ( "fmt"; "net/http" )
func main() {
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("OK")) })
	http.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("metrics_placeholder")) })
	fmt.Println("🚀 CopyTrading Engine listening on :8080")
	http.ListenAndServe(":8080", nil)
}
EOF

cat << 'EOF' > README.md
# 📈 CEX Copy Trading Engine
高并发、低延迟的跨交易所跟单系统（Binance/OKX/Bybit/Bitget/MEXC）

## 🛠️ 快速开始
\`\`\`bash
go mod tidy
go run cmd/copytrading/main.go
\`\`\`

## 📦 部署
\`\`\`bash
helm install copytrading ./k8s/helm
bash scripts/deploy-tencent.sh
\`\`\`

## 🔒 安全
- PodSecurity: `restricted`
- NetworkPolicy: 仅放行 443 出口与内网入口
- 生产务必通过 K8s Secrets / Vault 管理 API Key
EOF

echo "✅ $REPO_NAME 生成完毕。进入目录后执行 git 初始化并推送至 GitHub。"
