import boto3
import pytest
from fastapi.testclient import TestClient
from moto import mock_aws

from app.config import get_settings
from app.main import app
from app.s3 import get_s3_client

PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 32


@pytest.fixture
def client(monkeypatch):
    # Khong de test goi nham sang Floci/AWS that
    monkeypatch.delenv("AWS_ENDPOINT_URL", raising=False)
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "test")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "test")
    settings = get_settings()
    with mock_aws():
        s3 = boto3.client("s3", region_name=settings.aws_region)
        s3.create_bucket(
            Bucket=settings.s3_bucket,
            CreateBucketConfiguration={"LocationConstraint": settings.aws_region},
        )
        app.dependency_overrides[get_s3_client] = lambda: s3
        yield TestClient(app)
        app.dependency_overrides.clear()


def test_upload_get_list_delete(client):
    resp = client.post("/images", files={"file": ("cat.png", PNG, "image/png")})
    assert resp.status_code == 201
    info = resp.json()
    assert info["id"].endswith(".png")
    assert info["size"] == len(PNG)

    resp = client.get(info["url"])
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "image/png"
    assert resp.content == PNG

    assert [i["id"] for i in client.get("/images").json()] == [info["id"]]

    assert client.delete(info["url"]).status_code == 204
    assert client.get(info["url"]).status_code == 404


def test_upload_rejects_non_image(client):
    resp = client.post("/images", files={"file": ("a.txt", b"hello", "text/plain")})
    assert resp.status_code == 415


def test_upload_rejects_empty(client):
    resp = client.post("/images", files={"file": ("a.png", b"", "image/png")})
    assert resp.status_code == 400


def test_get_missing_image(client):
    assert client.get("/images/khong-co.png").status_code == 404
    assert client.delete("/images/khong-co.png").status_code == 404
