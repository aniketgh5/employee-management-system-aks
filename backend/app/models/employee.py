from sqlalchemy import Column, Date, DateTime, Integer, Numeric, String, func

from app.database import Base


class Employee(Base):
    __tablename__ = "employees"

    id = Column(Integer, primary_key=True, index=True)
    employee_id = Column(String(20), unique=True, index=True, nullable=False)
    first_name = Column(String(50), nullable=False)
    last_name = Column(String(50), nullable=False)
    email = Column(String(120), unique=True, index=True, nullable=False)
    department = Column(String(50), nullable=False, index=True)
    designation = Column(String(80), nullable=False)
    salary = Column(Numeric(10, 2), nullable=False)
    status = Column(String(20), nullable=False, default="active", index=True)
    joining_date = Column(Date, nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at = Column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )

    def __repr__(self) -> str:
        return f"<Employee id={self.id} employee_id={self.employee_id!r}>"
