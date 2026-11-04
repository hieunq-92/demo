from functools import lru_cache

import boto3
from botocore.config import Config

from app.config import get_settings


@lru_cache
def get_s3_client():
    settings = get_settings()
    # Path-style: Floci/local khong resolve duoc <bucket>.<host>
    return boto3.client(
        "s3",
        region_name=settings.aws_region,
        config=Config(s3={"addressing_style": "path"}),
    )
