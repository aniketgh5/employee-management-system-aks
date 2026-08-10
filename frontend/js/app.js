/**
 * Employee Management System - frontend logic.
 * Talks to the backend exclusively through the same-origin "/api" prefix,
 * which Nginx reverse-proxies to the FastAPI backend container.
 */
const API_BASE = "/api";

const state = { employees: [] };

const el = (id) => document.getElementById(id);

async function fetchJSON(url, options = {}) {
  const response = await fetch(url, options);
  if (!response.ok) {
    let detail = `Request failed (${response.status})`;
    try {
      const body = await response.json();
      if (body.detail) detail = body.detail;
    } catch (_) { /* non-JSON error body, keep default message */ }
    throw new Error(detail);
  }
  if (response.status === 204) return null;
  return response.json();
}

async function loadHealth() {
  try {
    const health = await fetchJSON("/health");
    el("stat-health").textContent = health.status === "healthy" ? "Healthy" : "Degraded";
  } catch (err) {
    el("stat-health").textContent = "Unreachable";
  }
}

async function loadDashboard() {
  try {
    const stats = await fetchJSON(`${API_BASE}/dashboard/stats`);
    el("stat-total").textContent = stats.total_employees;
    el("stat-active").textContent = stats.active_employees;
    el("stat-departments").textContent = stats.total_departments;
  } catch (err) {
    console.error("Failed to load dashboard stats", err);
  }
}

function buildQuery() {
  const params = new URLSearchParams();
  const search = el("search-input").value.trim();
  const department = el("department-filter").value;
  const status = el("status-filter").value;
  if (search) params.set("search", search);
  if (department) params.set("department", department);
  if (status) params.set("status", status);
  return params.toString();
}

function populateDepartmentFilter(employees) {
  const select = el("department-filter");
  const current = select.value;
  const departments = [...new Set(employees.map((e) => e.department))].sort();
  select.innerHTML =
    '<option value="">All Departments</option>' +
    departments.map((d) => `<option value="${d}">${d}</option>`).join("");
  select.value = current;
}

function formatCurrency(value) {
  return new Intl.NumberFormat("en-IN", {
    style: "currency",
    currency: "INR",
    maximumFractionDigits: 0,
  }).format(value);
}

function escapeHtml(value) {
  const div = document.createElement("div");
  div.textContent = value;
  return div.innerHTML;
}

function renderEmployees(employees) {
  const tbody = el("employee-table-body");
  if (!employees.length) {
    tbody.innerHTML = '<tr><td colspan="9" class="empty-row">No employees found.</td></tr>';
    return;
  }
  tbody.innerHTML = employees
    .map(
      (emp) => `
    <tr>
      <td>${escapeHtml(emp.employee_id)}</td>
      <td>${escapeHtml(emp.first_name)} ${escapeHtml(emp.last_name)}</td>
      <td>${escapeHtml(emp.email)}</td>
      <td>${escapeHtml(emp.department)}</td>
      <td>${escapeHtml(emp.designation)}</td>
      <td>${formatCurrency(emp.salary)}</td>
      <td><span class="badge badge-${emp.status}">${emp.status}</span></td>
      <td>${emp.joining_date}</td>
      <td class="row-actions">
        <button class="btn-icon" data-action="edit" data-id="${emp.id}" title="Edit">&#9998;</button>
        <button class="btn-icon" data-action="delete" data-id="${emp.id}" title="Delete">&#128465;</button>
      </td>
    </tr>`
    )
    .join("");
}

async function loadEmployees() {
  const tbody = el("employee-table-body");
  tbody.innerHTML = '<tr><td colspan="9" class="empty-row">Loading employees...</td></tr>';
  try {
    const query = buildQuery();
    const employees = await fetchJSON(`${API_BASE}/employees${query ? "?" + query : ""}`);
    state.employees = employees;
    renderEmployees(employees);
  } catch (err) {
    tbody.innerHTML = `<tr><td colspan="9" class="empty-row">Failed to load employees: ${escapeHtml(err.message)}</td></tr>`;
  }
}

async function loadDepartmentOptions() {
  try {
    const employees = await fetchJSON(`${API_BASE}/employees?limit=500`);
    populateDepartmentFilter(employees);
  } catch (err) {
    console.error("Failed to load department list", err);
  }
}

function openModal(employee = null) {
  el("employee-modal").classList.remove("hidden");
  el("form-error").classList.add("hidden");
  const form = el("employee-form");
  form.reset();
  if (employee) {
    el("modal-title").textContent = "Edit Employee";
    el("employee-db-id").value = employee.id;
    el("form-employee-id").value = employee.employee_id;
    el("form-employee-id").disabled = true;
    el("form-status").value = employee.status;
    el("form-first-name").value = employee.first_name;
    el("form-last-name").value = employee.last_name;
    el("form-email").value = employee.email;
    el("form-department").value = employee.department;
    el("form-designation").value = employee.designation;
    el("form-salary").value = employee.salary;
    el("form-joining-date").value = employee.joining_date;
  } else {
    el("modal-title").textContent = "Add Employee";
    el("employee-db-id").value = "";
    el("form-employee-id").disabled = false;
  }
}

function closeModal() {
  el("employee-modal").classList.add("hidden");
}

async function refreshAll() {
  await Promise.all([loadHealth(), loadDashboard(), loadEmployees(), loadDepartmentOptions()]);
}

function debounce(fn, delay = 350) {
  let timer;
  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), delay);
  };
}

document.addEventListener("DOMContentLoaded", () => {
  refreshAll();

  el("refresh-btn").addEventListener("click", refreshAll);
  el("search-input").addEventListener("input", debounce(loadEmployees));
  el("department-filter").addEventListener("change", loadEmployees);
  el("status-filter").addEventListener("change", loadEmployees);

  el("add-employee-btn").addEventListener("click", () => openModal());
  el("modal-close").addEventListener("click", closeModal);
  el("form-cancel").addEventListener("click", closeModal);
  el("employee-modal").addEventListener("click", (e) => {
    if (e.target.id === "employee-modal") closeModal();
  });

  el("employee-table-body").addEventListener("click", async (event) => {
    const btn = event.target.closest("button[data-action]");
    if (!btn) return;
    const id = btn.dataset.id;
    if (btn.dataset.action === "edit") {
      const employee = state.employees.find((e) => String(e.id) === id);
      if (employee) openModal(employee);
    } else if (btn.dataset.action === "delete") {
      if (confirm("Delete this employee? This cannot be undone.")) {
        try {
          await fetchJSON(`${API_BASE}/employees/${id}`, { method: "DELETE" });
          await Promise.all([loadEmployees(), loadDashboard()]);
        } catch (err) {
          alert(`Failed to delete employee: ${err.message}`);
        }
      }
    }
  });

  el("employee-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const dbId = el("employee-db-id").value;
    const payload = {
      employee_id: el("form-employee-id").value,
      first_name: el("form-first-name").value,
      last_name: el("form-last-name").value,
      email: el("form-email").value,
      department: el("form-department").value,
      designation: el("form-designation").value,
      salary: parseFloat(el("form-salary").value),
      status: el("form-status").value,
      joining_date: el("form-joining-date").value,
    };
    try {
      if (dbId) {
        delete payload.employee_id; // employee_id is immutable after creation
        await fetchJSON(`${API_BASE}/employees/${dbId}`, {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload),
        });
      } else {
        await fetchJSON(`${API_BASE}/employees`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload),
        });
      }
      closeModal();
      await refreshAll();
    } catch (err) {
      const errorEl = el("form-error");
      errorEl.textContent = err.message;
      errorEl.classList.remove("hidden");
    }
  });
});
