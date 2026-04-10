# Operations Runbook

This file tracks recurring operational workflows for the Capital Bikeshare analysis project so setup and maintenance do not live only in chat history.

## Interaction Rule

For operational setup or maintenance tasks, proceed one step at a time and wait for explicit confirmation before moving to the next step.

## Docker / OSRM Setup

Goal:
- run a local OSRM server for routed bike-time planning

Current status:
- Docker Desktop installed
- `docker --version` verified successfully on 2026-04-07

Repo scripts:
- [scripts/setup_osrm_server.sh](/Users/scotthuddle/Documents/Bikeshare%20Pull/scripts/setup_osrm_server.sh)
- [scripts/start_osrm_server.sh](/Users/scotthuddle/Documents/Bikeshare%20Pull/scripts/start_osrm_server.sh)
- [scripts/stop_osrm_server.sh](/Users/scotthuddle/Documents/Bikeshare%20Pull/scripts/stop_osrm_server.sh)

Planned one-time setup flow:
1. Install Docker Desktop.
2. Download a DC metro-area `.osm.pbf` extract from BBBike.
3. Preprocess the extract with `./scripts/setup_osrm_server.sh /absolute/path/to/file.osm.pbf`.
4. Start the OSRM server with `./scripts/start_osrm_server.sh dc-metro-region`.
5. Verify the server responds on `http://localhost:5000`.
6. Run the planner with `ROUTE_PLAN_COST_MODEL=osrm`.

Planner example:

```bash
cd "/Users/scotthuddle/Documents/Bikeshare Pull"
ROUTE_PLAN_COST_MODEL=osrm \
ROUTE_PLAN_OSRM_URL=http://localhost:5000 \
ROUTE_PLAN_OSRM_PROFILE=cycling \
ROUTE_PLAN_METRO_FILE=/Users/scotthuddle/Downloads/Metro_Stations_\(Regional\).csv \
ROUTE_PLAN_TARGET_STATIONS_PER_DAY=30 \
ROUTE_PLAN_MAX_TOTAL_DAY_MINUTES=300 \
ROUTE_PLAN_WRITE_MAPS=false \
Rscript cabi_route_planner.R
```

## Route Planner Notes

Important environment variables:
- `ROUTE_PLAN_COST_MODEL` = `haversine` or `osrm`
- `ROUTE_PLAN_OSRM_URL` = local OSRM server base URL
- `ROUTE_PLAN_OSRM_PROFILE` = usually `cycling`
- `ROUTE_PLAN_TARGET_STATIONS_PER_DAY`
- `ROUTE_PLAN_MAX_TOTAL_DAY_MINUTES`
- `ROUTE_PLAN_METRO_FILE`

Key outputs:
- `outputs/route_plan/station_route_plan.csv`
- `outputs/route_plan/day_route_summary.csv`
- `outputs/route_plan/total_route_summary.csv`
- `outputs/route_plan/weak_transit_exits.csv`

## To Extend Later

Useful future sections:
- refreshing CaBi station inventory
- rerunning visited-station matching
- Shiny app usage and common issues
- OSRM extract refresh procedure
- route-planner tuning recipes

## Moving To Another Machine

Goal:
- reopen the same project from a shared drive and restore routed planning with minimal setup

Required on the new machine:
- Docker Desktop
- R
- R packages used by the repo:
  - `dplyr`
  - `readr`
  - `shiny`
  - `leaflet`
  - `htmlwidgets`
  - optional: `jsonlite`

Best case:
- the shared drive already contains:
  - `data/osrm/dc-metro-region.osm.pbf`
  - the processed `data/osrm/*.osrm*` files
  - `data/metro_stations_regional.csv`
  - current `outputs/route_plan/` outputs

If the processed OSRM files are already present:
1. Install Docker Desktop.
2. Start Docker Desktop once.
3. Start the routing server:

```bash
cd "/path/to/Bikeshare Pull"
OSRM_PORT=5001 ./scripts/start_osrm_server.sh dc-metro-region
```

4. Verify the server:

```bash
curl "http://localhost:5001/nearest/v1/cycling/-77.0434,38.9096"
```

5. Run the planner:

```bash
ROUTE_PLAN_COST_MODEL=osrm \
ROUTE_PLAN_OSRM_URL=http://localhost:5001 \
ROUTE_PLAN_OSRM_PROFILE=cycling \
ROUTE_PLAN_METRO_FILE=data/metro_stations_regional.csv \
ROUTE_PLAN_TARGET_STATIONS_PER_DAY=30 \
ROUTE_PLAN_MAX_TOTAL_DAY_MINUTES=300 \
ROUTE_PLAN_WRITE_MAPS=false \
Rscript cabi_route_planner.R
```

If the processed OSRM files are missing:
1. Confirm `data/osrm/dc-metro-region.osm.pbf` exists.
2. Rebuild:

```bash
./scripts/setup_osrm_server.sh "/path/to/dc-metro-region.osm.pbf"
```

3. Then start the server as above.

Notes:
- Port `5000` may already be in use on another machine. If so, use `OSRM_PORT=5001` or another free port.
- The project now includes a local Metro station file at `data/metro_stations_regional.csv`.
