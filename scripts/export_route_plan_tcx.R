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
  "ROUTE_PLAN_TCX_DIR",
  unset = file.path("outputs", "route_plan_tcx")
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

haversine_m <- function(lon1, lat1, lon2, lat2) {
  rad <- pi / 180
  phi1 <- lat1 * rad
  phi2 <- lat2 * rad
  dphi <- (lat2 - lat1) * rad
  dlambda <- (lon2 - lon1) * rad
  a <- sin(dphi / 2)^2 + cos(phi1) * cos(phi2) * sin(dlambda / 2)^2
  6371000 * 2 * atan2(sqrt(a), sqrt(1 - a))
}

xml_add_text_child <- function(node, name, value) {
  xml_add_child(node, name, as.character(value))
}

osrm_route_url <- function(from_lon, from_lat, to_lon, to_lat) {
  paste0(
    osrm_base_url,
    "/route/v1/",
    osrm_profile,
    "/",
    sprintf("%.6f,%.6f;%.6f,%.6f", from_lon, from_lat, to_lon, to_lat),
    "?steps=true&overview=full&geometries=geojson"
  )
}

read_osrm_leg <- function(from_lon, from_lat, to_lon, to_lat) {
  url <- osrm_route_url(from_lon, from_lat, to_lon, to_lat)
  raw_json <- tryCatch(
    system2("curl", c("-L", "-sS", shQuote(url)), stdout = TRUE, stderr = TRUE),
    error = function(e) character()
  )
  if (!length(raw_json)) stop("Failed OSRM leg request.")
  payload <- jsonlite::fromJSON(paste(raw_json, collapse = "\n"), simplifyVector = FALSE)
  if (!identical(payload$code, "Ok")) {
    stop("OSRM response code was not Ok.")
  }
  payload$routes[[1]]$legs[[1]]
}

point_type_for_step <- function(step) {
  maneuver <- step$maneuver
  type <- if (!is.null(maneuver$type)) as.character(maneuver$type) else ""
  modifier <- if (!is.null(maneuver$modifier)) as.character(maneuver$modifier) else ""

  if (type %in% c("depart", "arrive")) {
    return("Generic")
  }
  if (modifier %in% c("left", "slight left", "sharp left", "uturn")) {
    return("Left")
  }
  if (modifier %in% c("right", "slight right", "sharp right")) {
    return("Right")
  }
  if (modifier %in% c("straight")) {
    return("Straight")
  }
  "Generic"
}

