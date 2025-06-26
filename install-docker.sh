#!/bin/bash

# Rocky Linux 8 Docker 설치 및 모니터링 시스템 설정 스크립트

set -e

echo "=== Rocky Linux 8 Docker 설치 및 모니터링 시스템 설정 ==="

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 로그 함수
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_header() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

# 에러 처리 함수
handle_error() {
    log_error "스크립트 실행 중 오류가 발생했습니다: $1"
    exit 1
}

# 트랩 설정
trap 'handle_error "예상치 못한 오류"' ERR

# 시스템 업데이트
log_header "시스템 패키지 업데이트"
log_info "시스템 패키지 업데이트 중..."
sudo dnf update -y || log_warn "패키지 업데이트 중 일부 오류가 발생했습니다."

# 필요한 패키지 설치
log_header "필요한 패키지 설치"
log_info "필요한 패키지 설치 중..."
sudo dnf install -y yum-utils device-mapper-persistent-data lvm2 || handle_error "필수 패키지 설치 실패"

# Docker 저장소 추가
log_header "Docker 저장소 추가"
log_info "Docker 저장소 추가 중..."
sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || handle_error "Docker 저장소 추가 실패"

# Docker 설치
log_header "Docker 설치"
log_info "Docker 설치 중..."
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || handle_error "Docker 설치 실패"

# Docker 서비스 시작 및 활성화
log_header "Docker 서비스 설정"
log_info "Docker 서비스 시작 중..."
sudo systemctl start docker || handle_error "Docker 서비스 시작 실패"
sudo systemctl enable docker || log_warn "Docker 서비스 자동 시작 설정 실패"

# 현재 사용자를 docker 그룹에 추가
log_info "현재 사용자를 docker 그룹에 추가 중..."
sudo usermod -aG docker $USER || handle_error "Docker 그룹 추가 실패"

# Docker Compose 설치 확인
log_header "Docker Compose 설치 확인"
log_info "Docker Compose 설치 확인 중..."
if ! command -v docker-compose &> /dev/null; then
    log_info "Docker Compose 설치 중..."
    sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose || handle_error "Docker Compose 다운로드 실패"
    sudo chmod +x /usr/local/bin/docker-compose || handle_error "Docker Compose 권한 설정 실패"
    sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose || log_warn "Docker Compose 심볼릭 링크 생성 실패"
fi

# 방화벽 설정
log_header "방화벽 설정"
log_info "방화벽 포트 열기 중..."
if systemctl is-active --quiet firewalld; then
    sudo firewall-cmd --permanent --add-port=9090/tcp || log_warn "Prometheus 포트 설정 실패"
    sudo firewall-cmd --permanent --add-port=3000/tcp || log_warn "Grafana 포트 설정 실패"
    sudo firewall-cmd --permanent --add-port=9100/tcp || log_warn "Node Exporter 포트 설정 실패"
    sudo firewall-cmd --reload || log_warn "방화벽 재로드 실패"
else
    log_warn "FirewallD가 실행되지 않고 있습니다. 수동으로 포트를 열어주세요."
fi

# SELinux 설정 (필요한 경우)
log_header "SELinux 설정"
if command -v getenforce &> /dev/null; then
    SELINUX_STATUS=$(getenforce)
    if [ "$SELINUX_STATUS" = "Enforcing" ]; then
        log_warn "SELinux가 활성화되어 있습니다. 컨테이너 실행을 위해 설정을 조정합니다."
        sudo setsebool -P container_manage_cgroup 1 || log_warn "SELinux 설정 조정 실패"
    fi
fi

# 모니터링 시스템 설정 파일 생성
log_header "모니터링 시스템 설정 파일 생성"
log_info "필요한 설정 파일들을 생성 중..."

# prometheus.yml 생성
log_info "Prometheus 설정 파일 생성 중..."
mkdir -p prometheus
cat > prometheus/prometheus.yml << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  # - "first_rules.yml"
  # - "second_rules.yml"

