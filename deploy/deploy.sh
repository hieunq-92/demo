#!/usr/bin/env bash
# Build image Python (FastAPI) + deploy len ECS trong Floci (may co Docker + Floci).
# Chay duoc tu GitHub Actions (self-hosted runner) hoac chay tay:
#    ./deploy/deploy.sh dev
# Can: bash (Linux/macOS hoac Git Bash tren Windows), docker, aws CLI, curl.
# Cau hinh khac qua bien moi truong, vd: CLUSTER=Demo2 ./deploy/deploy.sh dev
set -euo pipefail

IMAGE_TAG="${1:-local-$(date +%Y%m%d%H%M%S)}"
FAMILY="${FAMILY:-API-Testing-task}"
CLUSTER="${CLUSTER:-Demo}"
SERVICE="${SERVICE:-API-Testing}"
APP_PORT="${APP_PORT:-4747}"
DESIRED_COUNT="${DESIRED_COUNT:-1}"
HEALTH_PATH="${HEALTH_PATH:-/health}"
REGION="${REGION:-ap-southeast-1}"
ENDPOINT="${ENDPOINT:-http://localhost:4566}"
TIMEOUT_SEC="${TIMEOUT_SEC:-180}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

# ---- Floci credentials / endpoint (khong bao gio tro sang AWS that) ----
export AWS_ENDPOINT_URL="$ENDPOINT"
export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"
export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_PAGER=""

trap 'echo "Loi o dong $LINENO: $BASH_COMMAND" >&2' ERR

step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
die()  { echo "$*" >&2; exit 1; }
# aws.exe tren Windows tra ve CRLF -> bo \r
awsc() { aws "$@" | tr -d '\r'; }

# ---- 0. Kiem tra moi truong ----
# Runner co the khong co docker trong PATH (Docker Desktop cai theo user nam o AppData),
# nen tim o cac vi tri cai dat pho bien. Co the chi dinh thu muc bang DOCKER_BIN.
if ! command -v docker >/dev/null 2>&1; then
  for d in "${DOCKER_BIN:-}" \
           "/c/Program Files/Docker/Docker/resources/bin" \
           /c/Users/*/AppData/Local/Programs/DockerDesktop/resources/bin; do
    if [ -n "$d" ] && { [ -x "$d/docker.exe" ] || [ -x "$d/docker" ]; }; then
      export PATH="$d:$PATH"
      break
    fi
  done
fi
command -v docker >/dev/null 2>&1 || die "Khong tim thay docker, dat DOCKER_BIN=<thu muc chua docker>"
command -v aws >/dev/null 2>&1 || die "Khong tim thay aws CLI"

step "Kiem tra Docker va Floci"
docker version --format '{{.Server.Version}}' >/dev/null
curl -s -o /dev/null --max-time 5 "$ENDPOINT/" \
  || die "Khong goi duoc Floci tai $ENDPOINT. Floci da chay chua (docker compose up -d)?"

# ---- 1. Build image ----
IMAGE="$FAMILY:$IMAGE_TAG"
step "Build image $IMAGE"
docker build -t "$IMAGE" "$ROOT"

# ---- 2. Cluster ----
step "Dam bao cluster $CLUSTER ton tai"
active=$(awsc ecs describe-clusters --clusters "$CLUSTER" \
  --query "length(clusters[?status=='ACTIVE'])" --output text)
if [ "$active" != "1" ]; then
  awsc ecs create-cluster --cluster-name "$CLUSTER" --query cluster.status
fi

# ---- 3. Task definition ----
step "Dang ky task definition"
td_file=$(mktemp)
trap 'rm -f "$td_file"' EXIT
sed -e "s|__FAMILY__|$FAMILY|g" -e "s|__IMAGE__|$IMAGE|g" \
    -e "s|__PORT__|$APP_PORT|g" -e "s|__REGION__|$REGION|g" -e "s|__TAG__|$IMAGE_TAG|g" \
    "$SCRIPT_DIR/task-definition.json" > "$td_file"
td_path="$td_file"
# aws.exe (Windows) can duong dan dang C:/..., khong hieu /tmp/...
if command -v cygpath >/dev/null; then td_path=$(cygpath -m "$td_file"); fi
TD=$(awsc ecs register-task-definition --cli-input-json "file://$td_path" \
  --query taskDefinition.taskDefinitionArn --output text)
echo "Task definition: $TD"

# ---- 4. Subnet ----
subnet=$(awsc ec2 describe-subnets --query 'Subnets[0].SubnetId' --output text)
if [ -z "$subnet" ] || [ "$subnet" = "None" ]; then
  vpc=$(awsc ec2 create-vpc --cidr-block 10.0.0.0/16 --query Vpc.VpcId --output text)
  subnet=$(awsc ec2 create-subnet --vpc-id "$vpc" --cidr-block 10.0.1.0/24 \
    --query Subnet.SubnetId --output text)
fi

# ---- 5. Tao hoac cap nhat service ----
svc_active=$(awsc ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query "length(services[?status=='ACTIVE'])" --output text)
if [ "$svc_active" = "1" ]; then
  step "Cap nhat service $SERVICE"
  awsc ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
    --task-definition "$TD" --desired-count "$DESIRED_COUNT" \
    --query service.taskDefinition --output text
else
  step "Tao service $SERVICE"
  awsc ecs create-service --cluster "$CLUSTER" --service-name "$SERVICE" \
    --task-definition "$TD" --desired-count "$DESIRED_COUNT" --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$subnet]}" \
    --query service.status --output text
fi

# ---- 6. Dung task cu (Floci chua tu thay task khi doi revision) ----
# In moi task 1 dong: <taskArn> <taskDefinitionArn> <lastStatus>
get_tasks() {
  local arns
  arns=$(awsc ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" \
    --query taskArns --output text)
  if [ -z "$arns" ] || [ "$arns" = "None" ]; then return 0; fi
  # shellcheck disable=SC2086  # tach arns thanh nhieu tham so
  awsc ecs describe-tasks --cluster "$CLUSTER" --tasks $arns \
    --query 'tasks[].[taskArn,taskDefinitionArn,lastStatus]' --output text
}

step "Dung cac task chay revision cu"
tasks=$(get_tasks)
while read -r arn td _; do
  if [ -z "$arn" ] || [ "$td" = "$TD" ]; then continue; fi
  echo "  stop $arn (${td##*/})"
  awsc ecs stop-task --cluster "$CLUSTER" --task "$arn" --reason "deploy $IMAGE_TAG" \
    --query task.lastStatus --output text >/dev/null
