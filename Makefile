# =============================================================
# Makefile — OGC API Processes
# =============================================================

.PHONY: up down restart logs test clean status shell

ifneq (,$(wildcard .env))
  include .env
  export
endif

HOST    ?= localhost
PORT    ?= 80
API_KEY ?= dev-key-12345

up:
	@echo "▶ Starting OGC API Processes stack..."
	docker compose up --build -d
	@echo "✅ Stack is up. Run 'make logs' to watch or 'make test' to verify."

down:
	@echo "▶ Stopping stack..."
	docker compose down
	@echo "✅ Stack stopped."

restart: down up

logs:
	docker compose logs -f

status:
	docker compose ps

shell:
	docker exec -it ogc-api-pygeoapi-1 /bin/bash

clean:
	@echo "▶ Removing containers, images and volumes..."
	docker compose down --rmi all --volumes --remove-orphans
	@echo "✅ Clean complete."

test:
	@echo ""
	@echo "=============================================="
	@echo " OGC API Processes — Test Suite"
	@echo " Host: http://$(HOST):$(PORT)"
	@echo "=============================================="
	@echo ""
	@$(MAKE) _test_public
	@$(MAKE) _test_auth
	@$(MAKE) _test_buffer
	@$(MAKE) _test_zonal_stats
	@echo ""
	@echo "=============================================="
	@echo " ✅ All tests passed"
	@echo "=============================================="

_test_public:
	@echo "── Public endpoints (no key required) ──"
	@$(MAKE) _assert URL="http://$(HOST):$(PORT)/" EXPECT=200 LABEL="GET /"
	@$(MAKE) _assert URL="http://$(HOST):$(PORT)/conformance" EXPECT=200 LABEL="GET /conformance"
	@$(MAKE) _assert URL="http://$(HOST):$(PORT)/openapi" EXPECT=200 LABEL="GET /openapi"

_test_auth:
	@echo ""
	@echo "── Authentication ──"
	@$(MAKE) _assert URL="http://$(HOST):$(PORT)/processes" EXPECT=401 LABEL="No key → 401"
	@$(MAKE) _assert URL="http://$(HOST):$(PORT)/processes" EXPECT=403 LABEL="Wrong key → 403" EXTRA='-H "X-API-Key: wrong-key"'
	@$(MAKE) _assert URL="http://$(HOST):$(PORT)/processes" EXPECT=200 LABEL="Valid key → 200" EXTRA='-H "X-API-Key: $(API_KEY)"'

_test_buffer:
	@echo ""
	@echo "── Buffer process ──"
	@$(MAKE) _assert URL="http://$(HOST):$(PORT)/processes/buffer" EXPECT=200 LABEL="GET /processes/buffer" EXTRA='-H "X-API-Key: $(API_KEY)"'
	@echo "   Submitting async buffer job..."
	@JOB_ID=$$(curl -s -X POST \
		-H "Content-Type: application/json" \
		-H "X-API-Key: $(API_KEY)" \
		-H "Prefer: respond-async" \
		-d '{"inputs":{"latitude":12.9716,"longitude":77.5946,"distance":500}}' \
		http://$(HOST):$(PORT)/processes/buffer/execution | python3 -c "import sys,json; print(json.load(sys.stdin)['jobID'])"); \
	echo "   Job ID: $$JOB_ID"; \
	sleep 2; \
	STATUS=$$(curl -s -H "X-API-Key: $(API_KEY)" http://$(HOST):$(PORT)/jobs/$$JOB_ID | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])"); \
	echo "   Status: $$STATUS"; \
	if [ "$$STATUS" = "successful" ]; then echo "   ✅ Buffer job passed"; else echo "   ❌ Buffer job failed (status=$$STATUS)"; exit 1; fi; \
	curl -s -X DELETE -H "X-API-Key: $(API_KEY)" http://$(HOST):$(PORT)/jobs/$$JOB_ID > /dev/null; \
	echo "   Job cleaned up"

_test_zonal_stats:
	@echo ""
	@echo "── Zonal Statistics process ──"
	@$(MAKE) _assert URL="http://$(HOST):$(PORT)/processes/zonal-stats" EXPECT=200 LABEL="GET /processes/zonal-stats" EXTRA='-H "X-API-Key: $(API_KEY)"'
	@echo "   Submitting async zonal-stats job..."
	@JOB_ID=$$(curl -s -X POST \
		-H "Content-Type: application/json" \
		-H "X-API-Key: $(API_KEY)" \
		-H "Prefer: respond-async" \
		-d '{"inputs":{"zone":{"type":"Polygon","coordinates":[[[77.58,12.96],[77.61,12.96],[77.61,12.99],[77.58,12.99],[77.58,12.96]]]},"values":[10,20,30,40,50]}}' \
		http://$(HOST):$(PORT)/processes/zonal-stats/execution | python3 -c "import sys,json; print(json.load(sys.stdin)['jobID'])"); \
	echo "   Job ID: $$JOB_ID"; \
	sleep 2; \
	STATUS=$$(curl -s -H "X-API-Key: $(API_KEY)" http://$(HOST):$(PORT)/jobs/$$JOB_ID | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])"); \
	echo "   Status: $$STATUS"; \
	if [ "$$STATUS" = "successful" ]; then echo "   ✅ Zonal stats job passed"; else echo "   ❌ Zonal stats job failed (status=$$STATUS)"; exit 1; fi; \
	curl -s -X DELETE -H "X-API-Key: $(API_KEY)" http://$(HOST):$(PORT)/jobs/$$JOB_ID > /dev/null; \
	echo "   Job cleaned up"

_assert:
	@ACTUAL=$$(curl -s -o /dev/null -w "%{http_code}" $(EXTRA) "$(URL)"); \
	if [ "$$ACTUAL" = "$(EXPECT)" ]; then \
		echo "   ✅ $(LABEL) ($(EXPECT))"; \
	else \
		echo "   ❌ $(LABEL) — expected $(EXPECT), got $$ACTUAL"; \
		exit 1; \
	fi
