#!/usr/bin/env bash
# =============================================================================
#  OGC API – PROCESSES  ·  Complete curl Reference
#  pygeoapi + nginx + JWT auth  ·  http://localhost
# =============================================================================
#
#  USAGE
#    `chmod +x ogc-api-curl-reference.sh
#    ./ogc-api-curl-reference.sh `         # runs every request in sequence
#    source ogc-api-curl-reference.sh     # loads helpers into your shell
#
#  REQUIREMENTS
#    curl, python3 (for JSON pretty-print)
#    Stack running: make restart && docker compose ps
#
# =============================================================================

BASE="http://localhost"
CONTENT="Content-Type: application/json"

# Pretty-print helper — pipe any curl response through this
pp() { python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin), indent=2))" 2>/dev/null || cat; }

sep()  { echo; echo "─────────────────────────────────────────────────────"; echo "  $1"; echo "─────────────────────────────────────────────────────"; }
step() { echo; echo "  ▶  $1"; echo; }


# =============================================================================
#  1.  AUTHENTICATION
# =============================================================================

sep "1. AUTHENTICATION"

# ── 1a. Login ─────────────────────────────────────────────────────────────────
step "1a. Login — get JWT token"
curl -s -X POST "$BASE/auth/login" \
  -H "$CONTENT" \
  -d '{"username":"admin","password":"admin123"}' | pp

# ── 1b. Store token in a variable (for all subsequent requests) ───────────────
step "1b. Store token in TOKEN variable"
TOKEN=$(curl -s -X POST "$BASE/auth/login" \
  -H "$CONTENT" \
  -d '{"username":"admin","password":"admin123"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

echo "  TOKEN=${TOKEN:0:50}..."

# ── 1c. Get current user info ─────────────────────────────────────────────────
step "1c. Get current user info"
curl -s "$BASE/auth/me" \
  -H "Authorization: Bearer $TOKEN" | pp

# ── 1d. List all users (admin only) ──────────────────────────────────────────
step "1d. List all users — admin only"
curl -s "$BASE/auth/users" \
  -H "Authorization: Bearer $TOKEN" | pp

# ── 1e. Register a new user (admin only — no UI registration) ─────────────────
step "1e. Register a new user — admin only"
curl -s -X POST "$BASE/auth/register" \
  -H "$CONTENT" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"username":"newuser","password":"securepass123","role":"user"}' | pp

# ── 1f. Refresh token ─────────────────────────────────────────────────────────
step "1f. Refresh token — get a new token before expiry"
curl -s -X POST "$BASE/auth/refresh" \
  -H "Authorization: Bearer $TOKEN" | pp

# ── 1g. Revoke token (logout) ─────────────────────────────────────────────────
step "1g. Revoke token — logout (invalidates token server-side)"
curl -s -X POST "$BASE/auth/revoke" \
  -H "Authorization: Bearer $TOKEN" | pp

# Re-login after revoke so the rest of the script works
TOKEN=$(curl -s -X POST "$BASE/auth/login" \
  -H "$CONTENT" \
  -d '{"username":"admin","password":"admin123"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

# ── 1h. Deactivate a user (admin only) ───────────────────────────────────────
step "1h. Deactivate a user — admin only"
curl -s -X DELETE "$BASE/auth/users/newuser" \
  -H "Authorization: Bearer $TOKEN" | pp

# ── 1i. Auth error — no token ────────────────────────────────────────────────
step "1i. Auth error — request protected endpoint without token (expect 401)"
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" "$BASE/processes"

# ── 1j. Auth error — invalid token ───────────────────────────────────────────
step "1j. Auth error — invalid token (expect 401)"
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" "$BASE/processes" \
  -H "Authorization: Bearer this.is.not.valid"


# =============================================================================
#  2.  OGC DISCOVERY ENDPOINTS  (no auth required)
# =============================================================================

sep "2. OGC DISCOVERY ENDPOINTS — PUBLIC"

# ── 2a. Landing page ─────────────────────────────────────────────────────────
step "2a. Landing page — service metadata and links"
curl -s "$BASE/" | pp

# ── 2b. Landing page as JSON-LD ──────────────────────────────────────────────
step "2b. Landing page — JSON-LD format"
curl -s "$BASE/?f=jsonld" | pp

# ── 2c. Conformance ──────────────────────────────────────────────────────────
step "2c. Conformance — OGC conformance classes"
curl -s "$BASE/conformance?f=json" | pp

# ── 2d. OpenAPI spec ─────────────────────────────────────────────────────────
step "2d. OpenAPI 3.0 specification"
curl -s "$BASE/openapi?f=json" | pp


# =============================================================================
#  3.  PROCESS DISCOVERY  (auth required)
# =============================================================================

sep "3. PROCESS DISCOVERY — AUTH REQUIRED"

# ── 3a. List all processes ────────────────────────────────────────────────────
step "3a. List all registered processes"
curl -s "$BASE/processes?f=json" \
  -H "Authorization: Bearer $TOKEN" | pp

# ── 3b. Buffer process description ───────────────────────────────────────────
step "3b. Buffer process — full description with inputs/outputs"
curl -s "$BASE/processes/buffer?f=json" \
  -H "Authorization: Bearer $TOKEN" | pp

# ── 3c. Zonal statistics process description ─────────────────────────────────
step "3c. Zonal statistics process — full description with inputs/outputs"
curl -s "$BASE/processes/zonal-stats?f=json" \
  -H "Authorization: Bearer $TOKEN" | pp


# =============================================================================
#  4.  BUFFER PROCESS — EXECUTION
# =============================================================================

sep "4. BUFFER PROCESS EXECUTION"

# ── 4a. Synchronous execution ─────────────────────────────────────────────────
step "4a. Buffer — synchronous execution (result returned immediately)"
curl -s -X POST "$BASE/processes/buffer/execution" \
  -H "$CONTENT" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "inputs": {
      "latitude": 12.9716,
      "longitude": 77.5946,
      "distance": 500
    }
  }' | pp

