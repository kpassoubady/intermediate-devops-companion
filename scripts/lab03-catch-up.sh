#!/usr/bin/env bash
# ==============================================================================
# Lab 03 Catch-Up Script: Quality gates, pull requests and integration tests
# Explicitly runs all commands from Lab 03 to bring a machine to the end of Lab 03.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H_URL="${H_URL:-http://localhost:3000}"
H_ADMIN="${H_ADMIN:-admin}"
H_PASSWORD="${H_PASSWORD:-Harness-Lab-2026}"
H_STATE="${H_STATE:-$HOME/.lab-runner}"
mkdir -p "$H_STATE"

h_token() {
  if [ ! -s "$H_STATE/api-token" ]; then
    local session
    session=$(curl -fsS -X POST "$H_URL/api/v1/login" -H 'Content-Type: application/json' \
      -d "{\"login_identifier\":\"$H_ADMIN\",\"password\":\"$H_PASSWORD\"}" | jq -r .access_token)
    curl -fsS -X POST "$H_URL/api/v1/user/tokens" -H "Authorization: Bearer $session" \
      -H 'Content-Type: application/json' \
      -d "{\"identifier\":\"lab-runner-$(date +%s)\",\"lifetime\":2592000000000000}" \
      | jq -r .access_token > "$H_STATE/api-token"
    chmod 600 "$H_STATE/api-token"
  fi
  cat "$H_STATE/api-token"
}

h_api() {
  local method=$1 path=$2 data=${3:-}
  if [ -n "$data" ]; then
    curl -fsS -X "$method" "$H_URL$path" -H "Authorization: Bearer $(h_token)" \
      -H 'Content-Type: application/json' -d "$data"
  else
    curl -fsS -X "$method" "$H_URL$path" -H "Authorization: Bearer $(h_token)"
  fi
}

h_create() {
  local code
  code=$(curl -sS -o "$H_STATE/last-response.json" -w '%{http_code}' -X "$1" "$H_URL$2" \
    -H "Authorization: Bearer $(h_token)" -H 'Content-Type: application/json' -d "$3")
  case "$code" in
    2*|409) return 0 ;;
    *) echo "HTTP $code from $1 $2: $(cat "$H_STATE/last-response.json")" >&2; return 1 ;;
  esac
}

h_wait() {
  local repo_enc=$1 pipe=$2 want=$3 sha=$4 ex num="" st="" deadline=$((SECONDS + 900))
  while :; do
    ex=$(h_api GET "/api/v1/repos/$repo_enc/pipelines/$pipe/executions?limit=25" \
      | jq -c --arg s "$sha" '[.[] | select(.after == $s)] | max_by(.number) // empty')
    if [ -n "$ex" ]; then
      num=$(jq -r .number <<<"$ex")
      st=$(jq -r .status <<<"$ex")
      case "$st" in success|failure|error|killed) break ;; esac
    fi
    if [ $SECONDS -gt $deadline ]; then
      echo "Timed out waiting for $pipe on ${sha:0:8} (last: #$num $st)" >&2
      return 1
    fi
    sleep 5
  done
  echo "Pipeline $pipe #$num finished with status: $st (commit ${sha:0:8})"
  [ "$st" = "$want" ]
}

h_open_and_merge_pr() {
  local repo_enc=$1 source_branch=$2 target_branch=$3 title=$4 check=$5
  local pr_num sha out deadline=$((SECONDS + 600))
  pr_num=$(h_api GET "/api/v1/repos/$repo_enc/pullreq?state=open&source_branch=$source_branch&target_branch=$target_branch" \
    | jq -r '.[0].number // empty')
  if [ -z "$pr_num" ]; then
    pr_num=$(h_api POST "/api/v1/repos/$repo_enc/pullreq" \
      "$(jq -n --arg s "$source_branch" --arg t "$target_branch" --arg title "$title" \
        '{source_branch:$s,target_branch:$t,title:$title}')" | jq -r .number)
  fi
  echo "Opened pull request #$pr_num ($source_branch -> $target_branch)"
  sha=$(h_api GET "/api/v1/repos/$repo_enc/pullreq/$pr_num" | jq -r .source_sha)
  h_wait "$repo_enc" "$check" "success" "$sha"

  while :; do
    sha=$(h_api GET "/api/v1/repos/$repo_enc/pullreq/$pr_num" | jq -r .source_sha)
    if out=$(h_api POST "/api/v1/repos/$repo_enc/pullreq/$pr_num/merge" \
        "{\"method\":\"squash\",\"source_sha\":\"$sha\",\"delete_source_branch\":true}" 2>&1); then
      echo "Merged pull request #$pr_num"
      break
    fi
    if [ $SECONDS -gt $deadline ]; then
      echo "Merge of PR #$pr_num failed: $out" >&2
      return 1
    fi
    sleep 5
  done
}

