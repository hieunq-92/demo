from fastapi import FastAPI

from app.config import get_settings
from app.routers import items

settings = get_settings()

app = FastAPI(title=settings.app_name, version=settings.app_version)
app.include_router(items.router)


@app.get("/", tags=["root"])
def root() -> dict[str, str]:
    return {"message": f"Hello from {settings.app_name}"}


@app.get("/health", tags=["health"])
def health() -> dict[str, str]:
    return {
        "status": "ok",
        "version": settings.app_version,
        "environment": settings.environment,
    }