# ── 4b. Synchronous — larger buffer ───────────────────────────────────────────
step "4b. Buffer — synchronous, 2km radius"
curl -s -X POST "$BASE/processes/buffer/execution" \
  -H "$CONTENT" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "inputs": {
      "latitude": 28.6139,
      "longitude": 77.2090,
      "distance": 2000
    }
  }' | pp

# ── 4c. Asynchronous execution ────────────────────────────────────────────────
step "4c. Buffer — asynchronous execution (returns jobID immediately)"
BUFFER_JOB=$(curl -s -X POST "$BASE/processes/buffer/execution" \
  -H "$CONTENT" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Prefer: respond-async" \
  -d '{
    "inputs": {
      "latitude": 19.0760,
      "longitude": 72.8777,
      "distance": 1000
    }
  }')

echo "$BUFFER_JOB" | pp
BUFFER_JOB_ID=$(echo "$BUFFER_JOB" | python3 -c "import sys,json; print(json.load(sys.stdin).get('jobID',''))" 2>/dev/null)
echo "  Buffer Job ID: $BUFFER_JOB_ID"


# =============================================================================
#  5.  ZONAL STATISTICS PROCESS — EXECUTION
# =============================================================================

sep "5. ZONAL STATISTICS PROCESS EXECUTION"

# ── 5a. Synchronous execution ─────────────────────────────────────────────────
step "5a. Zonal stats — synchronous execution"
curl -s -X POST "$BASE/processes/zonal-stats/execution" \
  -H "$CONTENT" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "inputs": {
      "zone": {
        "type": "Polygon",
        "coordinates": [[
          [77.58, 12.96],
          [77.61, 12.96],
          [77.61, 12.99],
          [77.58, 12.99],
          [77.58, 12.96]
        ]]
      },
      "values": [12.5, 34.2, 8.9, 45.1, 23.7, 67.3, 15.6, 29.8, 52.4, 38.0]
    }
  }' | pp

# ── 5b. Synchronous — minimal dataset ─────────────────────────────────────────
step "5b. Zonal stats — synchronous, minimal 3-value dataset"
curl -s -X POST "$BASE/processes/zonal-stats/execution" \
  -H "$CONTENT" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "inputs": {
      "zone": {
        "type": "Polygon",
        "coordinates": [[
          [77.50, 12.90], [77.60, 12.90],
          [77.60, 13.00], [77.50, 13.00],
          [77.50, 12.90]
        ]]
      },
      "values": [100.0, 200.0, 300.0]
    }
  }' | pp

# ── 5c. Asynchronous execution ────────────────────────────────────────────────
step "5c. Zonal stats — asynchronous execution"
ZONAL_JOB=$(curl -s -X POST "$BASE/processes/zonal-stats/execution" \
  -H "$CONTENT" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Prefer: respond-async" \
  -d '{
    "inputs": {
      "zone": {
        "type": "Polygon",
        "coordinates": [[
          [77.58, 12.96], [77.61, 12.96],
          [77.61, 12.99], [77.58, 12.99],
          [77.58, 12.96]
        ]]
      },
      "values": [5.1, 10.2, 15.3, 20.4, 25.5, 30.6]
    }
  }')