step_instruction <- function(step, from_stop = NULL, to_stop = NULL) {
  maneuver <- step$maneuver
  modifier <- if (!is.null(maneuver$modifier)) maneuver$modifier else ""
  street <- trimws(if (!is.null(step$name)) step$name else "")
  type <- if (!is.null(maneuver$type)) maneuver$type else "continue"

  if (identical(type, "depart") && !is.null(from_stop) && nzchar(trimws(from_stop))) {
    return(sprintf("Depart from %s", trimws(from_stop)))
  }
  if (identical(type, "arrive") && !is.null(to_stop) && nzchar(trimws(to_stop))) {
    return(sprintf("Arrive at %s", trimws(to_stop)))
  }

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

coords_matrix <- function(x) {
  if (is.null(x) || length(x) == 0L) {
    return(matrix(numeric(), ncol = 2))
  }
  if (is.matrix(x)) {
    return(x)
  }
  if (is.data.frame(x)) {
    return(as.matrix(x))
  }
  if (is.list(x)) {
    rows <- lapply(x, function(row) as.numeric(unlist(row)[1:2]))
    rows <- rows[vapply(rows, length, integer(1)) == 2L]
    if (!length(rows)) return(matrix(numeric(), ncol = 2))
    return(do.call(rbind, rows))
  }
  matrix(numeric(), ncol = 2)
}

build_day_payload <- function(day_df) {
  track_rows <- list()
  course_rows <- list()
  station_rows <- list()
  cumulative_distance <- 0

  # Always start the track at the exact first dock.
  track_rows[[1]] <- tibble(
    seq_id = 1L,
    lat = day_df$lat[1],
    lon = day_df$lon[1],
    distance_m = 0
  )
  track_seq <- 1L
  station_rows[[1]] <- tibble(
    sort_distance_m = 0,
    course_index = 1L,
    name = sprintf("Station 01"),
    notes = sprintf("CaBi station: %s", day_df$station_name[1]),
    point_type = "Generic",
    lat = day_df$lat[1],
    lon = day_df$lon[1]
  )

  for (i in seq_len(nrow(day_df) - 1L)) {
    from <- day_df[i, ]
    to <- day_df[i + 1L, ]
    leg <- read_osrm_leg(from$lon, from$lat, to$lon, to$lat)

    full_geometry <- coords_matrix(leg$steps[[1]]$geometry$coordinates)
    if (length(leg$steps) > 1L) {
      full_geometry <- do.call(
        rbind,
        lapply(seq_along(leg$steps), function(step_idx) {
          step_coords <- coords_matrix(leg$steps[[step_idx]]$geometry$coordinates)
          if (step_idx > 1L) step_coords <- step_coords[-1, , drop = FALSE]
          step_coords
        })
      )
    }
    if (is.null(full_geometry) || nrow(full_geometry) == 0L) {
      full_geometry <- matrix(
        c(from$lon, from$lat, to$lon, to$lat),
        ncol = 2,
        byrow = TRUE
      )
    }

    # Force the track to touch the exact dock coordinates at both ends.
    full_geometry <- rbind(
      c(from$lon, from$lat),
      full_geometry,
      c(to$lon, to$lat)
    )
    if (i > 1L) {
      full_geometry <- full_geometry[-1, , drop = FALSE]
    }

    leg_distance <- 0
    leg_track <- lapply(seq_len(nrow(full_geometry)), function(j) {
      if (j == 1L) {
        increment <- 0
      } else {
        increment <- haversine_m(
          lon1 = as.numeric(full_geometry[j - 1L, 1]),
          lat1 = as.numeric(full_geometry[j - 1L, 2]),
          lon2 = as.numeric(full_geometry[j, 1]),
          lat2 = as.numeric(full_geometry[j, 2])
        )
      }
      leg_distance <<- leg_distance + increment
      track_seq <<- track_seq + 1L
      tibble(
        seq_id = track_seq,
        lat = as.numeric(full_geometry[j, 2]),
        lon = as.numeric(full_geometry[j, 1]),
        distance_m = cumulative_distance + leg_distance
      )
    })
    track_rows <- c(track_rows, leg_track)

    step_distance <- cumulative_distance
    for (j in seq_along(leg$steps)) {
      step <- leg$steps[[j]]
      step_type <- if (!is.null(step$maneuver$type)) as.character(step$maneuver$type) else ""
      if (step_type %in% c("depart", "arrive")) {
        step_distance <- step_distance + as.numeric(maybe_value(step$distance, 0))
        next
      }
      maneuver_loc <- maybe_value(step$maneuver$location, c(from$lon, from$lat))
      course_rows[[length(course_rows) + 1L]] <- tibble(
        sort_distance_m = step_distance,
        course_index = NA_integer_,
        name = sprintf("Leg %02d Step %02d", i, j),
        notes = step_instruction(
          step,
          from_stop = from$station_name,
          to_stop = to$station_name
        ),
        point_type = point_type_for_step(step),
        lat = as.numeric(maneuver_loc[2]),
        lon = as.numeric(maneuver_loc[1]),
        distance_m = step_distance
      )
      step_distance <- step_distance + as.numeric(maybe_value(step$distance, 0))
    }
    cumulative_distance <- cumulative_distance + as.numeric(maybe_value(leg$distance, 0))
    station_rows[[length(station_rows) + 1L]] <- tibble(
      sort_distance_m = cumulative_distance,
      course_index = NA_integer_,
      name = sprintf("Station %02d", i + 1L),
      notes = sprintf("CaBi station: %s", to$station_name),
      point_type = "Generic",
      lat = to$lat,
      lon = to$lon
    )
  }

  station_df <- bind_rows(station_rows)
  turn_df <- bind_rows(course_rows)
  if (!("distance_m" %in% names(station_df))) station_df$distance_m <- station_df$sort_distance_m
  if (!("distance_m" %in% names(turn_df))) turn_df$distance_m <- turn_df$sort_distance_m
  course_df <- bind_rows(turn_df, station_df) %>%
    mutate(
      is_station = grepl("^Station ", name),
      distance_m = coalesce(distance_m, sort_distance_m)
    ) %>%
    arrange(sort_distance_m, is_station, name) %>%
    mutate(course_index = row_number()) %>%
    select(course_index, name, notes, point_type, lat, lon, distance_m)

  list(
    track_df = bind_rows(track_rows),
    course_df = course_df
  )
}

build_tcx_doc <- function(day_df, payload) {
  day_id <- unique(day_df$day)[1]
  segment_id <- unique(day_df$route_segment)[1]
  segment_suffix <- if (!is.na(segment_id) && segment_id > 1) sprintf(" Segment %d", segment_id) else ""
  course_name <- sprintf("CaBi Day %02d%s Street Route", day_id, segment_suffix)

  doc <- xml_new_root(
    "TrainingCenterDatabase",
    xmlns = "http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2",
    `xmlns:xsi` = "http://www.w3.org/2001/XMLSchema-instance",
    `xsi:schemaLocation` = paste(
      "http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2",
      "http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd"
    )
  )

  courses <- xml_add_child(doc, "Courses")
  course <- xml_add_child(courses, "Course")
  xml_add_text_child(course, "Name", course_name)

  track <- xml_add_child(course, "Track")
  for (i in seq_len(nrow(payload$track_df))) {
    row <- payload$track_df[i, ]
    tp <- xml_add_child(track, "Trackpoint")
    pos <- xml_add_child(tp, "Position")
    xml_add_text_child(pos, "LatitudeDegrees", sprintf("%.6f", row$lat))
    xml_add_text_child(pos, "LongitudeDegrees", sprintf("%.6f", row$lon))
    xml_add_text_child(tp, "DistanceMeters", sprintf("%.1f", row$distance_m))
  }

  for (i in seq_len(nrow(payload$course_df))) {
    row <- payload$course_df[i, ]
    cp <- xml_add_child(course, "CoursePoint")
    xml_add_text_child(cp, "Name", row$name)
    xml_add_text_child(cp, "Time", sprintf("2000-01-01T00:00:%02dZ", (i - 1L) %% 60L))
    pos <- xml_add_child(cp, "Position")
    xml_add_text_child(pos, "LatitudeDegrees", sprintf("%.6f", row$lat))
    xml_add_text_child(pos, "LongitudeDegrees", sprintf("%.6f", row$lon))
    xml_add_text_child(cp, "PointType", row$point_type)
    xml_add_text_child(cp, "Notes", row$notes)
  }

  lap <- xml_add_child(course, "Lap")
  xml_add_text_child(lap, "TotalTimeSeconds", "0")
  xml_add_text_child(lap, "DistanceMeters", sprintf("%.1f", max(payload$track_df$distance_m, na.rm = TRUE)))

  doc
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
    station_name = as.character(station_name),
    lat = as.numeric(lat),
    lon = as.numeric(lon)
  ) %>%
  filter(!is.na(day), !is.na(visit_order), !is.na(lat), !is.na(lon)) %>%
  arrange(day, route_segment, visit_order)

if (!is.na(day_filter)) {
  route_df <- route_df %>% filter(day == day_filter)
}

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
  if (nrow(day_df) < 2) next
  first_name <- sanitize_name(day_df$station_name[1])
  segment_suffix <- if (!is.na(segment_id) && segment_id > 1) sprintf("_seg_%d", segment_id) else ""
  out_path <- file.path(output_dir, sprintf("day_%02d%s_%s.tcx", day_id, segment_suffix, first_name))
  payload <- build_day_payload(day_df)
  write_xml(build_tcx_doc(day_df, payload), out_path, options = "format")
  message("Wrote ", out_path)
}
