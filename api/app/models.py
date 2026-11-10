from sqlalchemy import Column, Integer, Numeric, String

from .database import Base


class Products(Base):
    __tablename__ = "Products"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(100), nullable=False)
    price = Column(Numeric(12, 2), nullable=False)
