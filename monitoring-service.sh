#!/bin/bash

# Rocky Linux 8 모니터링 서비스 관리 스크립트

set -e

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

# 서비스 상태 확인
check_status() {
    log_header "모니터링 서비스 상태 확인"
    docker-compose ps
    echo ""
    
    # 포트 확인
    log_info "포트 상태 확인:"
    echo "Prometheus (9090): $(ss -tlnp | grep :9090 || echo '닫힘')"
    echo "Grafana (3000): $(ss -tlnp | grep :3000 || echo '닫힘')"
    echo "Node Exporter (9100): $(ss -tlnp | grep :9100 || echo '닫힘')"
    echo ""
    
    # 시스템 리소스 확인
    log_info "시스템 리소스 사용량:"
    echo "CPU 사용률: $(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)%"
    echo "메모리 사용률: $(free | grep Mem | awk '{printf("%.1f%%", $3/$2 * 100.0)}')"
    echo "디스크 사용률: $(df -h / | awk 'NR==2 {print $5}')"
    echo ""

    # 시스템 업타임 및 Load Average 추가
    log_info "시스템 업타임:"
    uptime -p
    log_info "Load Average:"
    uptime | awk -F'load average:' '{ print $2 }'
    echo ""

    # 네트워크 트래픽 (eth0 기준)
    log_info "네트워크 트래픽 (eth0, 1초 단위):"
    RX1=$(cat /sys/class/net/eth0/statistics/rx_bytes)
    TX1=$(cat /sys/class/net/eth0/statistics/tx_bytes)
    sleep 1
    RX2=$(cat /sys/class/net/eth0/statistics/rx_bytes)
    TX2=$(cat /sys/class/net/eth0/statistics/tx_bytes)
    echo "수신: $(( (RX2 - RX1) / 1024 )) KB/s, 송신: $(( (TX2 - TX1) / 1024 )) KB/s"
    echo ""

    # 파일 디스크립터
    log_info "파일 디스크립터:"
    OPEN_FD=$(cat /proc/sys/fs/file-nr | awk '{print $1}')
    MAX_FD=$(cat /proc/sys/fs/file-max)
    echo "열린 파일 디스크립터: $OPEN_FD / 최대: $MAX_FD"
    echo ""

    # 프로세스 수
    log_info "프로세스 수:"
    echo "현재 실행 중인 프로세스: $(ps -e --no-headers | wc -l)"
    echo ""
}

# 서비스 시작
start_services() {
    log_header "모니터링 서비스 시작"
    
    # Docker 서비스 확인
    if ! systemctl is-active --quiet docker; then
        log_warn "Docker 서비스가 실행되지 않았습니다. 시작 중..."
        sudo systemctl start docker
    fi
    
    # 서비스 시작
    log_info "Docker Compose로 서비스 시작 중..."
    docker-compose up -d
    
    # 시작 확인
    sleep 5
    check_status
    
    log_info "서비스 접속 정보:"
    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo "Grafana: http://$SERVER_IP:3000 (admin/admin)"
    echo "Prometheus: http://$SERVER_IP:9090"
    echo "Node Exporter: http://$SERVER_IP:9100"
}

# 서비스 중지
stop_services() {
    log_header "모니터링 서비스 중지"
    docker-compose down
    log_info "모든 서비스가 중지되었습니다."
}

# 서비스 재시작
restart_services() {
    log_header "모니터링 서비스 재시작"
    docker-compose down
    sleep 2
    docker-compose up -d
    sleep 5
    check_status
}

# 로그 확인
show_logs() {
    log_header "서비스 로그 확인"
    echo "1. 전체 로그"
    echo "2. Prometheus 로그"
    echo "3. Grafana 로그"
    echo "4. Node Exporter 로그"
    echo "5. 실시간 로그 (Ctrl+C로 종료)"
    echo ""
    read -p "선택하세요 (1-5): " choice
    
    case $choice in
        1) docker-compose logs ;;
        2) docker-compose logs prometheus ;;
        3) docker-compose logs grafana ;;
        4) docker-compose logs node-exporter ;;
        5) docker-compose logs -f ;;
        *) log_error "잘못된 선택입니다." ;;
    esac
}

