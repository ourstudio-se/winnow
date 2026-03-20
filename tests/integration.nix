{
  pkgs,
  telemetry-experiment,
}: let
  quickwitImage = pkgs.dockerTools.pullImage {
    imageName = "quickwit/quickwit";
    imageDigest = "sha256:140f0bd905d2a1789083899c1701f749799466aaa943d8b374e645005687c3e4";
    sha256 = "sha256-WEp3/7CbUDZ1Duf7QocUIFpUTvMTr3ognysaao9Q2LI=";
    finalImageName = "quickwit/quickwit";
    finalImageTag = "v0.9.0-rc";
  };

  otelPythonLibs = with pkgs.python3Packages; [
    opentelemetry-api
    opentelemetry-sdk
    opentelemetry-exporter-otlp-proto-http
  ];

  # Python script that sends test traces using the OTel SDK.
  # Uses SimpleSpanProcessor for synchronous export (no batching).
  sendTraces =
    pkgs.writers.writePython3Bin "send-traces" {
      libraries = otelPythonLibs;
    } ''
      import os
      import time
      from opentelemetry import trace
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import (
          SimpleSpanProcessor,
      )
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
          OTLPSpanExporter,
      )

      os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"] = (
          "http://localhost:8080"
      )

      resource = Resource.create(
          {"service.name": "test-service"}
      )
      provider = TracerProvider(resource=resource)
      exporter = OTLPSpanExporter()
      provider.add_span_processor(
          SimpleSpanProcessor(exporter)
      )
      trace.set_tracer_provider(provider)

      tracer = trace.get_tracer("integration-test")
      with tracer.start_as_current_span("test-root-span"):
          with tracer.start_as_current_span("test-child-span"):
              time.sleep(0.01)
          with tracer.start_as_current_span(
              "call-backend-db",
              kind=trace.SpanKind.CLIENT,
              attributes={
                  "peer.service": "backend-db",
              },
          ):
              time.sleep(0.01)

      provider.shutdown()
      print("Traces sent successfully")
    '';

  # Python script that sends test logs using the OTel SDK.
  sendLogs =
    pkgs.writers.writePython3Bin "send-logs" {
      libraries = otelPythonLibs;
      flakeIgnore = ["E501"];
    } ''
      import os
      import logging
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk._logs import LoggerProvider
      from opentelemetry.sdk._logs.export import (
          SimpleLogRecordProcessor,
      )
      from opentelemetry.exporter.otlp.proto.http._log_exporter import (
          OTLPLogExporter,
      )
      from opentelemetry._logs import set_logger_provider

      os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"] = (
          "http://localhost:8080"
      )

      resource = Resource.create(
          {"service.name": "test-service"}
      )
      log_provider = LoggerProvider(resource=resource)
      log_exporter = OTLPLogExporter()
      log_provider.add_log_record_processor(
          SimpleLogRecordProcessor(log_exporter)
      )
      set_logger_provider(log_provider)

      handler = logging.Handler()
      try:
          from opentelemetry.sdk._logs import LoggingHandler
          handler = LoggingHandler(
              logger_provider=log_provider
          )
      except ImportError:
          pass

      logger = logging.getLogger("test-logger")
      logger.addHandler(handler)
      logger.setLevel(logging.INFO)

      logger.info("integration test log message")

      log_provider.shutdown()
      print("Logs sent successfully")
    '';
