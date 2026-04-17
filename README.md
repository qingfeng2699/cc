# 1. 执行生成脚本
chmod +x init_repo.sh && ./init_repo.sh

# 2. 进入项目目录
cd copytrading-engine

# 3. 初始化 Git & 添加远程仓库
git init
git add .
git commit -m "feat: init copytrading engine with exchange adapters, k8s helm, k6 loadtest"

# 4. 推送到 GitHub（替换 YOUR_USERNAME 和 REPO）
git remote add origin https://github.com/YOUR_USERNAME/copytrading-engine.git
git branch -M main
git push -u origin main