echo "$ZONAL_JOB" | pp
ZONAL_JOB_ID=$(echo "$ZONAL_JOB" | python3 -c "import sys,json; print(json.load(sys.stdin).get('jobID',''))" 2>/dev/null)
echo "  Zonal Job ID: $ZONAL_JOB_ID"


# =============================================================================
#  6.  JOB MANAGEMENT — FULL LIFECYCLE
# =============================================================================

sep "6. JOB MANAGEMENT — FULL OGC LIFECYCLE"

# Allow async jobs to complete
sleep 2

# ── 6a. List all jobs ─────────────────────────────────────────────────────────
step "6a. List all jobs"
curl -s "$BASE/jobs?f=json" \
  -H "Authorization: Bearer $TOKEN" | pp

# ── 6b. Get buffer job status ─────────────────────────────────────────────────
step "6b. Get buffer job status"
if [ -n "$BUFFER_JOB_ID" ]; then
  curl -s "$BASE/jobs/$BUFFER_JOB_ID?f=json" \
    -H "Authorization: Bearer $TOKEN" | pp
else
  echo "  No buffer job ID available — run step 4c first"
fi

# ── 6c. Get zonal job status ──────────────────────────────────────────────────
step "6c. Get zonal stats job status"
if [ -n "$ZONAL_JOB_ID" ]; then
  curl -s "$BASE/jobs/$ZONAL_JOB_ID?f=json" \
    -H "Authorization: Bearer $TOKEN" | pp
else
  echo "  No zonal job ID available — run step 5c first"
fi

# ── 6d. Get buffer job results ────────────────────────────────────────────────
step "6d. Get buffer job results (GeoJSON polygon)"
if [ -n "$BUFFER_JOB_ID" ]; then
  curl -s "$BASE/jobs/$BUFFER_JOB_ID/results?f=json" \
    -H "Authorization: Bearer $TOKEN" | pp
else
  echo "  No buffer job ID available"
fi

# ── 6e. Get zonal job results ────────────────────────────────────────────────
step "6e. Get zonal stats job results (statistics object)"
if [ -n "$ZONAL_JOB_ID" ]; then
  curl -s "$BASE/jobs/$ZONAL_JOB_ID/results?f=json" \
    -H "Authorization: Bearer $TOKEN" | pp
else
  echo "  No zonal job ID available"
fi

# ── 6f. Delete buffer job ─────────────────────────────────────────────────────
step "6f. Delete (dismiss) the buffer job"
if [ -n "$BUFFER_JOB_ID" ]; then
  curl -s -X DELETE "$BASE/jobs/$BUFFER_JOB_ID" \
    -H "Authorization: Bearer $TOKEN" | pp
else
  echo "  No buffer job ID available"
fi

# ── 6g. Delete zonal job ──────────────────────────────────────────────────────
step "6g. Delete (dismiss) the zonal stats job"
if [ -n "$ZONAL_JOB_ID" ]; then
  curl -s -X DELETE "$BASE/jobs/$ZONAL_JOB_ID" \
    -H "Authorization: Bearer $TOKEN" | pp
else
  echo "  No zonal job ID available"
fi

# ── 6h. Verify deletion — job should now return 404 ──────────────────────────
step "6h. Verify deletion — expect 404"
if [ -n "$BUFFER_JOB_ID" ]; then
  curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" \
    "$BASE/jobs/$BUFFER_JOB_ID" \
    -H "Authorization: Bearer $TOKEN"
fi


# =============================================================================
#  7.  COMPLETE ASYNC LIFECYCLE — STEP BY STEP
# =============================================================================

sep "7. COMPLETE ASYNC LIFECYCLE (single walkthrough)"

step "7a. Submit async buffer job"
LIFECYCLE_RESPONSE=$(curl -s -X POST "$BASE/processes/buffer/execution" \
  -H "$CONTENT" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Prefer: respond-async" \
  -d '{
    "inputs": {
      "latitude": 51.5074,
      "longitude": -0.1278,
      "distance": 750
    }
  }')
echo "$LIFECYCLE_RESPONSE" | pp
LIFECYCLE_JOB_ID=$(echo "$LIFECYCLE_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('jobID',''))" 2>/dev/null)
echo "  Job ID: $LIFECYCLE_JOB_ID"