# Ensure Lab 02 is complete first
if ! h_api GET "/api/v1/repos/flightops%2Fflight-status/pipelines/ci" >/dev/null 2>&1; then
  echo "Lab 02 state not detected; running lab02-catch-up.sh first..."
  "$SCRIPT_DIR/lab02-catch-up.sh"
fi

echo "=== [Lab 03] Before you start: Ensuring VS Code insertFinalNewline setting ==="
mkdir -p ~/.config/Code/User
f=~/.config/Code/User/settings.json
[ -s "$f" ] || echo '{}' > "$f"
jq '. + {"files.insertFinalNewline": true}' "$f" > /tmp/settings.json && mv /tmp/settings.json "$f"

cd ~/flight-status
git switch main
git pull

echo "=== [Lab 03] Part 2: Updating .harness/ci.yaml with PostgreSQL background service & 90% coverage ==="
cat > ~/flight-status/.harness/ci.yaml <<'EOF'
# Continuous integration for flight-status (Lab 03).
# Adds a PostgreSQL service for the integration tests and a coverage threshold.
kind: pipeline
spec:
  stages:
  - name: build
    type: ci
    spec:
      steps:
      - name: db
        type: background
        spec:
          container: postgres:17-alpine
          envs:
            POSTGRES_USER: flights
            POSTGRES_PASSWORD: flights
            POSTGRES_DB: flights
      - name: install
        type: run
        spec:
          container: python:3.12-slim
          script: |
            python -m venv .venv
            . .venv/bin/activate
            pip install --quiet -r requirements-dev.txt
      - name: lint
        type: run
        spec:
          container: python:3.12-slim
          script: |
            . .venv/bin/activate
            ruff check .
            ruff format --check .
      - name: test
        type: run
        spec:
          container: python:3.12-slim
          envs:
            DATABASE_URL: postgresql://flights:flights@db:5432/flights
          script: |
            . .venv/bin/activate
            pytest --cov=flightstatus --cov-report=term-missing --cov-fail-under=90
EOF

# If main is not protected yet, push directly as in Lab 03 Part 2.2
if ! h_api GET "/api/v1/repos/flightops%2Fflight-status/rules" | jq -e '.[] | select(.identifier == "protect-main")' >/dev/null 2>&1; then
  git add .harness/ci.yaml
  if ! git diff --cached --quiet; then
    git commit -m "Run integration tests against PostgreSQL and require 90% coverage"
    git push
    h_wait "flightops%2Fflight-status" "ci" "success" "$(git rev-parse HEAD)"
  fi
fi

echo "=== [Lab 03] Part 3: Creating branch protection rule 'protect-main' ==="
h_create POST "/api/v1/repos/flightops%2Fflight-status/rules" '{
  "identifier":"protect-main",
  "type":"branch",
  "state":"active",
  "pattern":{"default":true},
  "definition":{
    "bypass":{"repo_owners":false},
    "lifecycle":{"delete_forbidden":true,"update_forbidden":true,"update_force_forbidden":true},
    "pullreq":{
      "status_checks":{"require_identifiers":["ci"]},
      "merge":{"strategies_allowed":["squash","merge"],"delete_branch":true}
    }
  }
}'

echo "=== [Lab 03] Part 4, 5 & 6: Adding departures board feature on branch 'feature/departures' ==="
git checkout -B feature/departures

cat > ~/flight-status/flightstatus/rules.py <<'EOF'
"""Business rules for flight status changes.

A flight moves through a fixed set of states. ALLOWED_TRANSITIONS lists every
permitted change. Any other change is rejected with InvalidTransition.
"""

from datetime import datetime, timedelta

from .models import Flight, FlightStatus, StatusUpdate

S = FlightStatus

ALLOWED_TRANSITIONS: dict[FlightStatus, set[FlightStatus]] = {
    S.SCHEDULED: {S.BOARDING, S.DELAYED, S.CANCELLED},
    S.DELAYED: {S.DELAYED, S.BOARDING, S.CANCELLED},
    S.BOARDING: {S.DEPARTED, S.DELAYED},
    S.DEPARTED: {S.ARRIVED},
    S.ARRIVED: set(),
    S.CANCELLED: set(),
}