done <<< "$tasks"

# ---- 7. Cho task moi RUNNING ----
step "Cho task moi RUNNING (toi da $TIMEOUT_SEC giay)"
deadline=$(( $(date +%s) + TIMEOUT_SEC ))
new_task=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  tasks=$(get_tasks)
  new_task=$(awk -v td="$TD" '$2 == td && $3 == "RUNNING" { print $1; exit }' <<< "$tasks")
  if [ -n "$new_task" ]; then break; fi
  sleep 3
done
if [ -z "$new_task" ]; then
  stopped=$(awsc ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" \
    --desired-status STOPPED --query taskArns --output text)
  if [ -n "$stopped" ] && [ "$stopped" != "None" ]; then
    # shellcheck disable=SC2086
    awsc ecs describe-tasks --cluster "$CLUSTER" --tasks $stopped \
      --query 'tasks[].{td:taskDefinitionArn,reason:stoppedReason}' --output table
  fi
  die "Task moi khong RUNNING sau $TIMEOUT_SEC giay."
fi
task_id="${new_task##*/}"
echo "Task RUNNING: $task_id"

# ---- 8. Tim host port va health check ----
step "Health check"
container="floci-aws-ecs-$task_id-app"
host_port=""
for _ in $(seq 20); do
  mapping=$(docker port "$container" "$APP_PORT/tcp" 2>/dev/null | head -n1 | tr -d '\r' || true)
  host_port=$(sed -n 's/.*:\([0-9]*\)$/\1/p' <<< "$mapping")
  if [ -n "$host_port" ]; then break; fi
  sleep 1
done
if [ -z "$host_port" ]; then
  die "Container $container khong publish port $APP_PORT. Kiem tra FLOCI_SERVICES_ECS_PUBLISH_AWSVPC_PORTS_TO_HOST=true trong docker-compose.yml cua Floci."
fi

url="http://localhost:$host_port$HEALTH_PATH"
ok=""
for _ in $(seq 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url" || true)
  if [ "$code" -gt 0 ] && [ "$code" -lt 500 ]; then ok=1; break; fi
  sleep 2
done
if [ -z "$ok" ]; then
  printf '\033[33m--- docker logs %s ---\033[0m\n' "$container"
  docker logs --tail 50 "$container" || true
  die "Health check that bai: $url"
fi

printf '\n\033[32mDeploy OK: %s -> %s\033[0m\n' "$IMAGE" "$url"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '### Deploy len Floci thanh cong\n- Image: `%s`\n- Task definition: `%s`\n- URL: %s\n' \
    "$IMAGE" "$TD" "$url" >> "$GITHUB_STEP_SUMMARY"
fi

# ---- 9. Don image cu (giu 5 ban moi nhat) ----
docker images "$FAMILY" --format '{{.Repository}}:{{.Tag}}' | tr -d '\r' | tail -n +6 |
  while read -r img; do docker rmi "$img" >/dev/null 2>&1 || true; done
