## Weekly Station Alert Setup (macOS)

Script:
- `weekly_station_inventory_alert.R`

What it does weekly:
- Pulls current CaBi inventory
- Compares to `known_station_inventory.csv` by `station_id`
- Writes `outputs/new_stations_latest.csv`, `outputs/station_inventory_latest.csv`, and `outputs/station_inventory_unvisited_weekly.csv`
- Sends a weekly email summary every run with:
  - a "New stations" section
  - a "Remaining unvisited stations" section

### 1) Test manually

```bash
cd "/Users/scotthuddle/Documents/Bikeshare Pull"
Rscript weekly_station_inventory_alert.R
```

### 2) Shared jobs config (recommended)

Create one shared file used by multiple weekly jobs:

`~/.weekly_jobs_config`

Start from:

`weekly_jobs_config.example`

Then secure it:

```bash
chmod 600 ~/.weekly_jobs_config
```

Supported keys:
- `SMTP_HOST`
- `SMTP_PORT`
- `SMTP_USER`
- `SMTP_PASS` or `SMTP_APP_PASSWORD`
- `SMTP_USE_SSL`
- `EMAIL_FROM`
- `FROM_NAME_DEFAULT`
- `RECIPIENTS_DEFAULT`
- `RECIPIENTS_SHARED`
- `JOB_CABI_RECIPIENT_GROUP`
- `JOB_CABI_FROM_NAME`
- `JOB_CABI_SUBJECT_PREFIX`
- `CABI_ALERT_DRY_RUN` (optional)

### 3) launchd schedule (weekly example)

Copy `com.scotthuddle.cabi-weekly-alert.plist` to:

`~/Library/LaunchAgents/com.scotthuddle.cabi-weekly-alert.plist`

Load:

```bash
launchctl unload ~/Library/LaunchAgents/com.scotthuddle.cabi-weekly-alert.plist 2>/dev/null
launchctl load ~/Library/LaunchAgents/com.scotthuddle.cabi-weekly-alert.plist
launchctl start com.scotthuddle.cabi-weekly-alert
```

Logs:
- `/tmp/cabi_weekly_alert.out.log`
- `/tmp/cabi_weekly_alert.err.log`