in
  pkgs.testers.runNixOSTest {
    name = "telemetry-integration";

    nodes.machine = {pkgs, ...}: {
      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;
      virtualisation.docker.enable = true;

      environment.systemPackages = [
        telemetry-experiment
        sendTraces
        sendLogs
        pkgs.curl
        pkgs.jq
      ];
    };

    testScript =
      /*
      python
      */
      ''
        import json
        import time as time_mod

        def search_index(index, query):
            """Search a Quickwit index, return parsed JSON."""
            url = (
                "http://localhost:7280"
                f"/api/v1/{index}/search"
            )
            result = machine.succeed(
                "curl -sf "
                f"'{url}' "
                f"-d '{{\"query\":\"{query}\"}}' "
                "-H 'Content-Type: application/json'"
            )
            return json.loads(result)

        def search(query):
            """Search traces index."""
            return search_index(
                "otel-traces-v0_9", query
            )

        def wait_for_hits_index(
            index, query, min_hits, timeout=90
        ):
            """Poll until min_hits found or timeout."""
            deadline = time_mod.time() + timeout
            last = None
            while time_mod.time() < deadline:
                last = search_index(index, query)
                if last["num_hits"] >= min_hits:
                    return last
                machine.sleep(5)
            raise Exception(
                f"Timed out: >= {min_hits} hits "
                f"for '{query}' in {index}. "
                f"Last: {last}"
            )

        def wait_for_hits(query, min_hits, timeout=90):
            """Poll traces index for hits."""
            return wait_for_hits_index(
                "otel-traces-v0_9",
                query,
                min_hits,
                timeout,
            )

        machine.wait_for_unit("docker.service")

        # Load and start Quickwit
        machine.succeed("docker load < ${quickwitImage}")
        machine.succeed(
            "docker run -d --name quickwit --network host "
            "quickwit/quickwit:v0.9.0-rc run"
        )

        # Wait for Quickwit to be fully ready (ingesters must be up).
        # Port 7280 opens before the cluster is initialized.
        machine.wait_for_open_port(7280)
        machine.wait_until_succeeds(
            "curl -sf http://localhost:7280/health/readyz",
            timeout=60
        )

        # Start our server
        machine.succeed(
            "QUICKWIT_URL=http://localhost:7280 "
            "telemetry-experiment "
            ">/tmp/server.log 2>&1 &"
        )
        try:
            machine.wait_for_open_port(8080, timeout=60)
        except Exception:
            print(machine.succeed("cat /tmp/server.log"))
            raise

        # Send traces via OTel Python SDK
        machine.succeed("send-traces")

        # Wait for Quickwit to commit and index (up to 90s)
        # 3 spans: root, child, CLIENT call-backend-db
        wait_for_hits("*", 3)

        # Verify service name was ingested correctly
        resp = search("service_name:test-service")
        assert resp["num_hits"] >= 3, (
            f"Expected 3 spans with "
            f"service_name=test-service, "
            f"got {resp['num_hits']}"
        )

        # Verify span names
        resp = search("span_name:test-root-span")
        assert resp["num_hits"] >= 1, (
            "Root span not found"
        )

        # Verify service graph edges
        sg = wait_for_hits_index(
            "servicegraph",
            "source:test-service",
            1,
        )
        hits = sg["hits"]
        assert any(
            h["dest"] == "backend-db"
            for h in hits
        ), (
            f"Expected edge to backend-db, "
            f"got: {hits}"
        )

        # Send logs via OTel Python SDK
        machine.succeed("send-logs")

        # Wait for logs to be ingested and committed
        logs = wait_for_hits_index(
            "otel-logs-v0_9", "*", 1
        )
        hits = logs["hits"]
        assert any(
            "integration test log message"
            in str(h.get("body", ""))
            for h in hits
        ), (
            f"Expected log with "
            f"'integration test log message', "
            f"got: {hits}"
        )

        # -- Phase 5: Search proxy tests --

        # Search traces via proxy
        traces = json.loads(machine.succeed(
            "curl -sf "
            "http://localhost:8080"
            "/api/v1/otel-traces-v0_9/search "
            "-H 'Content-Type: application/json' "
            "-d '{\"query\": "
            "\"service_name:test-service "
            "AND span_name:test-root-span\", "
            "\"max_hits\": 10}'"
        ))
        assert traces["num_hits"] >= 1, (
            f"Expected >= 1 root span, "
            f"got {traces['num_hits']}"
        )

        # Get all spans for a trace
        trace_id = traces["hits"][0]["trace_id"]
        detail = json.loads(machine.succeed(
            "curl -sf "
            "http://localhost:8080"
            "/api/v1/otel-traces-v0_9/search "
            "-H 'Content-Type: application/json' "
            f"-d '{{\"query\": "
            f"\"trace_id:{trace_id}\", "
            f"\"max_hits\": 100}}'"
        ))
        assert detail["num_hits"] >= 3, (
            f"Expected >= 3 spans for trace, "
            f"got {detail['num_hits']}"
        )

        # Search logs via proxy
        proxy_logs = json.loads(machine.succeed(
            "curl -sf "
            "http://localhost:8080"
            "/api/v1/otel-logs-v0_9/search "
            "-H 'Content-Type: application/json' "
            "-d '{\"query\": "
            "\"service_name:test-service\", "
            "\"max_hits\": 10}'"
        ))
        assert proxy_logs["num_hits"] >= 1, (
            f"Expected >= 1 log, "
            f"got {proxy_logs['num_hits']}"
        )

        # Service graph search via proxy
        sg_proxy = json.loads(machine.succeed(
            "curl -sf "
            "http://localhost:8080"
            "/api/v1/servicegraph/search "
            "-H 'Content-Type: application/json' "
            "-d '{\"query\": \"*\", "
            "\"max_hits\": 100}'"
        ))
        assert sg_proxy["num_hits"] >= 1, (
            f"Expected >= 1 edge, "
            f"got {sg_proxy['num_hits']}"
        )

        # Verify unknown index is rejected (404)
        result = machine.succeed(
            "curl -s -o /dev/null "
            "-w '%{http_code}' "
            "http://localhost:8080"
            "/api/v1/secret-index/search "
            "-H 'Content-Type: application/json' "
            "-d '{\"query\": \"*\"}'"
        )
        assert result.strip() == "404", (
            f"Expected 404 for unknown index, "
            f"got {result.strip()}"
        )

        # List available indexes
        indexes = json.loads(machine.succeed(
            "curl -sf "
            "http://localhost:8080"
            "/api/v1/indexes"
        ))
        assert "otel-traces-v0_9" in indexes
        assert "otel-logs-v0_9" in indexes
        assert "servicegraph" in indexes
      '';
  }
