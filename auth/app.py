"""
OGC API – Processes Auth Service
JWT-based authentication with user management.
"""

import os
import json
import uuid
import hashlib
import hmac
import time
import base64
import re
from datetime import datetime, timezone
from functools import wraps
from flask import Flask, request, jsonify

app = Flask(__name__)

# ── Config ────────────────────────────────────────────────────────────────────
SECRET_KEY   = os.environ.get("JWT_SECRET", "change-me-in-production-use-long-random-string")
TOKEN_EXPIRY = int(os.environ.get("TOKEN_EXPIRY_SECONDS", 3600))   # 1 hour default
DATA_DIR     = os.environ.get("DATA_DIR", "/data")
USERS_FILE   = os.path.join(DATA_DIR, "users.json")
TOKENS_FILE  = os.path.join(DATA_DIR, "tokens.json")

os.makedirs(DATA_DIR, exist_ok=True)

# ── Minimal JWT (no external deps) ───────────────────────────────────────────
def b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

def b64url_decode(s: str) -> bytes:
    padding = 4 - len(s) % 4
    return base64.urlsafe_b64decode(s + "=" * padding)

def create_jwt(payload: dict) -> str:
    header  = b64url_encode(json.dumps({"alg":"HS256","typ":"JWT"}).encode())
    body    = b64url_encode(json.dumps(payload).encode())
    signing = f"{header}.{body}".encode()
    sig     = hmac.new(SECRET_KEY.encode(), signing, hashlib.sha256).digest()
    return f"{header}.{body}.{b64url_encode(sig)}"

def verify_jwt(token: str) -> dict | None:
    try:
        header, body, sig = token.split(".")
        signing  = f"{header}.{body}".encode()
        expected = hmac.new(SECRET_KEY.encode(), signing, hashlib.sha256).digest()
        if not hmac.compare_digest(b64url_encode(expected).encode(), sig.encode()):
            return None
        payload = json.loads(b64url_decode(body))
        if payload.get("exp", 0) < time.time():
            return None
        return payload
    except Exception:
        return None

# ── Storage helpers ───────────────────────────────────────────────────────────
def load_json(path: str, default) -> dict | list:
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return default

def save_json(path: str, data) -> None:
    with open(path, "w") as f:
        json.dump(data, f, indent=2)

def hash_password(password: str) -> str:
    salt = os.urandom(16).hex()
    h    = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 260_000)
    return f"{salt}:{h.hex()}"

def verify_password(password: str, stored: str) -> bool:
    try:
        salt, h = stored.split(":")
        expected = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 260_000)
        return hmac.compare_digest(expected.hex(), h)
    except Exception:
        return False

# ── Seed default admin on first boot ─────────────────────────────────────────
def seed_admin():
    users = load_json(USERS_FILE, {})
    if "admin" not in users:
        users["admin"] = {
            "id":         str(uuid.uuid4()),
            "username":   "admin",
            "password":   hash_password("admin123"),
            "role":       "admin",
            "created_at": datetime.now(timezone.utc).isoformat(),
            "active":     True,
        }
        save_json(USERS_FILE, users)
        app.logger.info("Seeded default admin user (admin / admin123)")

