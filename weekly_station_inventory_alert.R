#!/usr/bin/env Rscript

# Weekly Capital Bikeshare station inventory check:
# - Pull current station list from GBFS
# - Compare to known station inventory by station_id
# - Update known inventory history
# - Email weekly summary (includes no-new-stations weeks)
#
# Email config:
# - Preferred shared file: ~/.weekly_jobs_config
#   (override path with WEEKLY_JOBS_CONFIG_PATH)
# - Backward-compatible fallback: ~/.weekly_email_config, then ./.email_config
#
# Supported keys in config/env:
#   SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS or SMTP_APP_PASSWORD
#   SMTP_USE_SSL (true/false)
#   EMAIL_FROM (optional; default SMTP_USER)
#   FROM_NAME_DEFAULT (optional)
#   RECIPIENTS_DEFAULT (optional; comma-separated)
#   RECIPIENTS_SHARED  (optional; comma-separated)
#   JOB_CABI_RECIPIENT_GROUP (default/default|shared)
#   JOB_CABI_FROM_NAME
#   JOB_CABI_SUBJECT_PREFIX
#
# Optional run flags:
#   CABI_ALERT_DRY_RUN=true   # never send email, just log
#   CABI_NOTIFY_ON_NO_NEW=true  # default true; send "no new stations" summary

need_pkg <- function(pkg) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    stop("Missing package: ", pkg, ". Install with install.packages('", pkg, "')", call. = FALSE)
  }
}

need_pkg("jsonlite")
need_pkg("dplyr")
need_pkg("readr")

library(jsonlite)
library(dplyr)
library(readr)

info_url <- "https://gbfs.capitalbikeshare.com/gbfs/en/station_information.json"
known_file <- "known_station_inventory.csv"
output_dir <- "outputs"
scoring_file <- "station_inventory_scoring.csv"
visited_file <- file.path(output_dir, "visited_station_names_unique.csv")
snapshot_file <- file.path(output_dir, "station_inventory_latest.csv")
new_file <- file.path(output_dir, "new_stations_latest.csv")
dropped_file <- file.path(output_dir, "dropped_stations_latest.csv")
unvisited_file <- file.path(output_dir, "station_inventory_unvisited_weekly.csv")

today <- as.Date(Sys.time())

normalize_id <- function(x) trimws(as.character(x))
to_bool <- function(x) tolower(trimws(as.character(x))) %in% c("true", "t", "1", "yes", "y")

normalize_name <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  x <- gsub("\u00A0", " ", x, fixed = TRUE)
  x <- tolower(x)
  x <- gsub("&", " and ", x, fixed = TRUE)
  x <- gsub("[^a-z0-9]+", " ", x)
  trimws(gsub("\\s+", " ", x))
}

build_section <- function(title, lines) {
  paste(c(title, lines), collapse = "\n")
}

compute_remaining_unvisited <- function(current) {
  if (!file.exists(scoring_file)) {
    message("Unvisited section unavailable. Missing scoring file: ", scoring_file)
    return(NULL)
  }

  scoring <- read_csv(scoring_file, show_col_types = FALSE) %>%
    mutate(station_id = normalize_id(station_id))

  manual_visited <- rep(FALSE, nrow(scoring))
  if ("visited" %in% names(scoring)) {
    manual_visited <- to_bool(scoring$visited)
  }
  scoring$manual_visited <- manual_visited

  visited_norm <- character()
  if (file.exists(visited_file)) {
    visited_names <- read_csv(visited_file, show_col_types = FALSE)
    if ("station_name" %in% names(visited_names)) {
      visited_norm <- unique(normalize_name(visited_names$station_name))
      visited_norm <- visited_norm[visited_norm != ""]
    } else {
      message("Unvisited history match skipped. Missing station_name column in: ", visited_file)
    }
  } else {
    message("Visited-name file not found; using manual visited flags only for unvisited section.")
  }

  current_eval <- current %>%
    mutate(station_name_norm = normalize_name(station_name)) %>%
    left_join(scoring %>% select(station_id, manual_visited), by = "station_id") %>%
    mutate(
      manual_visited = coalesce(manual_visited, FALSE),
      visited_by_history = station_name_norm %in% visited_norm,
      visited_effective = manual_visited | visited_by_history
    )

  unvisited <- current_eval %>%
    filter(!visited_effective) %>%
    select(station_id, station_name, lat, lon) %>%
    arrange(station_name)

  write_csv(unvisited, unvisited_file)
  unvisited
}

