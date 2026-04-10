#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(dplyr)
  library(jsonlite)
  library(readr)
  library(xml2)
})

route_plan_path <- Sys.getenv(
  "ROUTE_PLAN_FILE",
  unset = file.path("outputs", "route_plan", "station_route_plan.csv")
)
output_dir <- Sys.getenv(
  "ROUTE_PLAN_GPX_DIR",
  unset = file.path("outputs", "route_plan_gpx")
)
osrm_base_url <- Sys.getenv("ROUTE_PLAN_OSRM_URL", unset = "http://localhost:5001")
osrm_profile <- Sys.getenv("ROUTE_PLAN_OSRM_PROFILE", unset = "cycling")

sanitize_name <- function(x) {
  x <- trimws(as.character(x))
  x <- gsub("[^A-Za-z0-9]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  tolower(x)
}

label_stop <- function(visit_order, station_name) {
  sprintf("CaBi %02d - %s", visit_order, station_name)
}

normalize_url <- function(x) sub("/+$", "", trimws(as.character(x)))

osrm_route_query <- function(from_lon, from_lat, to_lon, to_lat) {
  paste0(
    normalize_url(osrm_base_url),
    "/route/v1/",
    trimws(osrm_profile),
    "/",
    sprintf("%.6f,%.6f;%.6f,%.6f", from_lon, from_lat, to_lon, to_lat),
    "?overview=full&geometries=geojson&steps=false"
  )
}

fetch_osrm_leg_geometry <- function(from_lon, from_lat, to_lon, to_lat) {
  tmp <- tempfile(fileext = ".json")
  ok <- tryCatch(
    {
      utils::download.file(osrm_route_query(from_lon, from_lat, to_lon, to_lat), tmp, quiet = TRUE)
      TRUE
    },
    error = function(e) FALSE
  )
  if (!ok) return(NULL)

  payload <- tryCatch(jsonlite::fromJSON(tmp), error = function(e) NULL)
  if (is.null(payload) || !identical(payload$code, "Ok") || length(payload$routes) == 0) {
    return(NULL)
  }

  coords <- payload$routes$geometry$coordinates[[1]]
  if (is.null(coords) || nrow(coords) == 0) return(NULL)
  tibble(
    lon = as.numeric(coords[, 1]),
    lat = as.numeric(coords[, 2])
  )
}

build_track_points <- function(day_df) {
  if (nrow(day_df) == 0) {
    return(tibble(lon = numeric(), lat = numeric()))
  }

  if (nrow(day_df) == 1) {
    return(day_df %>% transmute(lon = lon, lat = lat))
  }

  points <- list()
  for (i in seq_len(nrow(day_df) - 1L)) {
    from <- day_df[i, ]
    to <- day_df[i + 1L, ]
    leg <- fetch_osrm_leg_geometry(from$lon, from$lat, to$lon, to$lat)
    if (is.null(leg)) {
      leg <- tibble(
        lon = c(from$lon, to$lon),
        lat = c(from$lat, to$lat)
      )
    } else {
      # Force the exported track to touch the actual dock coordinates even if
      # OSRM snaps the routable geometry slightly away from the station.
      leg <- bind_rows(
        tibble(lon = from$lon, lat = from$lat),
        leg,
        tibble(lon = to$lon, lat = to$lat)
      )
    }
    if (length(points) > 0) {
      leg <- leg[-1, , drop = FALSE]
    }
    points[[length(points) + 1L]] <- leg
  }

  if (length(points) == 0) {
    return(day_df %>% transmute(lon = lon, lat = lat))
  }

  bind_rows(points)
}

build_gpx_doc <- function(day_df) {
  gpx <- xml_new_root(
    "gpx",
    version = "1.1",
    creator = "cabi_route_planner",
    xmlns = "http://www.topografix.com/GPX/1/1",
    `xmlns:xsi` = "http://www.w3.org/2001/XMLSchema-instance",
    `xsi:schemaLocation` = paste(
      "http://www.topografix.com/GPX/1/1",
      "http://www.topografix.com/GPX/1/1/gpx.xsd"
    )
  )

  metadata <- xml_add_child(gpx, "metadata")
  segment_id <- unique(day_df$route_segment)[1]
  segment_suffix <- if (!is.na(segment_id) && segment_id > 1) sprintf(" Segment %d", segment_id) else ""
  xml_add_child(metadata, "name", sprintf("CaBi Day %02d%s", unique(day_df$day)[1], segment_suffix))
  xml_add_child(metadata, "desc", "Capital Bikeshare stop sequence exported from station_route_plan.csv")

  for (i in seq_len(nrow(day_df))) {
    row <- day_df[i, ]
    wpt <- xml_add_child(
      gpx,
      "wpt",
      lat = sprintf("%.6f", row$lat),
      lon = sprintf("%.6f", row$lon)
    )
    xml_add_child(wpt, "name", label_stop(row$visit_order, row$station_name))
    xml_add_child(wpt, "desc", paste0(
      "Capital Bikeshare stop ", row$visit_order,
      " on Day ", sprintf("%02d", row$day),
      ": ", row$station_name
    ))
    xml_add_child(wpt, "cmt", paste("Station ID:", row$station_id))
    xml_add_child(wpt, "sym", "Flag, Blue")
    xml_add_child(wpt, "type", "Capital Bikeshare Station")
  }

  rte <- xml_add_child(gpx, "rte")
  xml_add_child(rte, "name", sprintf("CaBi Day %02d%s", unique(day_df$day)[1], segment_suffix))
  xml_add_child(rte, "desc", "Ordered Capital Bikeshare stop sequence")

  for (i in seq_len(nrow(day_df))) {
    row <- day_df[i, ]
    rtept <- xml_add_child(
      rte,
      "rtept",
      lat = sprintf("%.6f", row$lat),
      lon = sprintf("%.6f", row$lon)
    )
    xml_add_child(rtept, "name", label_stop(row$visit_order, row$station_name))
    xml_add_child(rtept, "desc", paste0(
      "Ride stop ", row$visit_order,
      ": ", row$station_name
    ))
    xml_add_child(rtept, "cmt", paste("Station ID:", row$station_id))
  }

  track_points <- build_track_points(day_df)
  trk <- xml_add_child(gpx, "trk")
  xml_add_child(trk, "name", sprintf("CaBi Day %02d%s Street Route", unique(day_df$day)[1], segment_suffix))
  xml_add_child(trk, "desc", "OSRM-routed street/path geometry between Capital Bikeshare stops")
  trkseg <- xml_add_child(trk, "trkseg")
  for (i in seq_len(nrow(track_points))) {
    row <- track_points[i, ]
    xml_add_child(
      trkseg,
      "trkpt",
      lat = sprintf("%.6f", row$lat),
      lon = sprintf("%.6f", row$lon)
    )
  }

  gpx
}

if (!file.exists(route_plan_path)) {
  stop("Missing route plan file: ", route_plan_path, call. = FALSE)
}

raw_route_df <- read_csv(route_plan_path, show_col_types = FALSE, progress = FALSE)
if (!("route_segment" %in% names(raw_route_df))) {
  raw_route_df$route_segment <- 1L
}

route_df <- raw_route_df %>%
  transmute(
    day = as.integer(day),
    route_segment = as.integer(route_segment),
    visit_order = as.integer(visit_order),
    station_id = as.character(station_id),
    station_name = as.character(station_name),
    lat = as.numeric(lat),
    lon = as.numeric(lon)
  ) %>%
  filter(!is.na(day), !is.na(visit_order), !is.na(lat), !is.na(lon)) %>%
  arrange(day, route_segment, visit_order)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

segment_groups <- route_df %>%
  group_by(day, route_segment) %>%
  summarise(.groups = "drop")

for (group_idx in seq_len(nrow(segment_groups))) {
  day_id <- segment_groups$day[group_idx]
  segment_id <- segment_groups$route_segment[group_idx]
  day_df <- route_df %>%
    filter(day == day_id, route_segment == segment_id) %>%
    arrange(visit_order)
  first_name <- sanitize_name(day_df$station_name[1])
  segment_suffix <- if (!is.na(segment_id) && segment_id > 1) sprintf("_seg_%d", segment_id) else ""
  file_name <- sprintf("day_%02d%s_%s.gpx", day_id, segment_suffix, first_name)
  out_path <- file.path(output_dir, file_name)
  write_xml(build_gpx_doc(day_df), out_path, options = "format")
  message("Wrote ", out_path)
}
