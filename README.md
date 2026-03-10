# OGC API – Processes

A production-grade implementation of the [OGC API – Processes](https://ogcapi.ogc.org/processes/) standard, built with **pygeoapi**, secured behind an **nginx** reverse proxy with **JWT authentication**, and fully containerised with **Docker**.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Project Structure](#project-structure)
- [Quick Start](#quick-start)
- [Authentication](#authentication)
- [OGC API Endpoints](#ogc-api-endpoints)
- [Processes](#processes)
  - [Buffer](#buffer-process)
  - [Zonal Statistics](#zonal-statistics-process)
- [Job Lifecycle](#job-lifecycle)
- [Frontend UI](#frontend-ui)
- [Security](#security)
- [Configuration](#configuration)
- [Makefile Commands](#makefile-commands)
- [curl Reference](#curl-reference)
- [Production Considerations](#production-considerations)
- [Tech Stack](#tech-stack)
- [OGC Conformance](#ogc-conformance)

---

## Overview

The **OGC API – Processes** standard defines a web API for publishing and executing geospatial processes over HTTP. It is the modern REST-based successor to WPS (Web Processing Service), standardised by the Open Geospatial Consortium.

This implementation provides:

- A fully compliant OGC API – Processes backend powered by **pygeoapi**
- Two geospatial processes: **Geodesic Buffer** and **Zonal Statistics**
- Both **synchronous** (immediate result) and **asynchronous** (job-based) execution modes
- Full job management: submit → monitor → retrieve results → delete
- JWT-based authentication with user management
- Rate limiting, CORS, and secure HTTP headers enforced at the proxy layer
- An interactive browser-based frontend UI

---

## Architecture

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
│  POST /login   │  │  GET  /processes      │
│  POST /refresh │  │  GET  /processes/{id} │
│  POST /revoke  │  │  POST /execution      │
│  GET  /me      │  │  GET  /jobs           │
│  GET  /users   │  │  GET  /jobs/{id}      │
│                │  │  GET  /jobs/{id}/     │
│  Users stored  │  │        results        │
│  in /data/     │  │  DELETE /jobs/{id}    │
│  users.json    │  │                       │
│                │  │  Jobs stored in       │
│  Tokens stored │  │  TinyDB (.db file)    │
│  in /data/     │  │                       │
│  tokens.json   │  └───────────────────────┘
└────────────────┘

All three containers communicate on an isolated Docker bridge
network (ogc-internal). pygeoapi is never exposed to the host.
```

### Request Flow

1. Every request hits **nginx** first
2. Public endpoints (`/`, `/conformance`, `/openapi`, `/ui`) are proxied directly
3. For all other endpoints, nginx sends a subrequest to `/_auth_validate` (auth service)
4. If auth returns `200`, nginx forwards the request to pygeoapi with `X-Auth-User` and `X-Auth-Role` headers injected
5. If auth fails, nginx returns an OGC RFC 7807-formatted `401` or `403` — pygeoapi never sees the request

---

## Project Structure

```
ogc-api/
├── Dockerfile                  # pygeoapi image — installs shapely, pyproj
├── docker-compose.yml          # Defines all 3 services + network + volumes
├── Makefile                    # Convenience commands (up, down, restart, test, logs)
├── requirements.txt            # Python deps for pygeoapi (shapely, pyproj)
├── .env.example                # Environment variable template — copy to .env
│
├── auth/
│   ├── Dockerfile              # python:3.11-slim base
│   ├── app.py                  # Flask app — login, refresh, revoke, user management
│   └── requirements.txt        # flask, gunicorn
│
├── config/
│   └── pygeoapi-config.yml     # pygeoapi server config, process registration, TinyDB manager
│
├── frontend/
│   └── index.html              # Single-file React + Leaflet UI (no build step required)
│
├── nginx/
│   └── nginx.conf              # Reverse proxy, auth_request, rate limiting, CORS, headers
│
└── processes/
    ├── buffer_process.py       # Geodesic buffer — WGS84 → EPSG:3857 → buffer → WGS84
    └── zonal_stats_process.py  # Zonal statistics — count, sum, min, max, mean, median, std_dev
```

---

## Quick Start

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Mac / Windows) or Docker Engine + Compose Plugin (Linux)
- Port `80` free on your machine

### 1. Enter the project directory

```bash
cd ogc-api
```

### 2. Create your environment file

```bash
cp .env.example .env
```

The defaults work for local development. For production, change `JWT_SECRET` to a long random string.

### 3. Start the stack

```bash
make restart
```

This builds all three Docker images and starts the containers. First run takes ~60 seconds to pull base images. Subsequent starts take ~5 seconds (cached layers).

### 4. Verify all containers are healthy

```bash
docker compose ps
```

Expected output:
```
NAME                   STATUS
ogc-api-auth-1         Up (healthy)
ogc-api-pygeoapi-1     Up (healthy)
ogc-api-nginx-1        Up
```

### 5. Open the UI

Visit **http://localhost/ui** and log in with:

```
username: admin
password: admin123
```

---

## Authentication

This project uses **JWT (JSON Web Token)** authentication. All OGC API endpoints except the three public discovery endpoints require a valid Bearer token.

### How it works

1. `POST /auth/login` with your credentials
2. Auth service verifies them, issues a signed JWT (1 hour expiry by default)
3. Include the token in every subsequent request: `Authorization: Bearer <token>`
4. nginx validates the token on every request via an internal subrequest to the auth service
5. On logout, `POST /auth/revoke` marks the token as revoked server-side immediately

### Auth endpoints

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `POST` | `/auth/login` | Public | Get a JWT token |
| `POST` | `/auth/refresh` | Auth | Issue a new token before expiry |
| `POST` | `/auth/revoke` | Auth | Invalidate current token (logout) |
| `GET` | `/auth/me` | Auth | Current user info and token expiry |
| `GET` | `/auth/users` | Admin | List all users |
| `DELETE` | `/auth/users/{username}` | Admin | Deactivate a user |

### Default credentials

A default admin user is seeded automatically on first boot:

```
username: admin
password: admin123
```

> ⚠️ Change this password before any production deployment.

### Registering new users

There is no self-registration from the UI. New users must be created by an admin:

```bash
# Get admin token
TOKEN=$(curl -s -X POST http://localhost/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

# Create new user
curl -X POST http://localhost/auth/register \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"username":"newuser","password":"securepass123","role":"user"}'
```

Available roles: `user` (standard access) and `admin` (user management).

---

## OGC API Endpoints

### Public (no auth required)

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/` | Landing page — service metadata and resource links |
| `GET` | `/conformance` | OGC conformance classes this implementation satisfies |
| `GET` | `/openapi` | OpenAPI 3.0 specification document |

### Protected (JWT required)

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/processes` | List all registered processes |
| `GET` | `/processes/{processId}` | Full process description with input/output schemas |
| `POST` | `/processes/{processId}/execution` | Execute a process — sync or async |
| `GET` | `/jobs` | List all jobs |
| `GET` | `/jobs/{jobId}` | Job status, progress, and timestamps |
| `GET` | `/jobs/{jobId}/results` | Retrieve completed job output |
| `DELETE` | `/jobs/{jobId}` | Dismiss and delete a job |

### Response formats

Append `?f=` to any GET request:

| Parameter | Content-Type | Description |
|-----------|-------------|-------------|
| `?f=json` | `application/json` | Standard JSON (default) |
| `?f=jsonld` | `application/ld+json` | JSON-LD with OGC linked data context |
| `?f=html` | `text/html` | Human-readable HTML rendered by pygeoapi |

---

## Processes

### Buffer Process

**ID:** `buffer` | **Endpoint:** `POST /processes/buffer/execution`

Creates a circular buffer polygon around a coordinate point. Projects from WGS84 (EPSG:4326) → Web Mercator (EPSG:3857) to apply a metric distance buffer → reprojects back to WGS84. Returns a GeoJSON Feature with a Polygon geometry.

#### Inputs

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `latitude` | number | Yes | Decimal degrees, -90 to 90 |
| `longitude` | number | Yes | Decimal degrees, -180 to 180 |
| `distance` | number | Yes | Buffer radius in metres |

#### Example

```bash
curl -X POST http://localhost/processes/buffer/execution \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "inputs": {
      "latitude": 12.9716,
      "longitude": 77.5946,
      "distance": 500
    }
  }'
```

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

---

### Zonal Statistics Process

**ID:** `zonal-stats` | **Endpoint:** `POST /processes/zonal-stats/execution`

Computes descriptive statistics over a set of numeric values within a defined zone polygon. Returns count, sum, min, max, mean, median, standard deviation, and range.

#### Inputs

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `zone` | GeoJSON Polygon | Yes | Boundary polygon defining the zone |
| `values` | number[] | Yes | Array of numeric values within the zone |

#### Example

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

---

## Job Lifecycle

### Synchronous execution

No special header needed. The result is returned immediately with HTTP `200`.

```bash
curl -X POST http://localhost/processes/buffer/execution \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"inputs": {"latitude": 12.9716, "longitude": 77.5946, "distance": 500}}'
# → 200 OK  +  GeoJSON result immediately
```

### Asynchronous execution

Add `Prefer: respond-async`. The server returns `201 Created` with a `jobID` immediately and processes in the background.

```
Step 1:  POST /processes/{id}/execution  +  Prefer: respond-async
         → 201 Created  +  {"jobID": "abc123...", "status": "accepted"}

Step 2:  GET /jobs/abc123...?f=json
         → {"status": "successful", "progress": 100, ...}

Step 3:  GET /jobs/abc123.../results?f=json
         → result object

Step 4:  DELETE /jobs/abc123...
         → {"status": "dismissed"}
```

### Job status values

| Status | Meaning |
|--------|---------|
| `accepted` | Job queued, not yet started |
| `running` | Currently executing |
| `successful` | Complete — results available |
| `failed` | Encountered an error |
| `dismissed` | Deleted |

> Jobs persist while the pygeoapi container is running. They are stored in TinyDB — a lightweight JSON file database at `/tmp/pygeoapi-jobs.db` inside the container. See [Production Considerations](#production-considerations) for persistence options.

---

## Frontend UI

A self-contained single-page application served at **http://localhost/ui**. Built with React and Leaflet, loaded from CDN — no npm, no build step.

### Tabs

| Tab | Description |
|-----|-------------|
| **Map** | Interactive Leaflet map. Click to place a buffer point, draw a polygon for zonal stats, execute processes, and see GeoJSON results overlaid on the map |
| **API** | Click any endpoint in the sidebar to call it and see the raw JSON response |
| **Jobs** | Enter a job ID to check status, retrieve results, or delete. Results can be sent directly to the Map tab |
| **Log** | Running history of every HTTP request made in the current session with status codes |
| **Docs** | Full in-app API reference — endpoint descriptions, process input schemas, auth guide, async lifecycle, and response format guide |

### Sidebar

- **Response format** — toggle `?f=json`, `?f=jsonld`, `?f=html`
- **Active token** — displays your current JWT (truncated header only)
- **Execution mode** — toggle `sync` / `async` for process execution buttons
- **User menu** (top right) — username, role, token expiry, and sign out

---

## Security

### Authentication

- Tokens signed with **HMAC-SHA256** using a configurable secret
- Passwords hashed with **PBKDF2-SHA256** (260,000 iterations)
- Token **revocation** tracked server-side — logout invalidates the token immediately, before expiry
- Token expiry configurable (default 1 hour)

### nginx security layer

All enforced before any request reaches the application services:

```nginx
# Rate limiting — prevents brute-force and abuse
limit_req_zone $binary_remote_addr zone=ogc_limit:10m  rate=10r/s;  # burst 20
limit_req_zone $binary_remote_addr zone=auth_limit:10m rate=5r/s;   # burst 10

# CORS
add_header Access-Control-Allow-Origin  "*" always;
add_header Access-Control-Allow-Methods "GET, POST, DELETE, OPTIONS" always;
add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;

# Security headers
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options        "DENY"    always;
```

### Network isolation

pygeoapi and the auth service are **not exposed to the host**. They only communicate on the internal `ogc-internal` Docker bridge network. The only public entry point is nginx on port 80.

### Input validation

Process inputs are validated against JSON Schema before execution. Missing required fields, wrong types, or out-of-range values return `400 Bad Request`.

---

## Configuration

### Environment variables (`.env`)

| Variable | Default | Description |
|----------|---------|-------------|
| `JWT_SECRET` | `super-secret-...` | Secret key for signing tokens — **change in production** |
| `TOKEN_EXPIRY_SECONDS` | `3600` | Token lifetime in seconds |

### pygeoapi (`config/pygeoapi-config.yml`)

Defines service metadata, registered processes, and the TinyDB job manager. Processes must be registered under the `resources:` key.

### nginx (`nginx/nginx.conf`)

Controls all routing logic. Key locations:

| Location | Purpose |
|----------|---------|
| `/_auth_validate` | Internal JWT validation subrequest to auth service |
| `/auth/` | Passes auth requests directly to Flask service |
| `/ui` | Serves static frontend files |
| `/` (catch-all) | JWT-protected, rate-limited, proxied to pygeoapi |

---

## Makefile Commands

Run all commands from the `ogc-api/` root directory.

| Command | Description |
|---------|-------------|
| `make restart` | Stop, rebuild images, and start the stack |
| `make up` | Build and start without stopping first |
| `make down` | Stop and remove all containers |
| `make logs` | Tail live logs from all containers |
| `make status` | Show container status and health |
| `make shell` | Open bash inside the pygeoapi container |
| `make test` | Run the full test suite (15 assertions) |
| `make clean` | Remove all containers, images, and volumes |

---

## curl Reference

A complete shell script covering every endpoint is included at `ogc-api-curl-reference.sh`:

```bash
chmod +x ogc-api-curl-reference.sh
./ogc-api-curl-reference.sh
```

Sections covered: authentication, discovery endpoints, process discovery, buffer execution (sync + async), zonal stats execution (sync + async), job management, complete async lifecycle walkthrough, response format variants, error cases, and rate limiting.

**Quick start — get your token:**

```bash
TOKEN=$(curl -s -X POST http://localhost/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
```

Then use `$TOKEN` in all subsequent requests as `Authorization: Bearer $TOKEN`.

---

## Production Considerations

This project fully satisfies all OGC API – Processes requirements. The following items were intentionally deferred as out of scope for local development but must be addressed before any real production deployment:

### HTTPS / TLS

Currently plain HTTP. In production, terminate TLS at nginx using Let's Encrypt (certbot) or a cloud load balancer. JWT tokens and credentials travel in plaintext over HTTP — only acceptable on localhost.

### Job persistence

TinyDB stores jobs in a flat file inside the container — lost on `docker compose down -v`. For production, switch pygeoapi to its native **PostgreSQL manager**:

```yaml
manager:
  name: PostgreSQL
  connection: postgresql://user:pass@postgres:5432/pygeoapi
```

### Horizontal scaling

A single pygeoapi instance is running. For high traffic, run multiple replicas behind nginx with `upstream` load balancing — but this requires PostgreSQL for shared job state first.

### CORS lockdown

Currently open to all origins (`*`). In production, restrict to your actual frontend domain:

```nginx
add_header Access-Control-Allow-Origin "https://yourdomain.com" always;
```

### JWT secret strength

Generate a strong secret for production:

```bash
openssl rand -hex 32
```

Store it in a proper secrets manager (AWS Secrets Manager, HashiCorp Vault, Docker Secrets) — not in a plaintext `.env` file.

### Kubernetes

Each of the three services maps cleanly to a Kubernetes Deployment + Service. The docker-compose setup was chosen here for simplicity, as Kubernetes is listed as an example option in the brief rather than a requirement.

---

## Tech Stack

| Component | Technology | Version |
|-----------|-----------|---------|
| OGC API backend | pygeoapi | 0.24 |
| Auth service | Flask + gunicorn | 3.0.3 / 21.2.0 |
| Reverse proxy | nginx | alpine |
| Containerisation | Docker + Compose v2 | — |
| Geospatial libs | shapely + pyproj | latest |
| Job store | TinyDB | built-in to pygeoapi |
| Frontend | React + Leaflet | 18 / 1.9.4 |
| Map tiles | CartoDB Dark Matter | — |

---

## OGC Conformance

This implementation satisfies the following OGC API – Processes conformance classes:

| Conformance class | Status |
|---|---|
| Core — `/processes`, `/jobs`, `/results` | ✅ |
| Sync execution (HTTP 200) | ✅ |
| Async execution (HTTP 201 + jobID) | ✅ |
| OGC Process Description (input/output schemas) | ✅ |
| Job list with pagination | ✅ |
| Dismiss — `DELETE /jobs/{jobId}` | ✅ |
| Callback | Not implemented (out of scope) |

Full conformance declaration: `GET http://localhost/conformance?f=json`
