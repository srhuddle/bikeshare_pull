# CHANGELOG

## 2026-04-11

### Added
- `data/fairfax_i66_proposed_stations_2026_04.csv` for the Fairfax April 2026 I-66 corridor proposal overlay.
- `data/fairfax_older_unbuilt_proposals_2026_04.csv` for older Fairfax proposal areas that are not yet built.
- `references/fairfax_bikeshare_proposals.md` documenting source lineage and ingestion notes for both proposal datasets.

### Changed
- `cabi_visit_map_app.R` now supports separate overlays for:
  - Fairfax I-66 proposal stations
  - older Fairfax proposals not yet built
- `README.md` and `CURRENT_STATUS.md` now point to the stored Fairfax proposal datasets and reference document.

## 2026-03-01

### Added
- `README.md` with end-to-end runbook for scraping, matching, map app usage, and weekly automation.
- `CHANGELOG.md` (this file).
- `weekly_station_inventory_alert.R` for weekly GBFS inventory pull and new-station alerting.
- `weekly_jobs_config.example` to standardize shared SMTP + recipient group config across jobs.
- `build_visited_station_list.R` and `match_visited_to_station_inventory.R` for post-scrape visited station processing.

### Changed
- `cabi_visit_map_app.R` now prefers `station_inventory_scoring.csv` as editable source and overlays `visited_by_history` from `station_inventory_with_history_match.csv` when available.
- `pull_cabi_history_playwright.R` updated for checkpointed chunk extraction and consolidated output writes.
- `com.scotthuddle.cabi-weekly-alert.plist` now points to shared config path (`~/.weekly_jobs_config`) instead of embedding SMTP/recipient secrets.

### Data/Workflow
- Consolidated and deduplicated ride-history data into `cabi_ride_history_all.csv`.
- Rebuilt visited-name and inventory match outputs from merged history.
- Archived legacy scripts/chunks/backups into `Archive/`.

### Notes
- Shared config model now supports recipient groups (`default`, `shared`) and per-job profile keys (e.g., `JOB_CABI_*`, `JOB_MOVIEPULL_*`).
