"""
Employee Management System - FastAPI application entrypoint.
"""
import logging
import sys
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.config import settings
from app.database import Base, engine
from app.routers import dashboard, employees, health

logging.basicConfig(
    level=settings.LOG_LEVEL,
    format="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("%s starting up in '%s' mode", settings.APP_NAME, settings.APP_ENV)
    # Safety net only - database/init.sql normally creates the schema the
    # first time the Postgres container starts. This is a no-op if the
    # table already exists, and is swallowed (with a warning) if the
    # database isn't reachable yet, so it never crashes app startup.
    try:
        Base.metadata.create_all(bind=engine)
    except Exception:
        logger.warning("Could not verify/create database tables at startup", exc_info=True)
    yield
    logger.info("%s shutting down", settings.APP_NAME)


app = FastAPI(
    title="Employee Management System API",
    description="A small, production-style REST API for managing employees.",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def log_requests(request: Request, call_next):
    response = await call_next(request)
    logger.info("%s %s -> %s", request.method, request.url.path, response.status_code)
    return response


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception):
    logger.exception("Unhandled exception on %s %s", request.method, request.url.path)
    return JSONResponse(status_code=500, content={"detail": "Internal server error"})


app.include_router(health.router)
app.include_router(employees.router)
app.include_router(dashboard.router)
