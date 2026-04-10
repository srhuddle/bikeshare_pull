# Capital Bikeshare Visit Tracker

This project tracks Capital Bikeshare stations you have visited, visualizes visited/unvisited stations on a map, and supports weekly automated checks for newly added stations.

The current setup is designed so you can:
- keep a manually editable map workflow for final cleanup/toggles,
- preserve full scraped ride-history data for future analysis,
- automatically detect and notify on newly added stations weekly.

## What Is In Scope

Primary goals implemented:
- Consolidated ride-history dataset (`cabi_ride_history_all.csv`).
- Unique visited station names derived from ride history.
- Match visited names to current station inventory.
- Shiny app for map-based visited/unvisited visualization and manual toggling.
- Weekly station inventory check + email alert for **new station IDs**.
- Weekly email summary with **new stations** and **remaining unvisited stations**.
- Shared multi-job email configuration with recipient groups.

## Core Files (Active)

- `cabi_visit_map_app.R`
  - Interactive map app for visited/unvisited toggling.
  - Uses `station_inventory_scoring.csv` as primary editable file.
  - Overlays `visited_by_history` from `outputs/station_inventory_with_history_match.csv` if present.
  - Can overlay a suggested route by selected day when route-planner outputs exist under `outputs/route_plan/`.

- `pull_cabi_history_playwright.R`
  - Playwright-based scraper for ride-history extraction (checkpointed).
  - Appends to `cabi_ride_history_all.csv`.
  - Resumes via `cabi_ride_history_checkpoint.txt`.

- `build_visited_station_list.R`
  - Builds:
    - `outputs/visited_station_names_unique.csv`
    - `outputs/visited_station_names_summary.csv`
  - Uses `cabi_ride_history_all.csv`.

- `match_visited_to_station_inventory.R`
  - Matches visited station names to current inventory.
  - Produces:
    - `outputs/station_inventory_with_history_match.csv`
    - `outputs/station_inventory_unvisited_by_history.csv`
    - `outputs/visited_names_not_in_current_inventory.csv`

- `weekly_station_inventory_alert.R`
  - Weekly automated station inventory pull from GBFS.
  - Detects **new station IDs** vs `known_station_inventory.csv`.
  - Writes:
    - `outputs/station_inventory_latest.csv`
    - `outputs/new_stations_latest.csv`
    - `outputs/station_inventory_unvisited_weekly.csv`
  - Sends a weekly email summary every run with new-station and remaining-unvisited sections.

- `cabi_route_planner.R`
  - Initial station-completion route planner.
  - Builds day-sized geographic clusters, solves each day as an open route, and optionally scores endpoints by Metro proximity.
  - Writes route outputs under `outputs/route_plan/`.

- `scripts/build_ors_full_schedule.py`
  - Builds the ORS-backed candidate day schedule while preserving existing day membership/start-end anchors.

- `scripts/export_route_plan_ors_tcx.py`
  - Canonical Ride with GPS export path.
  - Writes one `TCX` per day under `outputs/route_plan_ors_tcx/`.
  - Includes turn-by-turn course points and `CaBi station: ...` station cues.

- `weekly_jobs_config.example`
  - Template for shared config at `~/.weekly_jobs_config`.

- `com.scotthuddle.cabi-weekly-alert.plist`
  - launchd job definition for weekly CaBi alert.

## Data Files You Should Keep

- `station_inventory_scoring.csv` (app’s working file)
- `cabi_ride_history_all.csv` (consolidated ride history)
- `cabi_ride_history_all-JS.csv` (optional preserved JS export)
- `known_station_inventory.csv` (weekly baseline for new-station detection)
- `cabi_ride_history_checkpoint.txt` (resume state for Playwright scraper)

Generated analysis outputs are written under `outputs/`.

## Directory Cleanup Policy

Legacy/debug/experimental scripts and old backups are moved into `Archive/`:
- `Archive/legacy_scripts/`
- `Archive/legacy_chunks/`
- `Archive/backups/`

Treat `Archive/` as historical context only, not active runtime dependencies.

## Shared Config Model (Important)

Both CaBi and MoviePull now support a shared config:
- `~/.weekly_jobs_config`

Config priorities:
1. `WEEKLY_JOBS_CONFIG_PATH` (if set)
2. `~/.weekly_jobs_config`
3. Legacy fallbacks (`~/.weekly_email_config`, local `.email_config`) where supported

