# OGC API – Processes

A production-grade implementation of the [OGC API – Processes](https://ogcapi.ogc.org/processes/) standard, built with **pygeoapi**, secured behind an **nginx** reverse proxy with **JWT authentication**, and fully containerised with **Docker**.

---

## Table of Contents

- [Part 1 — Backend Establishment & Configuration](#part-1--backend-establishment--configuration)
  - [Implementation Selection](#1-implementation-selection)
  - [Execution Environment](#2-execution-environment)
  - [Configuration Parameters](#3-configuration-parameters)
  - [Required OGC Endpoints](#4-required-ogc-endpoints)
  - [Security Protocols & Authentication](#5-security-protocols--authentication)
  - [Scaling Considerations](#6-scaling-considerations)
- [Part 2 — Sample Process Execution](#part-2--sample-process-execution)
  - [Processes Defined](#1-processes-defined)
  - [Process Registration](#2-process-registration)
  - [Full Lifecycle — Proof of Concept](#3-full-lifecycle--proof-of-concept)
- [Quick Start](#quick-start)
- [Frontend UI](#frontend-ui)
- [Project Structure](#project-structure)
- [Makefile Commands](#makefile-commands)
- [curl Reference](#curl-reference)
- [Production Considerations](#production-considerations)
- [Tech Stack](#tech-stack)
- [OGC Conformance](#ogc-conformance)

---

## Part 1 — Backend Establishment & Configuration

### 1. Implementation Selection

**Technology chosen: [pygeoapi](https://pygeoapi.io/)**

pygeoapi is a mature, actively maintained open-source Python server implementing multiple OGC API standards including OGC API – Processes. It was selected over the available alternatives:

| Alternative | Reason not selected |
|-------------|-------------------|
| PyWPS | Implements the older WPS 1.0/2.0 standard — not OGC API – Processes |
| GeoServer | Java-based, heavyweight, requires additional plugins for OGC API – Processes |
| Custom microservice | Significant effort to achieve full standard compliance from scratch |
| **pygeoapi** | ✅ Native OGC API – Processes support, Python, lightweight, actively maintained |

pygeoapi runs as a **gunicorn WSGI application** inside Docker, behind an nginx reverse proxy. It is never exposed directly to the internet — all traffic enters through nginx, which handles authentication, rate limiting, and security headers before proxying to pygeoapi.

---

### 2. Execution Environment

**Containerisation with Docker and Docker Compose.**

The entire stack runs as three isolated containers on a private Docker bridge network (`ogc-internal`):

```
Browser / curl
      │
      ▼
┌─────────────────────────────────────────┐
│           nginx  (port 80)              │
│                                         │
│  • Reverse proxy                        │
│  • JWT validation via auth_request      │
│  • Rate limiting  (10 req/s, burst 20)  │
│  • CORS headers                         │
│  • Secure HTTP headers                  │
│  • Serves frontend UI at /ui            │
└────────────┬──────────────┬─────────────┘
             │              │
             ▼              ▼
┌────────────────┐  ┌───────────────────────┐
│  auth service  │  │       pygeoapi        │
│  (Flask :5000) │  │   (gunicorn :80)      │
│                │  │                       │
│  /auth/login   │  │  /processes           │
│  /auth/refresh │  │  /processes/{id}      │
│  /auth/revoke  │  │  /processes/{id}/     │
│  /auth/me      │  │    execution          │
│  /auth/users   │  │  /jobs                │
│                │  │  /jobs/{id}           │
│  Users/tokens  │  │  /jobs/{id}/results   │
│  stored in     │  │                       │
│  /data/*.json  │  │  Jobs stored in       │
│                │  │  TinyDB               │
└────────────────┘  └───────────────────────┘

All containers on isolated ogc-internal bridge network.
Only nginx is exposed to the host on port 80.
pygeoapi and auth are never directly reachable from outside.
```

**Request flow:**

1. Every request hits **nginx** first
2. Public endpoints (`/`, `/conformance`, `/openapi`, `/ui`) are proxied directly — no auth check
3. For all other endpoints, nginx sends an internal subrequest to `/_auth_validate` (auth service)
4. If the auth service returns `200`, nginx injects `X-Auth-User` and `X-Auth-Role` headers and forwards to pygeoapi
5. If auth fails, nginx returns an OGC RFC 7807-formatted `401` or `403` — pygeoapi never sees the request

**Dockerfiles:**

- `./Dockerfile` — extends `geopython/pygeoapi:latest`, installs `shapely` and `pyproj` into the existing venv at `/venv`
- `./auth/Dockerfile` — `python:3.11-slim`, installs Flask and gunicorn, runs as a non-root `authuser`

pygeoapi only starts after the auth service is confirmed healthy, and nginx only starts after both are healthy — enforced via `depends_on` with `condition: service_healthy` in docker-compose.

---

### 3. Configuration Parameters

**pygeoapi** — `config/pygeoapi-config.yml`:

```yaml
server:
  bind:
    host: 0.0.0.0
    port: 80
  manager:
    name: TinyDB                        # Job persistence backend
    connection: /tmp/pygeoapi-jobs.db   # Job storage path inside container
    output_dir: /tmp

resources:                              # Processes registered here (NOT under 'processes:')
  buffer:
    type: process
    processor:
      name: processes.buffer_process.BufferProcessor
  zonal-stats:
    type: process
    processor:
      name: processes.zonal_stats_process.ZonalStatsProcessor
```

**Auth service** — `.env`:

| Variable | Default | Description |
|----------|---------|-------------|
| `JWT_SECRET` | `super-secret-...` | HMAC-SHA256 signing key — **change in production** |
| `TOKEN_EXPIRY_SECONDS` | `3600` | JWT lifetime in seconds (default 1 hour) |

Copy `.env.example` to `.env` to get started. The defaults work for local development.

---

### 4. Required OGC Endpoints

All required OGC API – Processes endpoints are implemented and verified working.

#### Public (no authentication required)

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/` | Landing page — service metadata and resource links |
| `GET` | `/conformance` | OGC conformance classes satisfied by this implementation |
| `GET` | `/openapi` | OpenAPI 3.0 specification document |

#### Protected (JWT Bearer token required)

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/processes` | List all registered processes |
| `GET` | `/processes/{processId}` | Full process description with input/output schemas |
| `POST` | `/processes/{processId}/execution` | Execute a process — synchronous or asynchronous |
| `GET` | `/jobs` | List all submitted jobs |
| `GET` | `/jobs/{jobId}` | Job status, progress percentage, and timestamps |
| `GET` | `/jobs/{jobId}/results` | Retrieve completed job output |
| `DELETE` | `/jobs/{jobId}` | Dismiss and delete a job |

#### Response formats

Append `?f=` to any GET request:

| Parameter | Content-Type | Description |
|-----------|-------------|-------------|
| `?f=json` | `application/json` | Standard JSON — default |
| `?f=jsonld` | `application/ld+json` | JSON-LD with OGC linked data context |
| `?f=html` | `text/html` | Human-readable HTML rendered by pygeoapi |

---

### 5. Security Protocols & Authentication

All security is enforced at the **nginx layer** — before any request reaches pygeoapi.

#### JWT Authentication

A dedicated Flask auth service (`auth/app.py`) handles all user and token management. Tokens are fully spec-compliant JWTs signed with **HMAC-SHA256**, implemented using Python's standard library (`hmac`, `hashlib`, `base64`) — no external JWT dependency. The tokens are in the standard `header.payload.signature` format and decodable by any JWT debugger such as [jwt.io](https://jwt.io).

```
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9    ← Base64url({"alg":"HS256","typ":"JWT"})
.eyJzdWIiOiJhZG1pbiIsInJvbGUiOiJhZG1...  ← Base64url({sub, role, exp, iat, jti})
.xK8z2mP...                               ← HMAC-SHA256 signature
```

- Passwords hashed with **PBKDF2-SHA256** (260,000 iterations)
- Token **revocation** tracked server-side — logout invalidates the token immediately, before expiry
- nginx validates every JWT via `auth_request` internal subrequest before proxying to pygeoapi

**Auth endpoints:**

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `POST` | `/auth/login` | Public | Get a JWT token |
| `POST` | `/auth/refresh` | Auth | Issue a new token before expiry |
| `POST` | `/auth/revoke` | Auth | Invalidate current token (logout) |
| `GET` | `/auth/me` | Auth | Current user info and token expiry |
| `GET` | `/auth/users` | Admin | List all users |
| `DELETE` | `/auth/users/{username}` | Admin | Deactivate a user |

Default credentials (seeded on first boot): `admin / admin123` — change before production.

New users are created by admins only — no self-registration from the UI:

```bash
TOKEN=$(curl -s -X POST http://localhost/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

curl -X POST http://localhost/auth/register \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"username":"newuser","password":"securepass123","role":"user"}'
```

#### CORS Policies

```nginx
add_header Access-Control-Allow-Origin  "*" always;
add_header Access-Control-Allow-Methods "GET, POST, DELETE, OPTIONS" always;
add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;
```

OPTIONS preflight requests return `204 No Content` before reaching pygeoapi. Replace `"*"` with your domain in production.

#### Rate Limiting

```nginx
limit_req_zone $binary_remote_addr zone=ogc_limit:10m  rate=10r/s;  # burst 20
limit_req_zone $binary_remote_addr zone=auth_limit:10m rate=5r/s;   # burst 10
```

Two zones: standard API traffic at 10 req/s and auth endpoints at 5 req/s to slow brute-force attempts.

#### Secure HTTP Headers

```nginx
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options        "DENY"    always;
```

#### Input Validation

Every process input is validated against a JSON Schema defined in the process class before any execution begins. Missing fields, wrong types, or out-of-range values return `400 Bad Request`.

#### Network Isolation

pygeoapi and the auth service are **not exposed to the host machine** — they only listen on the internal `ogc-internal` Docker bridge network. The sole public entry point is nginx on port 80.

---

### 6. Scaling Considerations

The current configuration handles moderate workloads with:

- **Resource limits** on pygeoapi (`cpus: 2`, `memory: 1G` in docker-compose)
- **Rate limiting** at nginx prevents any single client overwhelming the service
- **Stateless API layer** — pygeoapi holds no session state; auth state lives in the auth service, job state in TinyDB

For high-traffic production use, see [Production Considerations](#production-considerations) which covers horizontal pygeoapi replicas, PostgreSQL for shared job state, and Kubernetes.

---

## Part 2 — Sample Process Execution

### 1. Processes Defined

Two meaningful geospatial processes are implemented, directly matching the examples cited in the brief.

#### Buffer Process

**ID:** `buffer` | **File:** `processes/buffer_process.py`

Creates a circular buffer polygon around a coordinate point. Projects WGS84 (EPSG:4326) → Web Mercator (EPSG:3857) to apply an accurate metric buffer → reprojects back to WGS84. Returns a GeoJSON Feature.

| Input | Type | Required | Description |
|-------|------|----------|-------------|
| `latitude` | number | Yes | Decimal degrees, -90 to 90 |
| `longitude` | number | Yes | Decimal degrees, -180 to 180 |
| `distance` | number | Yes | Buffer radius in metres |

**Output:** GeoJSON Feature (Polygon) with `center_latitude`, `center_longitude`, and `distance_metres` properties.

#### Zonal Statistics Process

**ID:** `zonal-stats` | **File:** `processes/zonal_stats_process.py`

Computes descriptive statistics over a set of numeric values within a defined zone polygon. Returns count, sum, min, max, mean, median, standard deviation, and range.

| Input | Type | Required | Description |
|-------|------|----------|-------------|
| `zone` | GeoJSON Polygon | Yes | Boundary polygon defining the zone |
| `values` | number[] | Yes | Array of numeric values within the zone |

**Output:** Statistics object — `count`, `sum`, `min`, `max`, `mean`, `median`, `std_dev`, `range`.

---

### 2. Process Registration

Processes are registered in `config/pygeoapi-config.yml` under `resources:`. Each process class extends pygeoapi's `BaseProcessor`, defines its input/output metadata, and implements an `execute()` method. The `PYTHONPATH=/pygeoapi` environment variable in docker-compose ensures gunicorn can discover the process modules at startup.

```yaml
resources:
  buffer:
    type: process
    processor:
      name: processes.buffer_process.BufferProcessor

  zonal-stats:
    type: process
    processor:
      name: processes.zonal_stats_process.ZonalStatsProcessor
```

---

### 3. Full Lifecycle — Proof of Concept

This section demonstrates the complete OGC API – Processes execution lifecycle: **submission → monitoring → result retrieval → cleanup**, for both synchronous and asynchronous modes.

Get your token first:

```bash
TOKEN=$(curl -s -X POST http://localhost/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
```

#### Synchronous Execution — Buffer (HTTP 200)

```bash
curl -X POST http://localhost/processes/buffer/execution \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"inputs": {"latitude": 12.9716, "longitude": 77.5946, "distance": 500}}'
```

Response (`200 OK`) — result returned immediately:
```json
{
  "type": "Feature",
  "geometry": {
    "type": "Polygon",
    "coordinates": [[[77.5991, 12.9716], [77.5990, 12.9731], "..."]]
  },
  "properties": {
    "center_latitude": 12.9716,
    "center_longitude": 77.5946,
    "distance_metres": 500.0
  }
}
```

#### Synchronous Execution — Zonal Statistics (HTTP 200)

```bash
curl -X POST http://localhost/processes/zonal-stats/execution \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
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
      "values": [12.5, 34.2, 8.9, 45.1, 23.7, 67.3, 15.6, 29.8, 52.4, 38.0]
    }
  }'
```

Response (`200 OK`):
```json
{
  "type": "ZonalStatisticsResult",
  "statistics": {
    "count": 10,
    "sum": 327.5,
    "min": 8.9,
    "max": 67.3,
    "mean": 32.75,
    "median": 31.35,
    "std_dev": 18.32,
    "range": 58.4
  }
}
```

#### Asynchronous Execution — Full Lifecycle (HTTP 201)

Add `Prefer: respond-async`. The server returns `201 Created` with a `jobID` immediately; processing happens in the background.

**Step 1 — Submit:**
```bash
curl -X POST http://localhost/processes/buffer/execution \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Prefer: respond-async" \
  -d '{"inputs": {"latitude": 12.9716, "longitude": 77.5946, "distance": 1000}}'
```
```json
{"jobID": "33136070-1c40-11f1-8ba3-15d7c94da424", "status": "accepted"}
```

**Step 2 — Monitor:**
```bash
curl "http://localhost/jobs/33136070-1c40-11f1-8ba3-15d7c94da424?f=json" \
  -H "Authorization: Bearer $TOKEN"
```
```json
{
  "status": "successful",
  "progress": 100,
  "created": "2026-03-10T05:15:48.559346Z",
  "finished": "2026-03-10T05:15:48.583483Z"
}
```

Status values: `accepted` → `running` → `successful` / `failed`

**Step 3 — Retrieve result:**
```bash
curl "http://localhost/jobs/33136070-1c40-11f1-8ba3-15d7c94da424/results?f=json" \
  -H "Authorization: Bearer $TOKEN"
```

Returns the GeoJSON Feature polygon — identical output to synchronous execution.

**Step 4 — Delete job:**
```bash
curl -X DELETE "http://localhost/jobs/33136070-1c40-11f1-8ba3-15d7c94da424" \
  -H "Authorization: Bearer $TOKEN"
```
```json
{"status": "dismissed"}
```

#### Lifecycle Diagram

```
Client                    nginx              auth service        pygeoapi
  │                         │                     │                 │
  ├─ POST /execution ───────▶                     │                 │
  │  Prefer: respond-async  ├─ /_auth_validate ──▶│                 │
  │                         │◀─ 200 OK ───────────│                 │
  │                         ├─ proxy ─────────────────────────────▶ │
  │◀─ 201 Created ──────────────────────────────────────────────── │
  │   + jobID               │                     │                 │
  │                         │                     │                 │
  ├─ GET /jobs/{id} ────────▶                     │                 │
  │                         ├─ /_auth_validate ──▶│                 │
  │                         ├─ proxy ─────────────────────────────▶ │
  │◀─ status: successful ───────────────────────────────────────── │
  │                         │                     │                 │
  ├─ GET /jobs/{id}/results ▶                     │                 │
  │                         ├─ proxy ─────────────────────────────▶ │
  │◀─ GeoJSON result ───────────────────────────────────────────── │
  │                         │                     │                 │
  ├─ DELETE /jobs/{id} ─────▶                     │                 │
  │◀─ dismissed ────────────────────────────────────────────────── │
```

---

## Quick Start

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Mac/Windows) or Docker Engine + Compose Plugin (Linux)
- Port `80` free on your machine

### Steps

```bash
# 1. Enter the project directory
cd ogc-api

# 2. Create your environment file
cp .env.example .env

# 3. Build and start all three containers
make restart

# 4. Confirm all containers are healthy
docker compose ps
# NAME                   STATUS
# ogc-api-auth-1         Up (healthy)
# ogc-api-pygeoapi-1     Up (healthy)
# ogc-api-nginx-1        Up

# 5. Open the UI
open http://localhost/ui
# Login: admin / admin123
```

---

## Frontend UI

An interactive single-page application at **http://localhost/ui** — React + Leaflet loaded from CDN, no build step required.

| Tab | Description |
|-----|-------------|
| **Map** | Click to place a buffer point, draw a polygon for zonal stats, execute processes and see GeoJSON results overlaid on the map |
| **API** | Click any endpoint in the sidebar to call it and view the raw JSON response |
| **Jobs** | Enter a job ID to check status, retrieve results, or delete. Results link directly to the Map tab |
| **Log** | Running history of every HTTP request in the current session with status codes |
| **Docs** | Full in-app reference — endpoint descriptions, process schemas, auth guide, async lifecycle diagram |

**Sidebar controls:** response format toggle (`?f=json` / `?f=jsonld` / `?f=html`), sync/async execution mode toggle, active JWT display, user menu with sign out.

---

## Project Structure

```
ogc-api/
├── Dockerfile                  # pygeoapi image (extends geopython/pygeoapi:latest)
├── docker-compose.yml          # 3 services: nginx, auth, pygeoapi + network + volumes
├── Makefile                    # up, down, restart, logs, status, shell, test, clean
├── requirements.txt            # shapely, pyproj for pygeoapi
├── .env.example                # Environment variable template — copy to .env
│
├── auth/
│   ├── Dockerfile              # python:3.11-slim, non-root user
│   ├── app.py                  # Flask JWT auth service — login, refresh, revoke, users
│   └── requirements.txt        # flask==3.0.3, gunicorn==21.2.0
│
├── config/
│   └── pygeoapi-config.yml     # OGC API server config + process registration + TinyDB manager
│
├── frontend/
│   └── index.html              # Self-contained React + Leaflet UI
│
├── nginx/
│   └── nginx.conf              # Reverse proxy, auth_request, rate limiting, CORS, headers
│
└── processes/
    ├── buffer_process.py       # Geodesic buffer — WGS84 → EPSG:3857 → buffer → WGS84
    └── zonal_stats_process.py  # Zonal statistics — count, sum, min, max, mean, median, std_dev
```

---

## Makefile Commands

Run all commands from the `ogc-api/` root directory.

| Command | Description |
|---------|-------------|
| `make restart` | Stop, rebuild images, and start the full stack |
| `make up` | Build and start without stopping first |
| `make down` | Stop and remove all containers |
| `make logs` | Tail live logs from all containers |
| `make status` | Show container status and health |
| `make shell` | Open bash inside the pygeoapi container |
| `make test` | Run the full test suite (15 assertions) |
| `make clean` | Remove all containers, images, and volumes |

---

## curl Reference

A complete shell script covering every endpoint is included:

```bash
chmod +x ogc-api-curl-reference.sh
./ogc-api-curl-reference.sh
```

Covers all 10 sections: authentication, discovery endpoints, process discovery, buffer execution (sync + async), zonal stats execution (sync + async), job management, complete async lifecycle walkthrough, response format variants, error cases, and rate limiting.

---

## Production Considerations

All core requirements are fully implemented. The following were intentionally deferred as out of scope for local development:

| Item | Current state | Production recommendation |
|------|--------------|--------------------------|
| **HTTPS / TLS** | Plain HTTP — fine for localhost | Terminate TLS at nginx with Let's Encrypt or a cloud load balancer |
| **Job persistence** | TinyDB — lost on `docker compose down -v` | Switch to pygeoapi's native PostgreSQL manager |
| **Horizontal scaling** | Single pygeoapi instance | Multiple replicas behind nginx `upstream` + PostgreSQL for shared job state |
| **CORS** | Open to all origins (`*`) | Lock down to your actual frontend domain |
| **JWT secret** | Default placeholder | `openssl rand -hex 32`, stored in a secrets manager — not a plaintext `.env` |
| **Kubernetes** | docker-compose for simplicity | Each service maps cleanly to a Deployment + Service; Kubernetes is listed as an example option in the brief |

---

## Tech Stack

| Component | Technology | Version |
|-----------|-----------|---------|
| OGC API backend | pygeoapi | 0.24 |
| Auth service | Flask + gunicorn | 3.0.3 / 21.2.0 |
| Reverse proxy | nginx | alpine |
| Containerisation | Docker + Compose v2 | — |
| Geospatial libraries | shapely + pyproj | latest |
| Job storage | TinyDB | built-in to pygeoapi |
| Frontend | React + Leaflet | 18 / 1.9.4 |
| Map tiles | CartoDB Dark Matter | — |

---

## OGC Conformance

| Conformance class | Status |
|---|---|
| Core — `/processes`, `/jobs`, `/results` | ✅ |
| Synchronous execution (HTTP 200) | ✅ |
| Asynchronous execution (HTTP 201 + jobID) | ✅ |
| OGC Process Description (input/output schemas) | ✅ |
| Job list with pagination | ✅ |
| Dismiss — `DELETE /jobs/{jobId}` | ✅ |
| Callback | Not implemented (out of scope) |

Full conformance declaration: `GET http://localhost/conformance?f=json`
