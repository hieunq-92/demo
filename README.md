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
- Ảnh trên S3 (bucket `hieunq92`, prefix `images/`):
  - `POST /images` – upload (form-data field `file`, chỉ nhận jpeg/png/gif/webp/svg, tối đa 10MB)
  - `GET /images` – danh sách ảnh
  - `GET /images/{id}` – tải ảnh về
  - `DELETE /images/{id}` – xoá ảnh

```bash
curl -F "file=@cat.png" http://localhost:4747/images
curl -o cat.png http://localhost:4747/images/<id>
```

Cấu hình qua biến môi trường: `S3_BUCKET`, `S3_PREFIX`, `AWS_REGION`, `MAX_IMAGE_SIZE_MB`.
Endpoint S3 lấy từ `AWS_ENDPOINT_URL` — container ECS trong Floci đã có sẵn `http://floci:4566`;
chạy local thì `export AWS_ENDPOINT_URL=http://localhost:4566 AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test`.