### Recipient Groups / Job Profiles

Use recipient groups instead of per-script email vars:
- `RECIPIENTS_DEFAULT` (typically you)
- `RECIPIENTS_SHARED` (you + partner)

Job mappings:
- `JOB_CABI_RECIPIENT_GROUP=default`
- `JOB_MOVIEPULL_RECIPIENT_GROUP=shared`

This avoids adding `EMAIL_TO_<SCRIPT>` for every future job.

Planned improvement:
- Move CaBi and MoviePull to a single shared Python email helper (JSON payload in, SMTP out) so both jobs use one identical sender path.

## Quick Start Commands

### 1) Rebuild visited + matching outputs

```bash
cd "/Users/scotthuddle/Documents/Bikeshare Pull"
Rscript build_visited_station_list.R
Rscript match_visited_to_station_inventory.R
```

### 2) Run map app

```r
library(shiny)
runApp("cabi_visit_map_app.R")
```

### 3) Run weekly station alert (dry run)

```bash
cd "/Users/scotthuddle/Documents/Bikeshare Pull"
CABI_ALERT_DRY_RUN=true Rscript weekly_station_inventory_alert.R
```

### 4) Run weekly station alert (normal)

```bash
cd "/Users/scotthuddle/Documents/Bikeshare Pull"
Rscript weekly_station_inventory_alert.R
```

### 5) Build a route plan

Default behavior uses `station_inventory_scoring.csv`, plans all stations, targets 25 stations/day, uses haversine distances, and writes per-day HTML maps if `leaflet` and `htmlwidgets` are installed:

```bash
cd "/Users/scotthuddle/Documents/Bikeshare Pull"
Rscript cabi_route_planner.R
```

Common route-planning options:

```bash
ROUTE_PLAN_HOME_LAT=38.9 \
ROUTE_PLAN_HOME_LON=-77.03 \
ROUTE_PLAN_TARGET_STATIONS_PER_DAY=35 \
ROUTE_PLAN_UNVISITED_ONLY=true \
ROUTE_PLAN_WRITE_MAPS=false \
Rscript cabi_route_planner.R
```

Metro endpoint scoring is enabled when one of these is available:

```bash
# CSV with metro_name/name/station_name plus lat/lon columns
ROUTE_PLAN_METRO_FILE=data/metro_stations.csv Rscript cabi_route_planner.R

# Or WMATA Rail Station Information API
WMATA_API_KEY=your_key_here Rscript cabi_route_planner.R
```

Route planner outputs:
- `outputs/route_plan/station_route_plan.csv`
- `outputs/route_plan/day_route_summary.csv`
- `outputs/route_plan/total_route_summary.csv`
- `outputs/route_plan/weak_transit_exits.csv`
- `outputs/route_plan/day_XX_map.html` when map output is enabled

### 6) Build the ORS candidate schedule

```bash
cd "/Users/scotthuddle/Documents/Bikeshare Pull"
python3 scripts/build_ors_full_schedule.py
```

ORS candidate outputs:
- `outputs/route_plan_ors/station_route_plan.csv`
- `outputs/route_plan_ors/day_route_summary.csv`
- `outputs/route_plan_ors/total_route_summary.csv`
- `outputs/route_plan_ors/baseline_comparison.csv`

### 7) Export Ride with GPS uploads

Canonical upload format is `TCX` only.

```bash
cd "/Users/scotthuddle/Documents/Bikeshare Pull"
python3 scripts/export_route_plan_ors_tcx.py
```

TCX upload outputs:
- `outputs/route_plan_ors_tcx/day_XX_*.tcx`
- `outputs/route_plan_ors_tcx/manifest.json`

Important:
- `TCX` is the only supported upload/export format for Ride with GPS in this repo now.
- `GPX` is no longer part of the active workflow because it does not carry the cue information needed for turn-by-turn.

When a plan is worth preserving as a benchmark, copy those files into a dated snapshot folder such as:
- `outputs/route_plan_current_best_YYYY-MM-DD/`

Current preserved baseline:
- `outputs/route_plan_current_best_2026-04-08/`

### OSRM Bike-Time Routing

The planner can use OSRM bike routing inside each day-cluster and for home-to-start / end-to-home access estimates. This is useful when you want day plans capped by estimated total time rather than just straight-line mileage.