# 백업 및 복원
backup_restore() {
    log_header "백업 및 복원"
    echo "1. 데이터 백업"
    echo "2. 데이터 복원"
    echo ""
    read -p "선택하세요 (1-2): " choice
    
    case $choice in
        1)
            log_info "데이터 백업 중..."
            BACKUP_DIR="backup_$(date +%Y%m%d_%H%M%S)"
            mkdir -p $BACKUP_DIR
            docker run --rm -v prometheus_data:/data -v $(pwd)/$BACKUP_DIR:/backup alpine tar czf /backup/prometheus_data.tar.gz -C /data .
            docker run --rm -v grafana_data:/data -v $(pwd)/$BACKUP_DIR:/backup alpine tar czf /backup/grafana_data.tar.gz -C /data .
            log_info "백업 완료: $BACKUP_DIR/"
            ;;
        2)
            log_warn "복원을 위해 서비스를 중지합니다."
            docker-compose down
            read -p "백업 디렉토리 경로를 입력하세요: " backup_path
            if [ -d "$backup_path" ]; then
                log_info "데이터 복원 중..."
                docker run --rm -v prometheus_data:/data -v $(pwd)/$backup_path:/backup alpine tar xzf /backup/prometheus_data.tar.gz -C /data
                docker run --rm -v grafana_data:/data -v $(pwd)/$backup_path:/backup alpine tar xzf /backup/grafana_data.tar.gz -C /data
                log_info "복원 완료. 서비스를 시작합니다."
                docker-compose up -d
            else
                log_error "백업 디렉토리를 찾을 수 없습니다: $backup_path"
            fi
            ;;
        *) log_error "잘못된 선택입니다." ;;
    esac
}

# 시스템 정보
system_info() {
    log_header "시스템 정보"
    echo "OS: $(cat /etc/redhat-release)"
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(uname -m)"
    echo "Hostname: $(hostname)"
    echo "IP Address: $(hostname -I | awk '{print $1}')"
    echo "Docker Version: $(docker --version)"
    echo "Docker Compose Version: $(docker-compose --version)"
    echo ""
    
    log_info "시스템 리소스:"
    echo "CPU: $(nproc) cores"
    echo "Memory: $(free -h | grep Mem | awk '{print $2}')"
    echo "Disk: $(df -h / | awk 'NR==2 {print $2}')"
    echo ""
}

# 메인 메뉴
show_menu() {
    echo ""
    log_header "Rocky Linux 8 모니터링 서비스 관리"
    echo "1. 서비스 시작"
    echo "2. 서비스 중지"
    echo "3. 서비스 재시작"
    echo "4. 상태 확인"
    echo "5. 로그 확인"
    echo "6. 백업/복원"
    echo "7. 시스템 정보"
    echo "8. 종료"
    echo ""
}

# 메인 루프
main() {
    while true; do
        show_menu
        read -p "선택하세요 (1-8): " choice
        
        case $choice in
            1) start_services ;;
            2) stop_services ;;
            3) restart_services ;;
            4) check_status ;;
            5) show_logs ;;
            6) backup_restore ;;
            7) system_info ;;
            8) 
                log_info "프로그램을 종료합니다."
                exit 0
                ;;
            *) log_error "잘못된 선택입니다. 다시 시도하세요." ;;
        esac
        
        echo ""
        read -p "계속하려면 Enter를 누르세요..."
    done
}

# 스크립트 실행
if [ "$1" = "start" ]; then
    start_services
elif [ "$1" = "stop" ]; then
    stop_services
elif [ "$1" = "restart" ]; then
    restart_services
elif [ "$1" = "status" ]; then
    check_status
elif [ "$1" = "logs" ]; then
    show_logs
else
    main
fi 