load_email_config <- function() {
  cfg_path <- Sys.getenv("WEEKLY_JOBS_CONFIG_PATH", unset = path.expand("~/.weekly_jobs_config"))
  old_shared <- path.expand("~/.weekly_email_config")
  local_fallback <- file.path(getwd(), ".email_config")

  if (file.exists(cfg_path)) {
    readRenviron(cfg_path)
    message("Loaded config: ", cfg_path)
    return(invisible(TRUE))
  }
  if (file.exists(old_shared)) {
    readRenviron(old_shared)
    message("Loaded legacy shared email config: ", old_shared)
    return(invisible(TRUE))
  }
  if (file.exists(local_fallback)) {
    readRenviron(local_fallback)
    message("Loaded local fallback config: ", local_fallback)
    return(invisible(TRUE))
  }
  invisible(FALSE)
}

send_email_if_configured <- function(new_stations, dropped_stations, remaining_unvisited, subject_date, current_station_count = NA_integer_) {
  dry_run <- to_bool(Sys.getenv("CABI_ALERT_DRY_RUN", unset = "false"))
  if (dry_run) {
    message("Dry run enabled; skipping email send.")
    return(invisible(FALSE))
  }

  job_group <- Sys.getenv("JOB_CABI_RECIPIENT_GROUP", unset = "default")
  group_key <- paste0("RECIPIENTS_", toupper(gsub("[^A-Za-z0-9]+", "_", job_group)))
  to <- Sys.getenv(group_key, unset = Sys.getenv("RECIPIENTS_DEFAULT", unset = Sys.getenv("EMAIL_TO", unset = Sys.getenv("CABI_ALERT_TO", unset = ""))))
  host <- Sys.getenv("SMTP_HOST", unset = Sys.getenv("CABI_SMTP_HOST", unset = ""))
  port <- suppressWarnings(as.integer(Sys.getenv("SMTP_PORT", unset = Sys.getenv("CABI_SMTP_PORT", unset = "587"))))
  user <- Sys.getenv("SMTP_USER", unset = Sys.getenv("CABI_SMTP_USER", unset = ""))
  pass <- Sys.getenv("SMTP_PASS", unset = Sys.getenv("SMTP_APP_PASSWORD", unset = Sys.getenv("CABI_SMTP_PASS", unset = "")))
  use_ssl <- to_bool(Sys.getenv("SMTP_USE_SSL", unset = Sys.getenv("CABI_SMTP_USE_SSL", unset = "false")))
  from_addr <- Sys.getenv("EMAIL_FROM", unset = Sys.getenv("CABI_ALERT_FROM", unset = user))
  from_name <- Sys.getenv("JOB_CABI_FROM_NAME", unset = Sys.getenv("FROM_NAME_DEFAULT", unset = Sys.getenv("EMAIL_FROM_NAME", unset = "CaBi Alert")))
  from <- if (from_name != "" && from_addr != "") paste0(from_name, " <", from_addr, ">") else from_addr
  subject_prefix <- Sys.getenv("JOB_CABI_SUBJECT_PREFIX", unset = "Capital Bikeshare")

  required_missing <- c(
    if (to == "") "RECIPIENTS_DEFAULT/RECIPIENTS_<GROUP>",
    if (from_addr == "") "EMAIL_FROM or SMTP_USER",
    if (host == "") "SMTP_HOST"
  )
  if (length(required_missing) > 0) {
    message("Email not sent. Missing env vars: ", paste(required_missing, collapse = ", "))
    return(invisible(FALSE))
  }

  new_section <- if (nrow(new_stations) > 0) {
    build_section(
      "New stations",
      c(
        paste0("Count: ", nrow(new_stations)),
        paste0("- ", new_stations$station_name, " (", new_stations$station_id, ")"),
        paste0("CSV in project folder: ", new_file)
      )
    )
  } else {
    build_section(
      "New stations",
      c(
        "Count: 0",
        "No new bike stations this week.",
        paste0("CSV in project folder: ", new_file)
      )
    )
  }

  dropped_section <- if (nrow(dropped_stations) > 0) {
    build_section(
      "Dropped stations",
      c(
        paste0("Count: ", nrow(dropped_stations)),
        paste0("- ", dropped_stations$station_name, " (", dropped_stations$station_id, ")"),
        paste0("CSV in project folder: ", dropped_file)
      )
    )
  } else {
    build_section(
      "Dropped stations",
      c(
        "Count: 0",
        "No stations dropped from the live inventory this week.",
        paste0("CSV in project folder: ", dropped_file)
      )
    )
  }

  unvisited_section <- if (is.null(remaining_unvisited)) {
    build_section(
      "Remaining unvisited stations",
      c(
        "Unavailable for this run.",
        "Check local inputs used for matching."
      )
    )
  } else if (nrow(remaining_unvisited) > 0) {
    build_section(
      "Remaining unvisited stations",
      c(
        paste0("Count: ", nrow(remaining_unvisited)),
        paste0("- ", remaining_unvisited$station_name, " (", remaining_unvisited$station_id, ")"),
        paste0("CSV in project folder: ", unvisited_file)
      )
    )
  } else {
    build_section(
      "Remaining unvisited stations",
      c(
        "Count: 0",
        "No remaining unvisited stations in the current inventory.",
        paste0("CSV in project folder: ", unvisited_file)
      )
    )
  }

  body_text <- paste(
    paste0(subject_prefix, " weekly check (", subject_date, ")"),
    if (!is.na(current_station_count)) paste0("Current stations tracked: ", current_station_count) else NULL,
    "",
    new_section,
    "",
    dropped_section,
    "",
    unvisited_section,
    "",
    paste0("Snapshot in project folder: ", snapshot_file),
    sep = "\n"
  )

  py_code <- paste(
    "import json, sys, smtplib",
    "from email.message import EmailMessage",
    "with open(sys.argv[1], 'r', encoding='utf-8') as f:",
    "    p = json.load(f)",
    "host = p['host']",
    "port = int(p['port'])",
    "user = p['user']",
    "password = p['password']",
    "from_header = p['from_header']",
    "subject = p['subject']",
    "to_list = [x.strip() for x in p['to'].split(',') if x.strip()]",
    "body = p['body']",
    "use_ssl = bool(p['use_ssl'])",
    "msg = EmailMessage()",
    "msg['Subject'] = subject",
    "msg['From'] = from_header",
    "msg['To'] = ', '.join(to_list)",
    "msg.set_content(body)",
    "if use_ssl:",
    "    with smtplib.SMTP_SSL(host, port) as server:",
    "        server.login(user, password)",
    "        server.send_message(msg)",
    "else:",
    "    with smtplib.SMTP(host, port) as server:",
    "        server.starttls()",
    "        server.login(user, password)",
    "        server.send_message(msg)",
    sep = "\n"
  )

  payload <- list(
    host = host,
    port = ifelse(is.na(port), 587L, port),
    user = user,
    password = pass,
    use_ssl = use_ssl,
    from_header = from,
    subject = if (nrow(new_stations) > 0) {
      paste0(subject_prefix, ": weekly summary - ", nrow(new_stations), " new station(s)")
    } else if (nrow(dropped_stations) > 0) {
      paste0(subject_prefix, ": weekly summary - ", nrow(dropped_stations), " dropped station(s)")
    } else {
      paste0(subject_prefix, ": weekly summary - no new stations")
    },
    to = to,
    body = body_text
  )
  tmp_payload <- tempfile(fileext = ".json")
  tmp_py <- tempfile(fileext = ".py")
  writeLines(jsonlite::toJSON(payload, auto_unbox = TRUE), tmp_payload, useBytes = TRUE)
  writeLines(py_code, tmp_py, useBytes = TRUE)
  on.exit(unlink(c(tmp_payload, tmp_py)), add = TRUE)

  res <- tryCatch(
    system2(
      "/usr/bin/env",
      c("python3", tmp_py, tmp_payload),
      stdout = TRUE,
      stderr = TRUE
    ),
    error = function(e) e
  )

  if (inherits(res, "error")) {
    message("Email send failed: ", conditionMessage(res))
    return(invisible(FALSE))
  }
  st <- attr(res, "status")
  if (!is.null(st) && as.integer(st) != 0L) {
    message("Email send failed with status ", st)
    if (length(res) > 0) message(paste(res, collapse = "\n"))
    return(invisible(FALSE))
  }

  message("Email sent to ", to)
  invisible(TRUE)
}

