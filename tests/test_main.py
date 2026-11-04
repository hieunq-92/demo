from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_root():
    resp = client.get("/")
    assert resp.status_code == 200
    assert "message" in resp.json()


def test_health():
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok1234"


def test_item_crud():
    resp = client.post("/items", json={"name": "book", "price": 9.5})
    assert resp.status_code == 201
    item = resp.json()
    assert item["name"] == "book"

    resp = client.get(f"/items/{item['id']}")
    assert resp.status_code == 200
    assert resp.json() == item

    assert item in client.get("/items").json()

    assert client.delete(f"/items/{item['id']}").status_code == 204
    assert client.get(f"/items/{item['id']}").status_code == 404


def test_create_item_validation():
    resp = client.post("/items", json={"name": "", "price": -1})
    assert resp.status_code == 422
