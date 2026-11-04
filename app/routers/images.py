import mimetypes
import uuid
from pathlib import PurePath
from typing import Annotated, Any

from botocore.exceptions import ClientError
from fastapi import APIRouter, Depends, HTTPException, UploadFile, status
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from app.config import Settings, get_settings
from app.s3 import get_s3_client

router = APIRouter(prefix="/images", tags=["images"])

ALLOWED_TYPES = {"image/jpeg", "image/png", "image/gif", "image/webp", "image/svg+xml"}

S3Client = Annotated[Any, Depends(get_s3_client)]
AppSettings = Annotated[Settings, Depends(get_settings)]


class ImageInfo(BaseModel):
    id: str
    key: str
    size: int
    content_type: str | None = None
    url: str


def _info(settings: Settings, key: str, size: int, content_type: str | None = None) -> ImageInfo:
    image_id = key.removeprefix(settings.s3_prefix)
    return ImageInfo(
        id=image_id,
        key=key,
        size=size,
        content_type=content_type or mimetypes.guess_type(key)[0],
        url=f"/images/{image_id}",
    )


@router.post("", response_model=ImageInfo, status_code=status.HTTP_201_CREATED)
def upload_image(
    file: UploadFile,
    s3: S3Client,
    settings: AppSettings,
) -> ImageInfo:
    content_type = file.content_type or mimetypes.guess_type(file.filename or "")[0]
    if content_type not in ALLOWED_TYPES:
        raise HTTPException(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            detail=f"Chi nhan anh: {', '.join(sorted(ALLOWED_TYPES))}",
        )

    data = file.file.read(settings.max_image_size_mb * 1024 * 1024 + 1)
    if len(data) > settings.max_image_size_mb * 1024 * 1024:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"Anh toi da {settings.max_image_size_mb}MB",
        )
    if not data:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="File rong")

    ext = PurePath(file.filename or "").suffix.lower() or mimetypes.guess_extension(content_type)
    key = f"{settings.s3_prefix}{uuid.uuid4().hex}{ext or ''}"
    s3.put_object(
        Bucket=settings.s3_bucket,
        Key=key,
        Body=data,
        ContentType=content_type,
        Metadata={"original-filename": file.filename or ""},
    )
    return _info(settings, key, len(data), content_type)


@router.get("", response_model=list[ImageInfo])
def list_images(
    s3: S3Client,
    settings: AppSettings,
) -> list[ImageInfo]:
    paginator = s3.get_paginator("list_objects_v2")
    return [
        _info(settings, obj["Key"], obj["Size"])
        for page in paginator.paginate(Bucket=settings.s3_bucket, Prefix=settings.s3_prefix)
        for obj in page.get("Contents", [])
    ]


@router.get("/{image_id}")
def get_image(
    image_id: str,
    s3: S3Client,
    settings: AppSettings,
) -> StreamingResponse:
    try:
        obj = s3.get_object(Bucket=settings.s3_bucket, Key=f"{settings.s3_prefix}{image_id}")
    except ClientError as e:
        if e.response["Error"]["Code"] in ("NoSuchKey", "404"):
            raise HTTPException(status_code=404, detail="Image not found") from e
        raise
    return StreamingResponse(
        obj["Body"].iter_chunks(),
        media_type=obj.get("ContentType", "application/octet-stream"),
        headers={"Content-Length": str(obj["ContentLength"])},
    )


@router.delete("/{image_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_image(
    image_id: str,
    s3: S3Client,
    settings: AppSettings,
) -> None:
    key = f"{settings.s3_prefix}{image_id}"
    try:
        s3.head_object(Bucket=settings.s3_bucket, Key=key)
    except ClientError as e:
        raise HTTPException(status_code=404, detail="Image not found") from e
    s3.delete_object(Bucket=settings.s3_bucket, Key=key)
