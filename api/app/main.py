import logging
import time
from contextlib import asynccontextmanager
from decimal import Decimal

from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session

from .database import Base, engine, get_db
from .models import Products

log = logging.getLogger("uvicorn.error")


def wait_for_db(retries: int = 40, delay: float = 3.0) -> None:
    """MySQL can take 30-60 s to initialise on first boot (ECS/compose).
    Retry long enough, then create the tables."""
    for attempt in range(1, retries + 1):
        try:
            Base.metadata.create_all(bind=engine)
            log.info("Base de datos lista (intento %s)", attempt)
            return
        except OperationalError:
            log.warning("BD no disponible, reintento %s/%s", attempt, retries)
            time.sleep(delay)
    raise RuntimeError("No se pudo conectar a la base de datos")


@asynccontextmanager
async def lifespan(_: FastAPI):
    wait_for_db()
    yield


app = FastAPI(title="FastAPI + MySQL", version="1.2.0", lifespan=lifespan)

# Frontend may be served from S3 / CloudFront (other origin) -> allow CORS.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


class ProductIn(BaseModel):
    name: str = Field(..., min_length=1, max_length=100)
    price: Decimal = Field(..., gt=0, max_digits=12, decimal_places=2)


def to_dict(p: Products) -> dict:
    return {"id": p.id, "name": p.name, "price": float(p.price)}


@app.get("/api/health")
def health(db: Session = Depends(get_db)):
    db.execute(text("SELECT 1"))
    return {"status": "ok", "db": "ok"}


@app.get("/api/products")
def list_products(db: Session = Depends(get_db)):
    return [to_dict(p) for p in db.query(Products).order_by(Products.id.desc()).all()]


@app.get("/api/products/{product_id}")
def get_product(product_id: int, db: Session = Depends(get_db)):
    product = db.get(Products, product_id)
    if not product:
        raise HTTPException(status_code=404, detail="Producto no encontrado")
    return to_dict(product)


@app.post("/api/products", status_code=201)
def create_product(data: ProductIn, db: Session = Depends(get_db)):
    name = data.name.strip()
    if not name:
        raise HTTPException(status_code=422, detail="El nombre es obligatorio")
    product = Products(name=name, price=data.price)
    db.add(product)
    db.commit()
    db.refresh(product)
    return to_dict(product)


@app.put("/api/products/{product_id}")
def update_product(product_id: int, data: ProductIn, db: Session = Depends(get_db)):
    product = db.get(Products, product_id)
    if not product:
        raise HTTPException(status_code=404, detail="Producto no encontrado")
    name = data.name.strip()
    if not name:
        raise HTTPException(status_code=422, detail="El nombre es obligatorio")
    product.name = name
    product.price = data.price
    db.commit()
    db.refresh(product)
    return to_dict(product)


@app.delete("/api/products/{product_id}")
def delete_product(product_id: int, db: Session = Depends(get_db)):
    product = db.get(Products, product_id)
    if not product:
        raise HTTPException(status_code=404, detail="Producto no encontrado")
    db.delete(product)
    db.commit()
    return {"ok": True, "deleted_id": product_id}
