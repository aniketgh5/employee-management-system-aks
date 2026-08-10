import logging
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.database import get_db
from app.schemas.employee import EmployeeCreate, EmployeeResponse, EmployeeUpdate
from app.services import employee_service

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/employees", tags=["Employees"])


@router.get("", response_model=List[EmployeeResponse])
def list_employees(
    search: Optional[str] = Query(None, description="Search by name, email or employee ID"),
    department: Optional[str] = Query(None, description="Filter by department"),
    status_filter: Optional[str] = Query(None, alias="status", description="Filter by status (active/inactive)"),
    skip: int = Query(0, ge=0),
    limit: int = Query(100, ge=1, le=500),
    db: Session = Depends(get_db),
):
    return employee_service.get_employees(
        db,
        search=search,
        department=department,
        status=status_filter,
        skip=skip,
        limit=limit,
    )


@router.get("/{employee_id}", response_model=EmployeeResponse)
def get_employee(employee_id: int, db: Session = Depends(get_db)):
    employee = employee_service.get_employee(db, employee_id)
    if not employee:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Employee not found")
    return employee


@router.post("", response_model=EmployeeResponse, status_code=status.HTTP_201_CREATED)
def create_employee(employee_in: EmployeeCreate, db: Session = Depends(get_db)):
    if employee_service.get_employee_by_business_id(db, employee_in.employee_id):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Employee ID already exists")
    if employee_service.get_employee_by_email(db, employee_in.email):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already exists")
    try:
        return employee_service.create_employee(db, employee_in)
    except IntegrityError:
        db.rollback()
        logger.exception("Integrity error creating employee")
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Employee could not be created due to a data conflict",
        )


@router.put("/{employee_id}", response_model=EmployeeResponse)
def update_employee(employee_id: int, employee_in: EmployeeUpdate, db: Session = Depends(get_db)):
    employee = employee_service.get_employee(db, employee_id)
    if not employee:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Employee not found")
    try:
        return employee_service.update_employee(db, employee, employee_in)
    except IntegrityError:
        db.rollback()
        logger.exception("Integrity error updating employee")
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Update violates a unique constraint (email must be unique)",
        )


@router.delete("/{employee_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_employee(employee_id: int, db: Session = Depends(get_db)):
    employee = employee_service.get_employee(db, employee_id)
    if not employee:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Employee not found")
    employee_service.delete_employee(db, employee)
    return None