load_email_config()
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
message("Pulling current station inventory...")
stations_info <- fromJSON(info_url)$data$stations

current <- as_tibble(stations_info) %>%
  transmute(
    station_id = normalize_id(station_id),
    station_name = as.character(name),
    lat = suppressWarnings(as.numeric(lat)),
    lon = suppressWarnings(as.numeric(lon))
  ) %>%
  filter(!is.na(station_id), station_id != "") %>%
  arrange(station_name)

write_csv(current, snapshot_file)

if (file.exists(known_file)) {
  known <- read_csv(known_file, show_col_types = FALSE) %>%
    mutate(
      station_id = normalize_id(station_id),
      station_name = as.character(station_name),
      first_seen_date = as.Date(first_seen_date),
      last_seen_date = as.Date(last_seen_date)
    )
} else {
  known <- tibble(
    station_id = character(),
    station_name = character(),
    first_seen_date = as.Date(character()),
    last_seen_date = as.Date(character())
  )
}

new_stations <- current %>%
  anti_join(known %>% select(station_id), by = "station_id") %>%
  arrange(station_name)

dropped_stations <- known %>%
  anti_join(current %>% select(station_id), by = "station_id") %>%
  arrange(station_name)

known_updated <- current %>%
  select(station_id, station_name) %>%
  left_join(known %>% select(station_id, first_seen_date), by = "station_id") %>%
  mutate(
    first_seen_date = if_else(is.na(first_seen_date), today, first_seen_date),
    last_seen_date = today
  ) %>%
  arrange(station_name)

write_csv(known_updated, known_file)
write_csv(new_stations, new_file)
write_csv(dropped_stations, dropped_file)
remaining_unvisited <- compute_remaining_unvisited(current)

message("Current stations: ", nrow(current))
message("New stations this run: ", nrow(new_stations))
message("Dropped stations this run: ", nrow(dropped_stations))
message("Remaining unvisited stations: ", if (is.null(remaining_unvisited)) "unavailable" else nrow(remaining_unvisited))
message("Snapshot: ", file.path(getwd(), snapshot_file))
message("Known file updated: ", file.path(getwd(), known_file))
message("New stations file: ", file.path(getwd(), new_file))
message("Dropped stations file: ", file.path(getwd(), dropped_file))
if (!is.null(remaining_unvisited)) {
  message("Unvisited file: ", file.path(getwd(), unvisited_file))
}

send_email_if_configured(
  new_stations,
  dropped_stations,
  remaining_unvisited,
  as.character(today),
  current_station_count = nrow(current)
)
