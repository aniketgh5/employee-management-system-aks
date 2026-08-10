"""
Basic API test coverage: health checks + employee CRUD + search/filter.
Run with: pytest
"""


def _sample_employee(suffix="001", **overrides):
    payload = {
        "employee_id": f"EMP9{suffix}",
        "first_name": "Test",
        "last_name": "User",
        "email": f"test.user{suffix}@company.com",
        "department": "Engineering",
        "designation": "QA Engineer",
        "salary": 60000.00,
        "status": "active",
        "joining_date": "2023-01-15",
    }
    payload.update(overrides)
    return payload


def test_health(client):
    response = client.get("/health")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "healthy"
    assert body["application"] == "employee-management-api"


def test_health_db(client):
    response = client.get("/health/db")
    assert response.status_code == 200
    assert response.json()["database"] == "connected"


def test_create_employee(client):
    response = client.post("/api/employees", json=_sample_employee("101"))
    assert response.status_code == 201
    data = response.json()
    assert data["employee_id"] == "EMP9101"
    assert "id" in data
    assert data["status"] == "active"


def test_create_employee_duplicate_email_rejected(client):
    client.post("/api/employees", json=_sample_employee("102"))
    response = client.post(
        "/api/employees", json=_sample_employee("103", email="test.user102@company.com")
    )
    assert response.status_code == 409


def test_get_employees_list(client):
    client.post("/api/employees", json=_sample_employee("104"))
    response = client.get("/api/employees")
    assert response.status_code == 200
    assert isinstance(response.json(), list)
    assert len(response.json()) >= 1


def test_get_employee_by_id(client):
    created = client.post("/api/employees", json=_sample_employee("105")).json()
    response = client.get(f"/api/employees/{created['id']}")
    assert response.status_code == 200
    assert response.json()["employee_id"] == "EMP9105"


def test_get_employee_not_found(client):
    response = client.get("/api/employees/999999")
    assert response.status_code == 404


def test_update_employee(client):
    created = client.post("/api/employees", json=_sample_employee("106")).json()
    response = client.put(
        f"/api/employees/{created['id']}", json={"designation": "Senior QA Engineer"}
    )
    assert response.status_code == 200
    assert response.json()["designation"] == "Senior QA Engineer"


def test_update_employee_not_found(client):
    response = client.put("/api/employees/999999", json={"designation": "X"})
    assert response.status_code == 404


def test_delete_employee(client):
    created = client.post("/api/employees", json=_sample_employee("107")).json()
    response = client.delete(f"/api/employees/{created['id']}")
    assert response.status_code == 204

    follow_up = client.get(f"/api/employees/{created['id']}")
    assert follow_up.status_code == 404


def test_search_employees(client):
    client.post("/api/employees", json=_sample_employee("108"))
    response = client.get("/api/employees?search=Test")
    assert response.status_code == 200
    assert len(response.json()) >= 1


def test_filter_employees_by_department_and_status(client):
    client.post("/api/employees", json=_sample_employee("109", department="Finance", status="inactive"))
    response = client.get("/api/employees?department=Finance&status=inactive")
    assert response.status_code == 200
    for emp in response.json():
        assert emp["department"] == "Finance"
        assert emp["status"] == "inactive"


def test_dashboard_stats(client):
    client.post("/api/employees", json=_sample_employee("110"))
    response = client.get("/api/dashboard/stats")
    assert response.status_code == 200
    body = response.json()
    assert body["total_employees"] >= 1
    assert "recent_employees" in body
