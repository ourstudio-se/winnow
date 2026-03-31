#!/usr/bin/env python3
"""Generate realistic OTel traces and logs against the winnow backend.

Simulates a microservice topology:
  api-gateway -> user-service -> postgres
  api-gateway -> order-service -> postgres
                 order-service -> redis

Usage:
  pip install opentelemetry-api opentelemetry-sdk opentelemetry-exporter-otlp-proto-http
  python scripts/generate-data.py [--endpoint http://localhost:4318] [--requests 20]
"""

import argparse
import logging
import os
import random
import time

from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
    OTLPSpanExporter,
)
from opentelemetry.sdk._logs import LoggerProvider
from opentelemetry.sdk._logs.export import SimpleLogRecordProcessor
from opentelemetry.exporter.otlp.proto.http._log_exporter import (
    OTLPLogExporter,
)
from opentelemetry._logs import set_logger_provider

SERVICES = {
    "api-gateway": {
        "calls": [
            ("user-service", "GetUser"),
            ("order-service", "ListOrders"),
        ],
    },
    "user-service": {
        "calls": [("postgres", "SELECT users")],
    },
    "order-service": {
        "calls": [
            ("postgres", "SELECT orders"),
            ("redis", "GET order:cache"),
        ],
    },
}

ENDPOINTS = [
    ("GET", "/api/orders"),
    ("GET", "/api/users/{id}"),
    ("POST", "/api/orders"),
    ("GET", "/api/orders/{id}"),
]


def setup_provider(service_name, endpoint):
    """Create a TracerProvider + LoggerProvider for a given service."""
    resource = Resource.create({"service.name": service_name})

    tp = TracerProvider(resource=resource)
    tp.add_span_processor(
        SimpleSpanProcessor(
            OTLPSpanExporter(endpoint=f"{endpoint}/v1/traces")
        )
    )

    lp = LoggerProvider(resource=resource)
    lp.add_log_record_processor(
        SimpleLogRecordProcessor(
            OTLPLogExporter(endpoint=f"{endpoint}/v1/logs")
        )
    )

    return tp, lp


def make_logger(name, log_provider):
    """Attach an OTel log handler to a stdlib logger."""
    try:
        from opentelemetry.sdk._logs import LoggingHandler
        handler = LoggingHandler(logger_provider=log_provider)
    except ImportError:
        handler = logging.Handler()

    logger = logging.getLogger(name)
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    return logger


def simulate_request(providers, inject_error):
    """Simulate one end-to-end request across the service topology."""
    gw_tp, gw_lp = providers["api-gateway"]
    us_tp, us_lp = providers["user-service"]
    os_tp, os_lp = providers["order-service"]

    gw_tracer = gw_tp.get_tracer("api-gateway")
    us_tracer = us_tp.get_tracer("user-service")
    os_tracer = os_tp.get_tracer("order-service")

    gw_logger = make_logger("api-gateway", gw_lp)
    os_logger = make_logger("order-service", os_lp)

    method, path = random.choice(ENDPOINTS)
    span_name = f"{method} {path}"

    # Root span: api-gateway receives the HTTP request
    with gw_tracer.start_as_current_span(
        span_name,
        kind=trace.SpanKind.SERVER,
        attributes={
            "http.method": method,
            "http.route": path,
            "http.status_code": 500 if inject_error else 200,
        },
    ) as root:
        gw_logger.info("Incoming request: %s %s", method, path)
        time.sleep(random.uniform(0.001, 0.005))

        # api-gateway -> user-service
        with gw_tracer.start_as_current_span(
            "GetUser",
            kind=trace.SpanKind.CLIENT,
            attributes={"peer.service": "user-service"},
        ):
            # user-service handles it
            with us_tracer.start_as_current_span(
                "GetUser",
                kind=trace.SpanKind.SERVER,
            ):
                # user-service -> postgres
                with us_tracer.start_as_current_span(
                    "SELECT users",
                    kind=trace.SpanKind.CLIENT,
                    attributes={
                        "peer.service": "postgres",
                        "db.system": "postgresql",
                        "db.statement": "SELECT * FROM users WHERE id = $1",
                    },
                ):
                    time.sleep(random.uniform(0.002, 0.010))

        # api-gateway -> order-service
        with gw_tracer.start_as_current_span(
            "ListOrders",
            kind=trace.SpanKind.CLIENT,
            attributes={"peer.service": "order-service"},
        ):
            # order-service handles it
            with os_tracer.start_as_current_span(
                "ListOrders",
                kind=trace.SpanKind.SERVER,
            ) as order_span:
                # order-service -> redis
                with os_tracer.start_as_current_span(
                    "GET order:cache",
                    kind=trace.SpanKind.CLIENT,
                    attributes={
                        "peer.service": "redis",
                        "db.system": "redis",
                        "db.statement": "GET order:cache:user123",
                    },
                ):
                    time.sleep(random.uniform(0.001, 0.003))

                # order-service -> postgres
                with os_tracer.start_as_current_span(
                    "SELECT orders",
                    kind=trace.SpanKind.CLIENT,
                    attributes={
                        "peer.service": "postgres",
                        "db.system": "postgresql",
                        "db.statement": "SELECT * FROM orders WHERE user_id = $1",
                    },
                ) as pg_span:
                    time.sleep(random.uniform(0.003, 0.015))

                    if inject_error:
                        pg_span.set_status(
                            trace.StatusCode.ERROR,
                            "connection refused",
                        )
                        pg_span.set_attribute(
                            "error.message",
                            "could not connect to postgres:5432",
                        )
                        order_span.set_status(
                            trace.StatusCode.ERROR,
                            "upstream failure",
                        )
                        os_logger.error(
                            "Failed to query orders: %s",
                            "connection refused",
                        )

                if not inject_error:
                    os_logger.info("Returned %d orders", random.randint(1, 50))

        if inject_error:
            root.set_status(trace.StatusCode.ERROR, "internal error")
            gw_logger.error("Request failed: %s %s -> 500", method, path)
        else:
            gw_logger.info(
                "Request completed: %s %s -> 200", method, path
            )


def main():
    parser = argparse.ArgumentParser(
        description="Generate OTel traces/logs for winnow"
    )
    parser.add_argument(
        "--endpoint",
        default="http://localhost:4318",
        help="Backend endpoint (default: http://localhost:4318)",
    )
    parser.add_argument(
        "--requests",
        type=int,
        default=20,
        help="Number of requests to simulate (default: 20)",
    )
    args = parser.parse_args()

    print(f"Generating {args.requests} requests against {args.endpoint}")

    # Set up providers for each instrumented service
    providers = {}
    for svc in ["api-gateway", "user-service", "order-service"]:
        providers[svc] = setup_provider(svc, args.endpoint)

    errors = 0
    for i in range(args.requests):
        inject_error = random.random() < 0.25
        if inject_error:
            errors += 1
        simulate_request(providers, inject_error)

    # Shutdown all providers
    for svc, (tp, lp) in providers.items():
        tp.shutdown()
        lp.shutdown()

    print(
        f"Done. Sent {args.requests} requests "
        f"({errors} errors, "
        f"{args.requests - errors} success)"
    )


if __name__ == "__main__":
    main()