# Statuses after which a flight no longer appears on a departures board.
FINISHED = {S.DEPARTED, S.ARRIVED, S.CANCELLED}


class InvalidTransition(ValueError):
    """Raised when a status change breaks the rules."""


def can_transition(current: FlightStatus, new: FlightStatus) -> bool:
    return new in ALLOWED_TRANSITIONS[current]


def apply_update(flight: Flight, update: StatusUpdate) -> Flight:
    """Return a copy of the flight with the update applied, or raise InvalidTransition."""
    if not can_transition(flight.status, update.status):
        raise InvalidTransition(f"cannot change status from {flight.status} to {update.status}")

    delay = flight.delay_minutes
    if update.status == S.DELAYED:
        if not update.delay_minutes:
            raise InvalidTransition("a DELAYED status needs delay_minutes greater than 0")
        delay = update.delay_minutes

    return flight.model_copy(update={"status": update.status, "delay_minutes": delay})


def estimated_departure(flight: Flight) -> datetime:
    """Scheduled departure plus the current delay."""
    return flight.departure + timedelta(minutes=flight.delay_minutes)


def departures_board(flights: list[Flight], airport: str) -> list[Flight]:
    """Flights still to leave an airport, ordered by estimated departure."""
    upcoming = [f for f in flights if f.origin == airport and f.status not in FINISHED]
    return sorted(upcoming, key=estimated_departure)
EOF

cat > ~/flight-status/flightstatus/main.py <<'EOF'
"""Flight status API.

Settings come from environment variables (twelve-factor style):
  DATABASE_URL  PostgreSQL connection URL. Without it, flights are kept in memory.
  APP_ENV       Environment name, for example dev or production.
  APP_VERSION   Version shown by /version and on the home page.
  GIT_COMMIT    Commit the image was built from.
  SEED_DATA     "true" (default) loads sample flights into an empty store.
"""

import html
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Response
from fastapi.responses import HTMLResponse

from .models import Flight, FlightStatus, StatusUpdate
from .rules import InvalidTransition, apply_update, departures_board, estimated_departure
from .seed import sample_flights
from .store import FlightExists, MemoryStore, PostgresStore, make_store


