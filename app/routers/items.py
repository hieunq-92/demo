from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field

router = APIRouter(prefix="/items", tags=["items"])


class ItemIn(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    price: float = Field(ge=0)


class Item(ItemIn):
    id: int


# In-memory store for demo purposes.
_items: dict[int, Item] = {}
_next_id = 1


@router.get("", response_model=list[Item])
def list_items() -> list[Item]:
    return list(_items.values())


@router.post("", response_model=Item, status_code=status.HTTP_201_CREATED)
def create_item(payload: ItemIn) -> Item:
    global _next_id
    item = Item(id=_next_id, **payload.model_dump())
    _items[item.id] = item
    _next_id += 1
    return item


@router.get("/{item_id}", response_model=Item)
def get_item(item_id: int) -> Item:
    if item_id not in _items:
        raise HTTPException(status_code=404, detail="Item not found")
    return _items[item_id]


@router.delete("/{item_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_item(item_id: int) -> None:
    if _items.pop(item_id, None) is None:
        raise HTTPException(status_code=404, detail="Item not found")
