from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_name: str = "demo-service"
    app_version: str = "0.1.0"
    environment: str = "local"

    # S3. Endpoint/credentials lay tu bien moi truong chuan cua AWS SDK
    # (AWS_ENDPOINT_URL, AWS_ACCESS_KEY_ID, ...); Floci tu set san cho container ECS.
    s3_bucket: str = "hieunq92"
    s3_prefix: str = "images/"
    aws_region: str = "ap-southeast-1"
    max_image_size_mb: int = 10


@lru_cache
def get_settings() -> Settings:
    return Settings()