step "7b. Poll status until successful"
for i in 1 2 3; do
  echo "  Poll attempt $i..."
  STATUS=$(curl -s "$BASE/jobs/$LIFECYCLE_JOB_ID?f=json" \
    -H "Authorization: Bearer $TOKEN" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','unknown'))" 2>/dev/null)
  echo "  Status: $STATUS"
  [ "$STATUS" = "successful" ] && break
  sleep 1
done

step "7c. Retrieve results"
curl -s "$BASE/jobs/$LIFECYCLE_JOB_ID/results?f=json" \
  -H "Authorization: Bearer $TOKEN" | pp

step "7d. Cleanup — delete job"
curl -s -X DELETE "$BASE/jobs/$LIFECYCLE_JOB_ID" \
  -H "Authorization: Bearer $TOKEN" | pp


# =============================================================================
#  8.  RESPONSE FORMAT VARIANTS
# =============================================================================

sep "8. RESPONSE FORMAT VARIANTS"

step "8a. JSON format (default)"
curl -s "$BASE/processes?f=json" \
  -H "Authorization: Bearer $TOKEN" | pp

step "8b. JSON-LD format"
curl -s "$BASE/processes?f=jsonld" \
  -H "Authorization: Bearer $TOKEN" | pp

step "8c. HTML format (returns raw HTML)"
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" \
  "$BASE/processes?f=html" \
  -H "Authorization: Bearer $TOKEN"


# =============================================================================
#  9.  ERROR CASES
# =============================================================================

sep "9. ERROR CASES"

step "9a. 401 — no token on protected endpoint"
curl -s "$BASE/processes" | pp

step "9b. 401 — expired/invalid token"
curl -s "$BASE/processes" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.invalid.signature" | pp

step "9c. 404 — non-existent process"
curl -s "$BASE/processes/does-not-exist?f=json" \
  -H "Authorization: Bearer $TOKEN" | pp

step "9d. 404 — non-existent job"
curl -s "$BASE/jobs/00000000-0000-0000-0000-000000000000?f=json" \
  -H "Authorization: Bearer $TOKEN" | pp

step "9e. 400 — missing required input (buffer without distance)"
curl -s -X POST "$BASE/processes/buffer/execution" \
  -H "$CONTENT" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"inputs": {"latitude": 12.9716, "longitude": 77.5946}}' | pp

step "9f. 401 — login with wrong password"
curl -s -X POST "$BASE/auth/login" \
  -H "$CONTENT" \
  -d '{"username":"admin","password":"wrongpassword"}' | pp


# =============================================================================
#  10.  RATE LIMITING
# =============================================================================

sep "10. RATE LIMITING"

step "10a. Rapid-fire requests — nginx allows burst of 20, rate 10/s"
echo "  Sending 5 quick requests..."
for i in 1 2 3 4 5; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/processes?f=json" \
    -H "Authorization: Bearer $TOKEN")
  echo "  Request $i: HTTP $STATUS"
done


# =============================================================================
#  QUICK REFERENCE — COPY-PASTE SNIPPETS
# =============================================================================

sep "QUICK REFERENCE — copy-paste snippets"

cat << 'SNIPPETS'

  # Get token and save to variable
  TOKEN=$(curl -s -X POST http://localhost/auth/login \
    -H "Content-Type: application/json" \
    -d '{"username":"admin","password":"admin123"}' \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

  # Sync buffer — Bengaluru city centre, 500m
  curl -s -X POST http://localhost/processes/buffer/execution \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"inputs":{"latitude":12.9716,"longitude":77.5946,"distance":500}}' \
    | python3 -m json.tool

  # Async buffer — get jobID
  curl -s -X POST http://localhost/processes/buffer/execution \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Prefer: respond-async" \
    -d '{"inputs":{"latitude":12.9716,"longitude":77.5946,"distance":500}}'

  # Check job — replace <jobID>
  curl -s "http://localhost/jobs/<jobID>?f=json" \
    -H "Authorization: Bearer $TOKEN" | python3 -m json.tool

  # Get results — replace <jobID>
  curl -s "http://localhost/jobs/<jobID>/results?f=json" \
    -H "Authorization: Bearer $TOKEN" | python3 -m json.tool

  # Delete job — replace <jobID>
  curl -s -X DELETE "http://localhost/jobs/<jobID>" \
    -H "Authorization: Bearer $TOKEN"

  # Zonal stats — sync
  curl -s -X POST http://localhost/processes/zonal-stats/execution \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"inputs":{"zone":{"type":"Polygon","coordinates":[[[77.58,12.96],[77.61,12.96],[77.61,12.99],[77.58,12.99],[77.58,12.96]]]},"values":[12.5,34.2,8.9,45.1,23.7]}}' \
    | python3 -m json.tool

SNIPPETS

echo
echo "  ✅  Done. All requests complete."
echo