scrape_configs:
  # Prometheus 자체 모니터링
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # Node Exporter 모니터링
  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']
    scrape_interval: 5s

  # Grafana 모니터링 (선택사항)
  - job_name: 'grafana'
    static_configs:
      - targets: ['grafana:3000']
    metrics_path: /metrics
EOF

# Grafana 설정 파일 생성
log_info "Grafana 설정 파일 생성 중..."
mkdir -p grafana/provisioning/datasources
mkdir -p grafana/provisioning/dashboards

# 데이터소스 설정
cat > grafana/provisioning/datasources/datasource.yml << 'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
EOF

# 대시보드 설정
cat > grafana/provisioning/dashboards/dashboard.yml << 'EOF'
apiVersion: 1

providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /etc/grafana/provisioning/dashboards
EOF

# Node Exporter 대시보드 생성
# 아래 구간은 수동 관리로 전환하므로 주석 처리
# cat > grafana/provisioning/dashboards/node-exporter-dashboard.json << 'EOF'
# {
#   "annotations": {
#     "list": [
#       {
#         "builtIn": 1,
#         "datasource": "-- Grafana --",
#         "enable": true,
#         "hide": true,
#         "iconColor": "rgba(0, 211, 255, 1)",
#         "name": "Annotations & Alerts",
#         "type": "dashboard"
#       }
#     ]
#   },
#   "editable": true,
#   "gnetId": null,
#   "graphTooltip": 0,
#   "id": null,
#   "links": [],
#   "panels": [
#     ... (중략) ...
#   ],
#   "schemaVersion": 26,
#   "style": "dark",
#   "tags": [],
#   "templating": {
#     "list": []
#   },
#   "time": {
#     "from": "now-1h",
#     "to": "now"
#   },
#   "timepicker": {},
#   "timezone": "",
#   "title": "Node Exporter Dashboard",
#   "uid": "node-exporter",
#   "version": 1
# }
# EOF

# 파일 권한 설정
log_info "파일 권한 설정 중..."
chmod 644 prometheus/prometheus.yml
chmod 644 grafana/provisioning/datasources/datasource.yml
chmod 644 grafana/provisioning/dashboards/dashboard.yml
chmod 644 grafana/provisioning/dashboards/node-exporter-dashboard.json

# 디렉토리 권한 설정
log_info "디렉토리 권한 설정 중..."
sudo mkdir -p /opt/monitoring
sudo chown -R $USER:$USER /opt/monitoring

# Docker 설치 확인
log_header "설치 확인"
log_info "Docker 설치 확인 중..."
if docker --version; then
    log_info "Docker 설치 완료!"
else
    log_error "Docker 설치에 실패했습니다."
    exit 1
fi

# Docker Compose 설치 확인
if docker-compose --version; then
    log_info "Docker Compose 설치 완료!"
else
    log_error "Docker Compose 설치에 실패했습니다."
    exit 1
fi

# 최종 완료 메시지
echo ""
log_header "=== 설치 완료 ==="
log_info "모든 설정이 완료되었습니다!"
echo ""
log_info "다음 단계:"
log_info "1. 새 터미널 세션을 시작하거나 다음 명령어를 실행하세요:"
log_info "   newgrp docker"
echo ""
log_info "2. 모니터링 시스템을 시작하려면:"
log_info "   docker-compose up -d"
echo ""
log_info "3. 서비스 접속 정보:"
SERVER_IP=$(hostname -I | awk '{print $1}')
log_info "   - Grafana: http://$SERVER_IP:3000 (admin/admin)"
log_info "   - Prometheus: http://$SERVER_IP:9090"
log_info "   - Node Exporter: http://$SERVER_IP:9100"
echo ""
log_info "4. 서비스 관리를 위해 다음 명령어를 사용하세요:"
log_info "   ./monitoring-service.sh"
echo ""
log_info "설치가 성공적으로 완료되었습니다! 🎉"
echo ""

# 강제로 출력 버퍼 플러시
sync 