# ── Auth decorator ────────────────────────────────────────────────────────────
def require_admin(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        token = _extract_token()
        if not token:
            return _err(401, "No token provided")
        payload = verify_jwt(token)
        if not payload:
            return _err(401, "Invalid or expired token")
        if payload.get("role") != "admin":
            return _err(403, "Admin role required")
        return f(*args, **kwargs)
    return wrapper

def _extract_token() -> str | None:
    auth = request.headers.get("Authorization", "")
    if auth.startswith("Bearer "):
        return auth[7:]
    return request.headers.get("X-API-Key") or request.args.get("token")

def _err(status: int, detail: str) -> tuple:
    return jsonify({
        "type":   "https://www.opengis.net/def/rel/ogc/1.0/exception",
        "title":  {401:"Unauthorized", 403:"Forbidden", 400:"Bad Request", 404:"Not Found", 409:"Conflict"}.get(status, "Error"),
        "status": status,
        "detail": detail,
    }), status

# ── Routes ────────────────────────────────────────────────────────────────────

@app.route("/auth/health")
def health():
    return jsonify({"status": "ok", "service": "auth"}), 200


@app.route("/auth/register", methods=["POST"])
def register():
    """Register a new user. Admin only (except first-time setup if no users exist)."""
    data = request.get_json(silent=True) or {}
    username = data.get("username", "").strip().lower()
    password = data.get("password", "")
    role     = data.get("role", "user")

    if not username or not password:
        return _err(400, "username and password are required")
    if not re.match(r"^[a-z0-9_]{3,32}$", username):
        return _err(400, "username must be 3-32 chars, lowercase alphanumeric and underscores only")
    if len(password) < 6:
        return _err(400, "password must be at least 6 characters")
    if role not in ("user", "admin"):
        return _err(400, "role must be 'user' or 'admin'")

    users = load_json(USERS_FILE, {})

    # Allow open registration only if no users exist yet (bootstrapping)
    if users:
        token = _extract_token()
        if not token:
            return _err(401, "Registration requires admin authentication")
        payload = verify_jwt(token)
        if not payload or payload.get("role") != "admin":
            return _err(403, "Only admins can register new users")

    if username in users:
        return _err(409, f"User '{username}' already exists")

    users[username] = {
        "id":         str(uuid.uuid4()),
        "username":   username,
        "password":   hash_password(password),
        "role":       role,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "active":     True,
    }
    save_json(USERS_FILE, users)

    return jsonify({
        "message":    f"User '{username}' created successfully",
        "username":   username,
        "role":       role,
        "created_at": users[username]["created_at"],
    }), 201


@app.route("/auth/login", methods=["POST"])
def login():
    """Authenticate and receive a JWT token."""
    data     = request.get_json(silent=True) or {}
    username = data.get("username", "").strip().lower()
    password = data.get("password", "")

    if not username or not password:
        return _err(400, "username and password are required")

    users = load_json(USERS_FILE, {})
    user  = users.get(username)

    if not user or not user.get("active"):
        return _err(401, "Invalid credentials")
    if not verify_password(password, user["password"]):
        return _err(401, "Invalid credentials")

    now     = int(time.time())
    payload = {
        "sub":      username,
        "role":     user["role"],
        "user_id":  user["id"],
        "iat":      now,
        "exp":      now + TOKEN_EXPIRY,
        "jti":      str(uuid.uuid4()),
    }
    token = create_jwt(payload)

    # Log the token so nginx lua can also validate (store active JTIs)
    tokens = load_json(TOKENS_FILE, {})
    tokens[payload["jti"]] = {
        "username":   username,
        "issued_at":  datetime.fromtimestamp(now, timezone.utc).isoformat(),
        "expires_at": datetime.fromtimestamp(now + TOKEN_EXPIRY, timezone.utc).isoformat(),
        "revoked":    False,
    }
    save_json(TOKENS_FILE, tokens)

    return jsonify({
        "token":      token,
        "token_type": "Bearer",
        "expires_in": TOKEN_EXPIRY,
        "username":   username,
        "role":       user["role"],
    }), 200


@app.route("/auth/validate", methods=["GET", "POST"])
def validate():
    """
    Internal endpoint called by nginx auth_request.
    Returns 200 if token valid, 401 otherwise.
    nginx passes the Authorization header through.
    """
    token = _extract_token()
    if not token:
        return "", 401

    payload = verify_jwt(token)
    if not payload:
        return "", 401

    # Check token not revoked
    tokens = load_json(TOKENS_FILE, {})
    jti    = payload.get("jti", "")
    entry  = tokens.get(jti, {})
    if entry.get("revoked"):
        return "", 401

    # Pass user info to upstream via headers
    resp = app.make_response(("", 200))
    resp.headers["X-Auth-User"] = payload.get("sub", "")
    resp.headers["X-Auth-Role"] = payload.get("role", "")
    return resp


@app.route("/auth/refresh", methods=["POST"])
def refresh():
    """Issue a new token given a still-valid token."""
    token = _extract_token()
    if not token:
        return _err(401, "No token provided")
    payload = verify_jwt(token)
    if not payload:
        return _err(401, "Invalid or expired token")

    # Revoke old token
    tokens = load_json(TOKENS_FILE, {})
    old_jti = payload.get("jti", "")
    if old_jti in tokens:
        tokens[old_jti]["revoked"] = True

    now      = int(time.time())
    new_payload = {
        "sub":     payload["sub"],
        "role":    payload["role"],
        "user_id": payload["user_id"],
        "iat":     now,
        "exp":     now + TOKEN_EXPIRY,
        "jti":     str(uuid.uuid4()),
    }
    new_token = create_jwt(new_payload)
    tokens[new_payload["jti"]] = {
        "username":   payload["sub"],
        "issued_at":  datetime.fromtimestamp(now, timezone.utc).isoformat(),
        "expires_at": datetime.fromtimestamp(now + TOKEN_EXPIRY, timezone.utc).isoformat(),
        "revoked":    False,
    }
    save_json(TOKENS_FILE, tokens)

    return jsonify({
        "token":      new_token,
        "token_type": "Bearer",
        "expires_in": TOKEN_EXPIRY,
    }), 200


@app.route("/auth/revoke", methods=["POST"])
def revoke():
    """Revoke the current token."""
    token = _extract_token()
    if not token:
        return _err(401, "No token provided")
    payload = verify_jwt(token)
    if not payload:
        return _err(401, "Invalid token")

    tokens  = load_json(TOKENS_FILE, {})
    jti     = payload.get("jti", "")
    if jti in tokens:
        tokens[jti]["revoked"] = True
        save_json(TOKENS_FILE, tokens)

    return jsonify({"message": "Token revoked successfully"}), 200


@app.route("/auth/me", methods=["GET"])
def me():
    """Return info about the currently authenticated user."""
    token = _extract_token()
    if not token:
        return _err(401, "No token provided")
    payload = verify_jwt(token)
    if not payload:
        return _err(401, "Invalid or expired token")

    users = load_json(USERS_FILE, {})
    user  = users.get(payload["sub"], {})

    return jsonify({
        "username":   payload["sub"],
        "role":       payload["role"],
        "created_at": user.get("created_at"),
        "expires_at": datetime.fromtimestamp(payload["exp"], timezone.utc).isoformat(),
    }), 200


@app.route("/auth/users", methods=["GET"])
@require_admin
def list_users():
    """List all users. Admin only."""
    users = load_json(USERS_FILE, {})
    return jsonify({
        "users": [
            {k: v for k, v in u.items() if k != "password"}
            for u in users.values()
        ]
    }), 200


@app.route("/auth/users/<username>", methods=["DELETE"])
@require_admin
def delete_user(username):
    """Deactivate a user. Admin only."""
    users = load_json(USERS_FILE, {})
    if username not in users:
        return _err(404, f"User '{username}' not found")
    if username == "admin":
        return _err(403, "Cannot deactivate the admin user")
    users[username]["active"] = False
    save_json(USERS_FILE, users)
    return jsonify({"message": f"User '{username}' deactivated"}), 200


@app.route("/auth/tokens", methods=["GET"])
@require_admin
def list_tokens():
    """List all active tokens. Admin only."""
    tokens = load_json(TOKENS_FILE, {})
    active = {jti: t for jti, t in tokens.items() if not t.get("revoked")}
    return jsonify({"active_tokens": len(active), "tokens": active}), 200


# ── Startup ───────────────────────────────────────────────────────────────────
seed_admin()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
