# Weather API

Rails API that accepts an international address and returns the current temperature
and a seven-day forecast in Celsius. Forecasts are cached by country and postal
code for 30 minutes, with an indicator showing whether the forecast came from cache.

Ruby 3.3.13 · Rails 8.1 · Redis 7

## Run locally

Requires Docker and Docker Compose v2:

```sh
docker compose up --build
```

The API runs at `http://localhost:3000`; `GET /up` is the health check.
Compose mounts the source at `/rails` and runs as UID/GID 1000, so files generated
in the container belong to the matching local user.

## API

```sh
curl --get 'http://localhost:3000/forecast' \
  --data-urlencode 'address=10 Downing Street, London SW1A 2AA, United Kingdom'
```

Example response with illustrative weather values:

```json
{
  "postal_code": "SW1A 2AA",
  "country": "United Kingdom",
  "country_code": "GB",
  "forecast": {
    "current_temperature": 12.5,
    "temperature_unit": "°C",
    "current_time": "2026-10-30T12:00:00Z",
    "timezone": "Europe/London",
    "utc_offset_seconds": 0,
    "daily": [
      { "date": "2026-10-30", "temperature_min": 8.0, "temperature_max": 15.0 },
      { "date": "2026-10-31", "temperature_min": 9.0, "temperature_max": 16.0 },
      { "date": "2026-11-01", "temperature_min": 7.0, "temperature_max": 14.0 },
      { "date": "2026-11-02", "temperature_min": 8.0, "temperature_max": 15.0 },
      { "date": "2026-11-03", "temperature_min": 6.0, "temperature_max": 13.0 },
      { "date": "2026-11-04", "temperature_min": 7.0, "temperature_max": 14.0 },
      { "date": "2026-11-05", "temperature_min": 8.0, "temperature_max": 15.0 }
    ]
  },
  "cached": false
}
```

`cached` refers to the forecast. Subsequent requests for the same country and
postal code return `true` while the entry remains cached. Responses use
`Cache-Control: no-store` so HTTP caches do not reuse an outdated cache indicator.

`address` must be a nonblank string of at most 500 characters. Include street
number, city and country. Multiple location matches return `422 ambiguous_address`
and require more details; the API never silently chooses the first candidate.

Errors use this format:

```json
{"error":{"code":"ambiguous_address","message":"Address is ambiguous; include street number, city, region and country"}}
```

| HTTP status | Error codes |
| --- | --- |
| 422 | `invalid_address`, `address_not_found`, `ambiguous_address`, `invalid_coordinates` |
| 502 | `invalid_response` |
| 503 | `upstream_rate_limited`, `upstream_unavailable` |
| 504 | `upstream_timeout` |

## Architecture and trade-offs

| Component | Responsibility |
| --- | --- |
| `ForecastsController` | Receive parameters and return JSON with the appropriate HTTP status |
| `Locations::Client` | Resolve the address through Geocoder and Photon; validate postal code, country and coordinates |
| `Weather::Client` | Query Open-Meteo through its Ruby SDK and validate the forecast |
| `Forecasts::Fetch` | Coordinate location lookup, forecast retrieval and caching |

Location requests use `Net::HTTP`. The weather SDK uses Faraday with a `Net::HTTP`
transport. Both clients set a 2-second connection timeout and 3-second read/write
timeouts, disable automatic retries, and translate provider errors into their own
exceptions. These timeouts apply to individual operations, not the whole request.
Malformed or incomplete responses are rejected, and raw provider error bodies
are not exposed to callers.

The real address used above was validated against Photon; the response includes
postal code `SW1A 2AA`, country code `GB`, latitude `51.5034878` and longitude
`-0.1276965`. Captured provider responses are stored under `spec/fixtures/`.
International search does not guarantee that every address has postal data.

Photon's public server is intended for moderate traffic. Higher-volume deployments
need provider capacity and quotas suited to their load, potentially through a
hosted or self-managed Photon instance. See the [Photon usage terms](https://github.com/komoot/photon#demo-server)
and [Open-Meteo documentation](https://open-meteo.com/en/docs).
Location data: [© OpenStreetMap contributors](https://www.openstreetmap.org/copyright).

### Cache, eviction and concurrency

Development and production use `Rails.cache` with Redis. All application instances
must share `REDIS_URL` to share entries; transient data is not stored in database
tables. Both location and forecast entries expire 30 minutes after being written.
Reads do not extend that lifetime, and only successful results are cached.

| Entry | Key within the environment namespace |
| --- | --- |
| Location | `locations/v1/<SHA-256 of normalized address>` |
| Forecast | `forecasts/v1/<country code>/<normalized postal code>` |

Address keys ignore case and repeated whitespace. Postal codes remain strings,
with spaces and hyphens removed and letters uppercased; the country prevents
collisions between countries. The first resolved address supplies the coordinates
for that postal area's cached forecast. A different address in the same postal
area still needs geocoding unless its location is already cached.

Compose configures Redis with a 128 MB data memory limit, `allkeys-lfu` eviction
and persistence disabled. Entries can be evicted before their TTL under memory
pressure. Redis connection/read/write timeouts and pool checkout timeout are
200 ms; the per-process pool follows `RAILS_MAX_THREADS` (default 3).
Connection failures are treated as cache misses and failed writes are ignored,
allowing fresh forecasts when providers remain available. Provider traffic
increases during a cache outage.

Concurrent requests for an uncached or expired key can repeat provider calls:
`Rails.cache.fetch` does not provide a distributed lock. The application uses
strict expiration and does not serve stale forecasts. Under heavier load,
measure cache hit rates, evictions, provider latency and rate limits before
sizing web concurrency or introducing locks to coordinate cache fills.

## Tests and CI

```sh
docker compose exec -e CI=true web bundle exec rspec
docker compose exec web bin/rubocop
docker compose exec web bin/brakeman --no-pager
```

Tests use WebMock and fixtures with real HTTP requests disabled. They cover
successful forecasts, ambiguous and invalid addresses, malformed responses,
timeouts, provider errors, timezone transitions, cache expiration and cache-hit
indicators. Cache tests use Rails memory stores and require no running Redis.

SimpleCov generates `coverage/index.html` and `coverage/coverage.json` for all
Ruby files in `app/` and `lib/`, including unloaded files. With `CI=true`, coverage
below **95% of lines** or **90% of branches** fails the run. Omit `-e CI=true` for
local runs of individual specs without enforcing the overall coverage thresholds.
Reports reflect only the current run and are ignored by Git.

GitHub Actions runs RSpec, RuboCop and Brakeman on pull requests and pushes to
`main` or `develop`. The generated report is available as the `coverage-report`
artifact for 14 days, including failed runs when a report exists.

## Production image

```sh
docker build -t weather-api .
docker run --rm -p 3001:3000 \
  --env SECRET_KEY_BASE --env REDIS_URL weather-api
```

Export `SECRET_KEY_BASE` and a `REDIS_URL` reachable from the container before
starting it. Supply `RAILS_MASTER_KEY` at runtime if using encrypted credentials.
The final image runs as UID/GID 1000, excludes the `development:test` gem groups,
and listens on port 3000; the example publishes it on host port 3001.

Production enforces HTTPS and expects a reverse proxy that terminates TLS and
sets `X-Forwarded-Proto: https`. For a local health check:

```sh
curl --fail --header 'X-Forwarded-Proto: https' http://localhost:3001/up
```

Optional provider overrides: `LOCATIONS_URL` accepts a Photon endpoint URL;
`WEATHER_HOST` accepts an Open-Meteo hostname without a scheme or path.
