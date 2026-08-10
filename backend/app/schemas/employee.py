from datetime import date, datetime
from decimal import Decimal
from typing import List, Optional

from pydantic import BaseModel, ConfigDict, EmailStr, Field


class EmployeeBase(BaseModel):
    employee_id: str = Field(..., max_length=20, examples=["EMP1001"])
    first_name: str = Field(..., max_length=50)
    last_name: str = Field(..., max_length=50)
    email: EmailStr
    department: str = Field(..., max_length=50)
    designation: str = Field(..., max_length=80)
    salary: Decimal = Field(..., gt=0)
    status: str = Field(default="active", pattern="^(active|inactive)$")
    joining_date: date


class EmployeeCreate(EmployeeBase):
    pass


class EmployeeUpdate(BaseModel):
    """All fields optional - only provided fields are updated (PATCH-style PUT)."""

    first_name: Optional[str] = Field(default=None, max_length=50)
    last_name: Optional[str] = Field(default=None, max_length=50)
    email: Optional[EmailStr] = None
    department: Optional[str] = Field(default=None, max_length=50)
    designation: Optional[str] = Field(default=None, max_length=80)
    salary: Optional[Decimal] = Field(default=None, gt=0)
    status: Optional[str] = Field(default=None, pattern="^(active|inactive)$")
    joining_date: Optional[date] = None


class EmployeeResponse(EmployeeBase):
    model_config = ConfigDict(from_attributes=True)

    id: int
    created_at: datetime
    updated_at: Optional[datetime] = None


class DashboardStats(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    total_employees: int
    active_employees: int
    total_departments: int
    recent_employees: List[EmployeeResponse]
