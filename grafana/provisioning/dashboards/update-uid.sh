#!/bin/bash

# 오늘 날짜를 YYYYMMDD 형식으로 변수에 저장
DATE=$(date +%Y%m%d)

# 대시보드 JSON 파일 경로
DASHBOARD_JSON="grafana/provisioning/dashboards/node-exporter-dashboard.json"

# sed로 uid 값을 자동 치환
sed -i "s/\"uid\": \".*\"/\"uid\": \"node-exporter-comprehensive-$DATE\"/" "$DASHBOARD_JSON"

echo "UID가 자동으로 node-exporter-comprehensive-$DATE 로 변경되었습니다."
