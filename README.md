# demo-service

FastAPI service mẫu với CI/CD bằng GitHub Actions.

## Chạy local

```bash
python -m venv .venv
.venv\Scripts\activate          # Windows  (Linux/macOS: source .venv/bin/activate)
pip install -r requirements-dev.txt
uvicorn app.main:app --reload
```

Mở http://localhost:8000/docs để xem Swagger UI.

## Test & lint

```bash
pytest --cov=app
ruff check . && ruff format --check .
```

## Docker

```bash
docker compose up --build
```

## CI/CD (deploy lên Floci)

Workflow [.github/workflows/ci.yml](.github/workflows/ci.yml):

| Job | Chạy ở | Khi nào | Việc làm |
|---|---|---|---|
| `test` | `ubuntu-latest` | PR, push `main`, chạy tay | ruff, pytest, kiểm tra import app |
| `deploy` | self-hosted runner `[self-hosted, floci]` | push `main`, chạy tay | chạy [deploy/deploy.sh](deploy/deploy.sh) |

`deploy.sh` làm: build image → push lên ECR của Floci → đăng ký task definition mới → tạo/cập nhật ECS service (cluster `Demo`, service `API-Testing`, task family `API-Testing-task`, port `4747`, region `ap-southeast-1`) → đợi task mới trả `/health` ok và in URL.

Floci chạy trên máy local nên GitHub runner không gọi tới được — cần cài **self-hosted runner** trên chính máy chạy Floci (Settings → Actions → Runners → New self-hosted runner, thêm label `floci`). Máy đó cần Docker, AWS CLI, `bash` và `curl` (trên Windows dùng Git Bash).

Deploy tay không qua CI:

```bash
./deploy/deploy.sh dev1
# đổi cluster/service: CLUSTER=Demo SERVICE=my-api FAMILY=my-api-task CONTAINER_PORT=8000 ./deploy/deploy.sh dev1
```

## API

- `GET /` – hello
- `GET /health` – health check
- `GET /items`, `POST /items`, `GET /items/{id}`, `DELETE /items/{id}`