def create_app(store: MemoryStore | PostgresStore | None = None) -> FastAPI:
    app_env = os.environ.get("APP_ENV", "dev")
    version = os.environ.get("APP_VERSION", "dev")
    commit = os.environ.get("GIT_COMMIT", "unknown")
    seed = os.environ.get("SEED_DATA", "true").lower() == "true"

    if store is None:
        database_url = os.environ.get("DATABASE_URL")
        if app_env == "production" and not database_url:
            raise RuntimeError(
                "APP_ENV is production but DATABASE_URL is not set. "
                "Refusing to start with in-memory storage."
            )
        store = make_store(database_url)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        store.setup()
        if seed and not store.list():
            for flight in sample_flights():
                store.add(flight)
        yield

    app = FastAPI(title="Flight Status API", version=version, lifespan=lifespan)

    @app.get("/health")
    def health() -> dict:
        """Liveness: the process is running and can answer requests."""
        return {"status": "ok"}

    @app.get("/ready")
    def ready(response: Response) -> dict:
        """Readiness: the service can reach its storage."""
        if store.ping():
            return {"status": "ready", "storage": store.kind}
        response.status_code = 503
        return {"status": "not ready", "storage": store.kind}

    @app.get("/version")
    def get_version() -> dict:
        return {"version": version, "commit": commit, "environment": app_env}

    @app.get("/flights")
    def list_flights(origin: str | None = None, status: FlightStatus | None = None) -> list[Flight]:
        flights = store.list()
        if origin:
            flights = [f for f in flights if f.origin == origin.upper()]
        if status:
            flights = [f for f in flights if f.status == status]
        return flights

    @app.get("/flights/{number}")
    def get_flight(number: str) -> Flight:
        flight = store.get(number.upper())
        if flight is None:
            raise HTTPException(status_code=404, detail=f"flight {number} not found")
        return flight

    @app.post("/flights", status_code=201)
    def create_flight(flight: Flight) -> Flight:
        try:
            store.add(flight)
        except FlightExists as exc:
            raise HTTPException(
                status_code=409, detail=f"flight {flight.number} already exists"
            ) from exc
        return flight

    @app.patch("/flights/{number}/status")
    def update_status(number: str, update: StatusUpdate) -> Flight:
        flight = get_flight(number)
        try:
            updated = apply_update(flight, update)
        except InvalidTransition as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        store.save(updated)
        return updated

    @app.get("/airports/{code}/departures")
    def departures(code: str) -> list[Flight]:
        """Departures board for one airport."""
        return departures_board(store.list(), code.upper())

    @app.get("/", response_class=HTMLResponse)
    def home() -> str:
        rows = "".join(
            f"<tr><td>{html.escape(f.number)}</td><td>{f.origin}</td><td>{f.destination}</td>"
            f"<td>{estimated_departure(f):%H:%M} UTC</td><td>{html.escape(f.gate or '')}</td>"
            f"<td>{f.status}</td></tr>"
            for f in store.list()
        )
        return PAGE.format(version=html.escape(version), env=html.escape(app_env), rows=rows)

    return app


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Flight status</title>
<style>
body {{ font-family: system-ui, sans-serif; margin: 40px; color: #14263d; }}
table {{ border-collapse: collapse; min-width: 640px; }}
th, td {{ text-align: left; padding: 8px 16px 8px 0; border-bottom: 1px solid #e3e7ea; }}
.meta {{ color: #5c6b7b; }}
</style></head>
<body>
<h1>Flight status</h1>
<p class="meta">Version {version} &middot; environment {env}</p>
<table>
<tr><th>Flight</th><th>From</th><th>To</th><th>Departs</th><th>Gate</th><th>Status</th></tr>
{rows}
</table>
</body></html>
"""

app = create_app()
EOF

cat > ~/flight-status/tests/unit/test_departures.py <<'EOF'
"""Unit tests for the departures board."""

from datetime import UTC, datetime

from flightstatus.models import Flight
from flightstatus.models import FlightStatus as S
from flightstatus.rules import departures_board


def flight(number, hour, **changes) -> Flight:
    return Flight(
        number=number,
        origin=changes.pop("origin", "ORD"),
        destination="SFO",
        departure=datetime(2026, 10, 27, hour, 0, tzinfo=UTC),
        **changes,
    )


def test_only_flights_from_the_airport():
    board = departures_board([flight("UA1", 9), flight("UA2", 10, origin="DEN")], "ORD")
    assert [f.number for f in board] == ["UA1"]


def test_finished_flights_are_not_listed():
    flights = [
        flight("UA1", 9, status=S.DEPARTED),
        flight("UA2", 10, status=S.CANCELLED),
        flight("UA3", 11),
    ]
    assert [f.number for f in departures_board(flights, "ORD")] == ["UA3"]


def test_ordered_by_estimated_departure():
    # UA1 is scheduled first, but a 90-minute delay moves it behind UA2.
    flights = [flight("UA1", 9, status=S.DELAYED, delay_minutes=90), flight("UA2", 10)]
    assert [f.number for f in departures_board(flights, "ORD")] == ["UA2", "UA1"]
EOF

cat > ~/flight-status/tests/api/test_departures_api.py <<'EOF'
"""API tests for the departures board endpoint."""


def test_departures_for_ord(client):
    numbers = [f["number"] for f in client.get("/airports/ord/departures").json()]
    assert numbers == ["UA101", "UA202", "UA707"]


def test_delayed_flight_moves_down_the_board(client):
    client.patch("/flights/UA101/status", json={"status": "DELAYED", "delay_minutes": 60})
    numbers = [f["number"] for f in client.get("/airports/ORD/departures").json()]
    assert numbers == ["UA202", "UA101", "UA707"]


def test_departed_flight_leaves_the_board(client):
    client.patch("/flights/UA101/status", json={"status": "BOARDING"})
    client.patch("/flights/UA101/status", json={"status": "DEPARTED"})
    numbers = [f["number"] for f in client.get("/airports/ORD/departures").json()]
    assert "UA101" not in numbers
EOF

git add .
if ! git diff --cached --quiet; then
  git commit -m "Add a departures board for each airport"
  git push -u origin feature/departures
  h_open_and_merge_pr "flightops%2Fflight-status" "feature/departures" "main" "Add departures board" "ci"
  MAIN_SHA=$(h_api GET "/api/v1/repos/flightops%2Fflight-status/branches/main" | jq -r '.sha // .commit.sha')
  h_wait "flightops%2Fflight-status" "ci" "success" "$MAIN_SHA"
fi

git switch main
git pull
git branch -D feature/departures 2>/dev/null || true
git fetch --prune

echo "=== [Lab 03] Verifying Lab 03 state ==="
test -z "$(git status --porcelain)"
grep -q 'def departures_board' ~/flight-status/flightstatus/rules.py
echo "=== [Lab 03] Completed successfully! ==="
