#!/usr/bin/env bash
# Build image, push len ECR cua Floci va deploy ECS service.
# Chay: ./deploy/deploy.sh <image-tag>
# Tuy chinh qua bien moi truong: CLUSTER, SERVICE, FAMILY, REPOSITORY, REGION, ENDPOINT,
# SUBNET, CONTAINER_PORT, TIMEOUT_SEC
set -euo pipefail

IMAGE_TAG="${1:?Can truyen image tag, vd: ./deploy/deploy.sh abc1234}"
CLUSTER="${CLUSTER:-Demo}"
SERVICE="${SERVICE:-API-Testing}"
FAMILY="${FAMILY:-API-Testing-task}"
REPOSITORY="${REPOSITORY:-demo-service}"
REGION="${REGION:-ap-southeast-1}"
ENDPOINT="${ENDPOINT:-http://localhost:4566}"
SUBNET="${SUBNET:-subnet-default-${REGION}-a}"
CONTAINER_PORT="${CONTAINER_PORT:-4747}"
TIMEOUT_SEC="${TIMEOUT_SEC:-120}"

# Floci chap nhan credentials bat ky
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$REGION" AWS_PAGER=""
# Git Bash tren Windows: khong tu doi duong dan /... trong tham so
export MSYS_NO_PATHCONV=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# aws.exe tren Windows tra ve CRLF, bo \r de so sanh chuoi cho dung
awsf() { aws --endpoint-url "$ENDPOINT" "$@" | tr -d '\r'; }
log() { echo "==> $*"; }

log "Kiem tra Floci tai $ENDPOINT"
ACCOUNT="$(awsf sts get-caller-identity --query Account --output text)"

# 1. ECR repository (tao neu chua co)
if [ -z "$(awsf ecr describe-repositories --query "repositories[?repositoryName=='$REPOSITORY'].repositoryName" --output text)" ]; then
  log "Tao ECR repository $REPOSITORY"
  awsf ecr create-repository --repository-name "$REPOSITORY" >/dev/null
fi

# 2. Build va push image.
# Docker 29 (containerd store) khong push duoc qua hostname *.localhost, nen push thang
# vao registry ben duoi cua Floci theo duong dan <account>/<region>/<repo>.
REGISTRY_CONTAINER="$(docker ps --filter 'name=ecr-registry' --format '{{.Names}}' | head -n1)"
[ -n "$REGISTRY_CONTAINER" ] || { echo "Khong tim thay container registry cua Floci ECR" >&2; exit 1; }
REGISTRY_PORT="$(docker port "$REGISTRY_CONTAINER" 5000 | head -n1 | awk -F: '{print $NF}')"
IMAGE="localhost:${REGISTRY_PORT}/${ACCOUNT}/${REGION}/${REPOSITORY}:${IMAGE_TAG}"

log "Build $IMAGE"
docker build -t "$IMAGE" .
log "Push $IMAGE"
docker push "$IMAGE"

# 3. Cluster
if [ -z "$(awsf ecs describe-clusters --clusters "$CLUSTER" --query "clusters[?status=='ACTIVE'].clusterName" --output text)" ]; then
  log "Tao ECS cluster $CLUSTER"
  awsf ecs create-cluster --cluster-name "$CLUSTER" >/dev/null
fi

# 4. Task definition moi (file tam de trong repo, duong dan tuong doi cho aws.exe doc duoc)
TD_FILE="deploy/.taskdef.rendered.json"
trap 'rm -f "$TD_FILE"' EXIT
sed -e "s|__FAMILY__|$FAMILY|" -e "s|__IMAGE__|$IMAGE|" -e "s|__TAG__|$IMAGE_TAG|" \
  -e "s|__PORT__|$CONTAINER_PORT|g" deploy/task-definition.json > "$TD_FILE"
TASK_DEF_ARN="$(awsf ecs register-task-definition --cli-input-json "file://$TD_FILE" \
  --query 'taskDefinition.taskDefinitionArn' --output text)"
log "Task definition: $TASK_DEF_ARN"

# 5. Tao moi hoac cap nhat service
if [ -n "$(awsf ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query "services[?status=='ACTIVE'].serviceName" --output text)" ]; then
  log "Cap nhat service $SERVICE"
  awsf ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
    --task-definition "$TASK_DEF_ARN" --force-new-deployment >/dev/null
else
  log "Tao service $SERVICE"
  awsf ecs create-service --cluster "$CLUSTER" --service-name "$SERVICE" \
    --task-definition "$TASK_DEF_ARN" --desired-count 1 --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET]}" >/dev/null
fi

# 6. Doi task moi RUNNING va /health tra ve ok
log "Doi task moi chay (toi da ${TIMEOUT_SEC}s)"
deadline=$(( $(date +%s) + TIMEOUT_SEC ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep 3
  task_arns="$(awsf ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" \
    --desired-status RUNNING --query 'taskArns' --output text)"
  [ -n "$task_arns" ] && [ "$task_arns" != "None" ] || continue

  # shellcheck disable=SC2086
  task_arn="$(awsf ecs describe-tasks --cluster "$CLUSTER" --tasks $task_arns \
    --query "tasks[?taskDefinitionArn=='$TASK_DEF_ARN' && lastStatus=='RUNNING'].taskArn | [0]" --output text)"
  [ -n "$task_arn" ] && [ "$task_arn" != "None" ] || continue

  task_id="${task_arn##*/}"
  container="$(docker ps --filter "name=$task_id" --format '{{.Names}}' | head -n1)"
  [ -n "$container" ] || container="$(docker ps --filter "ancestor=$IMAGE" --format '{{.Names}}' | head -n1)"
  [ -n "$container" ] || continue

  host_port="$(docker port "$container" "$CONTAINER_PORT" 2>/dev/null | head -n1 | awk -F: '{print $NF}')"
  [ -n "$host_port" ] || continue

  url="http://localhost:$host_port"
  if curl -fs --max-time 3 "$url/health" | grep -q '"status":"ok"'; then
    log "Deploy thanh cong: $url"
    exit 0
  fi
done

log "Su kien gan nhat cua service:"
awsf ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].events[0:5].message' --output text || true
echo "Task moi khong healthy sau ${TIMEOUT_SEC}s" >&2
exit 1
