#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(dplyr)
  library(jsonlite)
  library(readr)
})

route_plan_path <- Sys.getenv(
  "ROUTE_PLAN_FILE",
  unset = file.path("outputs", "route_plan", "station_route_plan.csv")
)
output_dir <- Sys.getenv(
  "ROUTE_PLAN_CUES_DIR",
  unset = file.path("outputs", "route_plan_cues")
)
osrm_base_url <- sub("/+$", "", Sys.getenv("ROUTE_PLAN_OSRM_URL", unset = "http://localhost:5001"))
osrm_profile <- trimws(Sys.getenv("ROUTE_PLAN_OSRM_PROFILE", unset = "cycling"))
day_filter <- suppressWarnings(as.integer(Sys.getenv("ROUTE_PLAN_DAY", unset = NA_character_)))

sanitize_name <- function(x) {
  x <- trimws(as.character(x))
  x <- gsub("[^A-Za-z0-9]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  tolower(x)
}

maybe_value <- function(x, default = NA_real_) {
  if (is.null(x) || length(x) == 0L) default else x
}

osrm_leg_url <- function(from_lon, from_lat, to_lon, to_lat) {
  paste0(
    osrm_base_url,
    "/route/v1/",
    osrm_profile,
    "/",
    sprintf("%.6f,%.6f;%.6f,%.6f", from_lon, from_lat, to_lon, to_lat),
    "?steps=true&overview=false&geometries=geojson"
  )
}

read_osrm_leg <- function(from_lon, from_lat, to_lon, to_lat) {
  url <- osrm_leg_url(from_lon, from_lat, to_lon, to_lat)
  raw_json <- tryCatch(
    system2("curl", c("-L", "-sS", shQuote(url)), stdout = TRUE, stderr = TRUE),
    error = function(e) character()
  )
  if (!length(raw_json)) stop("Failed OSRM leg request.")
  payload <- jsonlite::fromJSON(paste(raw_json, collapse = "\n"), simplifyVector = FALSE)
  if (!identical(payload$code, "Ok")) {
    stop("OSRM response code was not Ok.")
  }
  payload$routes[[1]]$legs[[1]]$steps
}

step_instruction <- function(step) {
  maneuver <- step$maneuver
  modifier <- if (!is.null(maneuver$modifier)) maneuver$modifier else ""
  street <- trimws(if (!is.null(step$name)) step$name else "")
  type <- if (!is.null(maneuver$type)) maneuver$type else "continue"

  action <- dplyr::case_when(
    type == "depart" ~ "Depart",
    type == "arrive" ~ "Arrive",
    type == "roundabout" ~ paste("Enter roundabout", if (nzchar(modifier)) paste("and go", modifier) else ""),
    type == "rotary" ~ paste("Enter rotary", if (nzchar(modifier)) paste("and go", modifier) else ""),
    nzchar(modifier) ~ paste(tools::toTitleCase(type), modifier),
    TRUE ~ tools::toTitleCase(type)
  )
  action <- trimws(gsub("\\s+", " ", action))

  if (nzchar(street) && !(type %in% c("arrive"))) {
    paste(action, "on", street)
  } else {
    action
  }
}

format_turn_line <- function(row) {
  sprintf(
    "%02d.%02d  %s  (%.1f mi, %.1f min)",
    row$leg_index,
    row$step_index,
    row$instruction,
    row$distance_m / 1609.344,
    row$duration_s / 60
  )
}

if (!file.exists(route_plan_path)) {
  stop("Missing route plan file: ", route_plan_path, call. = FALSE)
}

route_df <- read_csv(route_plan_path, show_col_types = FALSE, progress = FALSE) %>%
  transmute(
    day = as.integer(day),
    visit_order = as.integer(visit_order),
    station_name = as.character(station_name),
    lat = as.numeric(lat),
    lon = as.numeric(lon)
  ) %>%
  filter(!is.na(day), !is.na(visit_order), !is.na(lat), !is.na(lon)) %>%
  arrange(day, visit_order)

if (!is.na(day_filter)) {
  route_df <- route_df %>% filter(day == day_filter)
}

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

for (day_id in sort(unique(route_df$day))) {
  day_df <- route_df %>% filter(day == day_id) %>% arrange(visit_order)
  if (nrow(day_df) < 2) next

  cue_rows <- list()
  for (i in seq_len(nrow(day_df) - 1L)) {
    from <- day_df[i, ]
    to <- day_df[i + 1L, ]
    steps <- read_osrm_leg(from$lon, from$lat, to$lon, to$lat)

    for (j in seq_along(steps)) {
      step <- steps[[j]]
      cue_rows[[length(cue_rows) + 1L]] <- tibble(
        day = day_id,
        leg_index = i,
        step_index = j,
        from_stop = from$station_name,
        to_stop = to$station_name,
        instruction = step_instruction(step),
        road_name = if (!is.null(step$name)) as.character(step$name) else "",
        maneuver_type = if (!is.null(step$maneuver$type)) as.character(step$maneuver$type) else "",
        maneuver_modifier = if (!is.null(step$maneuver$modifier)) as.character(step$maneuver$modifier) else "",
        distance_m = as.numeric(maybe_value(step$distance)),
        duration_s = as.numeric(maybe_value(step$duration))
      )
    }
  }

  cue_df <- bind_rows(cue_rows)
  first_name <- sanitize_name(day_df$station_name[1])
  csv_path <- file.path(output_dir, sprintf("day_%02d_%s_cuesheet.csv", day_id, first_name))
  txt_path <- file.path(output_dir, sprintf("day_%02d_%s_turns.txt", day_id, first_name))

  write_csv(cue_df, csv_path, na = "")
  writeLines(
    c(
      sprintf("CaBi Day %02d Turn List", day_id),
      sprintf("Start: %s", day_df$station_name[1]),
      sprintf("End: %s", day_df$station_name[nrow(day_df)]),
      "",
      vapply(seq_len(nrow(cue_df)), function(i) format_turn_line(cue_df[i, ]), character(1))
    ),
    txt_path
  )
  message("Wrote ", csv_path)
  message("Wrote ", txt_path)
}
