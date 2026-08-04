"""OpenTelemetry tracing setup.

No-op when OTEL_ENABLED is false or OTEL_ENDPOINT is unset — dev/CI
environments need zero collector infrastructure. All OTEL imports are deferred
inside setup_telemetry so the packages are never loaded when tracing is off
(keeps cold-start cheap).

Call order in main.py:
  app = FastAPI(...)
  setup_telemetry(app)   ← after app creation so FastAPI instrumentation wraps it

DECISIONS:
- OTLP gRPC: port 4317; lower overhead than HTTP, protobuf native.
- TLS inferred from endpoint scheme: http:// → plaintext, https:// → TLS.
- SQLAlchemy: pass sync_engine explicitly — the auto-detect path is unreliable
  with SQLAlchemy 2.0 async (asyncpg).
- Redis: global patch via RedisInstrumentor() — no engine ref needed.
- Best-effort: any setup failure logs and returns; the app runs without tracing.
"""
import logging

logger = logging.getLogger("fieldtrack.telemetry")


def setup_telemetry(app) -> None:
    from app.core.config import get_settings

    settings = get_settings()

    if not settings.otel_enabled or not settings.otel_endpoint:
        logger.info("OTEL tracing disabled (OTEL_ENABLED=false or OTEL_ENDPOINT unset)")
        return

    try:
        from opentelemetry import trace
        from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
        from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
        from opentelemetry.instrumentation.redis import RedisInstrumentor
        from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
        from opentelemetry.sdk.resources import SERVICE_NAME, Resource
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor

        from app.core.database import engine

        resource = Resource.create({SERVICE_NAME: settings.otel_service_name})
        provider = TracerProvider(resource=resource)

        exporter = OTLPSpanExporter(endpoint=settings.otel_endpoint)
        provider.add_span_processor(BatchSpanProcessor(exporter))
        trace.set_tracer_provider(provider)

        # SQLAlchemy 2.0 async: instrument the underlying sync engine directly.
        SQLAlchemyInstrumentor().instrument(engine=engine.sync_engine)

        # Redis: global event patch — no engine reference needed.
        RedisInstrumentor().instrument()

        # FastAPI: wraps the ASGI app so every request gets a root span.
        FastAPIInstrumentor.instrument_app(
            app,
            excluded_urls="api/v1/health,metrics",
        )

        logger.info(
            "OTEL tracing active — service=%r endpoint=%r",
            settings.otel_service_name,
            settings.otel_endpoint,
        )
    except Exception:
        logger.exception("OTEL setup failed — continuing without tracing")
