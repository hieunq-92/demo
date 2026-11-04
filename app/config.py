from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_name: str = "demo-service"
    app_version: str = "0.1.0"
    environment: str = "local"


@lru_cache
def get_settings() -> Settings:
    return Settings()