Project helper scripts:
- `scripts/setup_osrm_server.sh`
- `scripts/start_osrm_server.sh`
- `scripts/stop_osrm_server.sh`

Recommended local setup:

1. Install Docker Desktop.
2. Download a DC metro-area `.osm.pbf` extract.
3. Preprocess the extract:

```bash
cd "/Users/scotthuddle/Documents/Bikeshare Pull"
./scripts/setup_osrm_server.sh /absolute/path/to/dc-metro-region.osm.pbf
```

4. Start the server:

```bash
cd "/Users/scotthuddle/Documents/Bikeshare Pull"
./scripts/start_osrm_server.sh dc-metro-region
```

5. Confirm it responds:

```bash
curl "http://localhost:5000/nearest/v1/cycling/-77.0434,38.9096"
```

6. Run the planner against OSRM:

Example:

```bash
ROUTE_PLAN_COST_MODEL=osrm \
ROUTE_PLAN_OSRM_URL=http://localhost:5000 \
ROUTE_PLAN_OSRM_PROFILE=cycling \
ROUTE_PLAN_TARGET_STATIONS_PER_DAY=30 \
ROUTE_PLAN_MAX_TOTAL_DAY_MINUTES=300 \
ROUTE_PLAN_WRITE_MAPS=false \
Rscript cabi_route_planner.R
```

Notes:
- `ROUTE_PLAN_OSRM_URL` should point to an OSRM server that supports the `/table` service.
- The helper scripts expect Docker image `osrm/osrm-backend` and default to the bicycle profile at `/opt/bicycle.lua`.
- If `ROUTE_PLAN_COST_MODEL=osrm` is set but `ROUTE_PLAN_OSRM_URL` is missing or the OSRM request fails, the planner falls back to haversine.
- Clustering still starts from approximate geography; OSRM is used for within-day route scoring and total-day time estimates.
- `day_route_summary.csv` includes `estimated_total_day_minutes` and `route_cost_model` so the app can show whether a day is being scored with routed bike time or fallback geometry.

## launchd Notes

Installed job label:
- `com.scotthuddle.cabi-weekly-alert`

Typical commands:

```bash
launchctl unload ~/Library/LaunchAgents/com.scotthuddle.cabi-weekly-alert.plist 2>/dev/null
launchctl load ~/Library/LaunchAgents/com.scotthuddle.cabi-weekly-alert.plist
launchctl start com.scotthuddle.cabi-weekly-alert
```

Logs:
- `/tmp/cabi_weekly_alert.out.log`
- `/tmp/cabi_weekly_alert.err.log`

## Updating / Editing Guidance

### Change recipients

Edit `~/.weekly_jobs_config` only:
- `RECIPIENTS_DEFAULT`
- `RECIPIENTS_SHARED`
- `JOB_*_RECIPIENT_GROUP`

No plist edits needed for recipient changes.

### Add a new weekly script in the future

1. Add new job profile keys to `~/.weekly_jobs_config`, e.g.:
   - `JOB_NEWJOB_RECIPIENT_GROUP=default`
   - `JOB_NEWJOB_FROM_NAME="New Job"`
2. In the script, resolve SMTP + recipient group from shared config.
3. Add a launchd plist that only executes the script (no SMTP secrets inline).

### Change CaBi schedule

Edit `com.scotthuddle.cabi-weekly-alert.plist`:
- `StartCalendarInterval` weekday/hour/minute
Then unload/load launch agent.

## Known Caveats

- Ride-history station data is name-based (no station IDs in scraped payload), so matching can have edge cases with renames and non-station drop-off addresses.
- “Drop anywhere” e-bike addresses appear in `outputs/visited_names_not_in_current_inventory.csv` and should not be treated as current stations.
- Playwright sync API in RStudio may require a fresh R session if reused in the same console (`asyncio loop` error).
- Very deep ride-history runs can stress browser memory; checkpointing is used to resume safely.

## Suggested Maintenance Routine

Weekly:
1. Let launchd run `weekly_station_inventory_alert.R`.
2. If new stations are reported, open app and review.

Periodic:
1. Refresh ride history with `pull_cabi_history_playwright.R`.
2. Rebuild visited + matching outputs.
3. Use app for manual cleanup and confirmation.
