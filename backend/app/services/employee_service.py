"""
Business/query logic for employees, kept separate from the HTTP layer
(routers) so it can be unit-tested and reused independently of FastAPI.
"""
import logging
from typing import Optional

from sqlalchemy import or_
from sqlalchemy.orm import Session

from app.models.employee import Employee
from app.schemas.employee import EmployeeCreate, EmployeeUpdate

logger = logging.getLogger(__name__)


def get_employees(
    db: Session,
    search: Optional[str] = None,
    department: Optional[str] = None,
    status: Optional[str] = None,
    skip: int = 0,
    limit: int = 100,
):
    query = db.query(Employee)

    if search:
        pattern = f"%{search}%"
        query = query.filter(
            or_(
                Employee.first_name.ilike(pattern),
                Employee.last_name.ilike(pattern),
                Employee.email.ilike(pattern),
                Employee.employee_id.ilike(pattern),
            )
        )

    if department:
        query = query.filter(Employee.department == department)

    if status:
        query = query.filter(Employee.status == status)

    return query.order_by(Employee.id).offset(skip).limit(limit).all()


def get_employee(db: Session, employee_id: int) -> Optional[Employee]:
    return db.query(Employee).filter(Employee.id == employee_id).first()


def get_employee_by_business_id(db: Session, employee_id: str) -> Optional[Employee]:
    return db.query(Employee).filter(Employee.employee_id == employee_id).first()


def get_employee_by_email(db: Session, email: str) -> Optional[Employee]:
    return db.query(Employee).filter(Employee.email == email).first()


def create_employee(db: Session, employee_in: EmployeeCreate) -> Employee:
    employee = Employee(**employee_in.model_dump())
    db.add(employee)
    db.commit()
    db.refresh(employee)
    logger.info("Created employee id=%s employee_id=%s", employee.id, employee.employee_id)
    return employee


def update_employee(db: Session, employee: Employee, employee_in: EmployeeUpdate) -> Employee:
    update_data = employee_in.model_dump(exclude_unset=True)
    for field, value in update_data.items():
        setattr(employee, field, value)
    db.commit()
    db.refresh(employee)
    logger.info("Updated employee id=%s", employee.id)
    return employee


def delete_employee(db: Session, employee: Employee) -> None:
    logger.info("Deleting employee id=%s", employee.id)
    db.delete(employee)
    db.commit()


def get_dashboard_stats(db: Session) -> dict:
    total_employees = db.query(Employee).count()
    active_employees = db.query(Employee).filter(Employee.status == "active").count()
    total_departments = db.query(Employee.department).distinct().count()
    recent_employees = (
        db.query(Employee).order_by(Employee.created_at.desc()).limit(5).all()
    )
    return {
        "total_employees": total_employees,
        "active_employees": active_employees,
        "total_departments": total_departments,
        "recent_employees": recent_employees,
    }
