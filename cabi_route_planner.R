#!/usr/bin/env Rscript

# Capital Bikeshare station-completion route planner.
#
# MVP model:
# - cluster-first, route-second multi-day coverage
# - haversine distance costs
# - optional straight-line Metro accessibility scoring
# - open routes, not closed loops
# - nearest-neighbor construction plus 2-opt local search
#
# Runtime configuration is via environment variables so the script stays easy to
# call from Rscript and from future scheduled/interactive workflows.

need_pkg <- function(pkg) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    stop("Missing package: ", pkg, ". Install with install.packages('", pkg, "')", call. = FALSE)
  }
}

need_pkg("dplyr")
need_pkg("readr")

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})

route_output_dir <- file.path("outputs", "route_plan")
default_home_lat <- 38.9096
default_home_lon <- -77.0434

parse_bool <- function(x, default = FALSE) {
  if (is.na(x) || trimws(x) == "") return(default)
  tolower(trimws(as.character(x))) %in% c("true", "t", "1", "yes", "y")
}

env_num <- function(name, default = NA_real_) {
  value <- Sys.getenv(name, unset = "")
  if (value == "") return(default)
  parsed <- suppressWarnings(as.numeric(value))
  if (is.na(parsed)) default else parsed
}

env_int <- function(name, default = NA_integer_) {
  value <- env_num(name, default)
  if (is.na(value)) return(NA_integer_)
  as.integer(round(value))
}

routeCostModel <- function() {
  model <- tolower(trimws(Sys.getenv("ROUTE_PLAN_COST_MODEL", unset = "haversine")))
  if (!(model %in% c("haversine", "osrm"))) "haversine" else model
}

maxMetroWalkMeters <- function() {
  env_num("ROUTE_PLAN_MAX_METRO_WALK_MIN", 30) * env_num("ROUTE_PLAN_WALK_SPEED_M_PER_MIN", 80)
}

avgBikeMetersPerMinute <- function() {
  env_num("ROUTE_PLAN_AVG_BIKE_KMH", 12) * 1000 / 60
}

metersToBikeMinutes <- function(meters) {
  meters / avgBikeMetersPerMinute()
}

metersToTransitMinutes <- function(meters) {
  meters / env_num("ROUTE_PLAN_TRANSIT_SPEED_M_PER_MIN", 500)
}

normalize_station_id <- function(x) trimws(as.character(x))

normalize_station_table <- function(stationsDf) {
  required <- c("station_id", "station_name", "lat", "lon")
  missing_cols <- setdiff(required, names(stationsDf))
  if (length(missing_cols) > 0) {
    stop("Station table missing required columns: ", paste(missing_cols, collapse = ", "), call. = FALSE)
  }

  stationsDf %>%
    transmute(
      station_id = normalize_station_id(station_id),
      station_name = as.character(station_name),
      lat = suppressWarnings(as.numeric(lat)),
      lon = suppressWarnings(as.numeric(lon)),
      visited = if ("visited" %in% names(stationsDf)) parse_bool_vector(visited) else FALSE,
      source_row = row_number()
    ) %>%
    filter(station_id != "", !is.na(lat), !is.na(lon)) %>%
    arrange(source_row) %>%
    distinct(station_id, .keep_all = TRUE) %>%
    arrange(station_name, station_id)
}

parse_bool_vector <- function(x) {
  tolower(trimws(as.character(x))) %in% c("true", "t", "1", "yes", "y")
}

loadStations <- function(
  stationFile = Sys.getenv("ROUTE_PLAN_STATIONS_FILE", unset = "station_inventory_scoring.csv"),
  unvisitedOnly = parse_bool(Sys.getenv("ROUTE_PLAN_UNVISITED_ONLY", unset = "false"))
) {
  if (!file.exists(stationFile)) {
    fallback <- file.path("outputs", "station_inventory_latest.csv")
    if (stationFile != fallback && file.exists(fallback)) {
      message("Station file not found: ", stationFile, ". Falling back to: ", fallback)
      stationFile <- fallback
    } else {
      stop("Station file not found: ", stationFile, call. = FALSE)
    }
  }

  stations <- read_csv(stationFile, show_col_types = FALSE, progress = FALSE) %>%
    normalize_station_table()

  if (unvisitedOnly && "visited" %in% names(stations)) {
    stations <- stations %>% filter(!visited)
  }

  if (nrow(stations) == 0) {
    stop("No valid stations available after filtering.", call. = FALSE)
  }

  stations
}

normalize_metro_table <- function(metroDf) {
  names(metroDf) <- sub("^\ufeff", "", names(metroDf))
  name_col <- intersect(names(metroDf), c("metro_name", "station_name", "name", "Name", "NAME", "StationName"))[1]
  lat_col <- intersect(names(metroDf), c("lat", "latitude", "Lat", "LAT"))[1]
  lon_col <- intersect(names(metroDf), c("lon", "lng", "longitude", "Lon", "LON"))[1]
  x_col <- intersect(names(metroDf), c("X", "x"))[1]
  y_col <- intersect(names(metroDf), c("Y", "y"))[1]

  has_lat_lon <- !any(is.na(c(lat_col, lon_col)))
  has_web_mercator <- !any(is.na(c(x_col, y_col)))

  if (is.na(name_col) || (!has_lat_lon && !has_web_mercator)) {
    stop(
      "Metro table must include a name column plus either lat/lon or Web Mercator X/Y columns.",
      call. = FALSE
    )
  }

  if (has_lat_lon) {
    return(
      metroDf %>%
        transmute(
          metro_name = as.character(.data[[name_col]]),
          metro_lat = suppressWarnings(as.numeric(.data[[lat_col]])),
          metro_lon = suppressWarnings(as.numeric(.data[[lon_col]]))
        ) %>%
        filter(!is.na(metro_lat), !is.na(metro_lon), !is.na(metro_name), metro_name != "") %>%
        distinct(metro_name, metro_lat, metro_lon, .keep_all = TRUE)
    )
  }

  metroDf %>%
    transmute(
      metro_name = as.character(.data[[name_col]]),
      x = suppressWarnings(as.numeric(.data[[x_col]])),
      y = suppressWarnings(as.numeric(.data[[y_col]]))
    ) %>%
    mutate(
      metro_lon = x / 6378137 * 180 / pi,
      metro_lat = (2 * atan(exp(y / 6378137)) - pi / 2) * 180 / pi
    ) %>%
    filter(!is.na(metro_lat), !is.na(metro_lon), !is.na(metro_name), metro_name != "") %>%
    select(metro_name, metro_lat, metro_lon) %>%
    distinct(metro_name, metro_lat, metro_lon, .keep_all = TRUE)
}

loadMetroStations <- function(
  metroFile = Sys.getenv("ROUTE_PLAN_METRO_FILE", unset = file.path("data", "metro_stations.csv")),
  metroUrl = Sys.getenv("WMATA_METRO_STATIONS_URL", unset = ""),
  wmataApiKey = Sys.getenv("WMATA_API_KEY", unset = "")
) {
  if (file.exists(metroFile)) {
    return(read_csv(metroFile, show_col_types = FALSE, progress = FALSE) %>% normalize_metro_table())
  }

  if (wmataApiKey != "") {
    return(loadWmataRailStations(wmataApiKey))
  }

  if (metroUrl != "") {
    return(read_csv(metroUrl, show_col_types = FALSE, progress = FALSE) %>% normalize_metro_table())
  }

  message(
    "No Metro station file found at ", metroFile,
    ". Continuing without Metro endpoint scoring. Set ROUTE_PLAN_METRO_FILE to enable it."
  )
  tibble(metro_name = character(), metro_lat = numeric(), metro_lon = numeric())
}

loadWmataRailStations <- function(apiKey) {
  need_pkg("jsonlite")
  tmp <- tempfile(fileext = ".json")
  url <- "https://api.wmata.com/Rail.svc/json/jStations"
  ok <- tryCatch(
    {
      utils::download.file(
        url,
        tmp,
        quiet = TRUE,
        headers = c(api_key = apiKey)
      )
      TRUE
    },
    error = function(e) {
      message("WMATA rail station API fetch failed: ", conditionMessage(e))
      FALSE
    }
  )

  if (!ok) {
    return(tibble(metro_name = character(), metro_lat = numeric(), metro_lon = numeric()))
  }

  payload <- jsonlite::fromJSON(tmp)
  if (!("Stations" %in% names(payload))) {
    stop("Unexpected WMATA rail station response; missing Stations field.", call. = FALSE)
  }

  payload$Stations %>%
    transmute(
      metro_name = as.character(Name),
      metro_lat = suppressWarnings(as.numeric(Lat)),
      metro_lon = suppressWarnings(as.numeric(Lon))
    ) %>%
    filter(!is.na(metro_lat), !is.na(metro_lon), metro_name != "") %>%
    distinct(metro_name, metro_lat, metro_lon, .keep_all = TRUE)
}

deg_to_rad <- function(x) x * pi / 180

haversineMeters <- function(lat1, lon1, lat2, lon2) {
  earth_radius_m <- 6371008.8
  dlat <- deg_to_rad(lat2 - lat1)
  dlon <- deg_to_rad(lon2 - lon1)
  rlat1 <- deg_to_rad(lat1)
  rlat2 <- deg_to_rad(lat2)
  a <- sin(dlat / 2)^2 + cos(rlat1) * cos(rlat2) * sin(dlon / 2)^2
  earth_radius_m * 2 * atan2(sqrt(a), sqrt(pmax(0, 1 - a)))
}

lowerPotomacSide <- function(lat, lon) {
  case_when(
    lat < 38.845 & lon > -77.035 ~ 1,
    lat < 38.845 & lon <= -77.035 ~ -1,
    TRUE ~ 0
  )
}

centralPotomacSide <- function(lat, lon) {
  case_when(
    lat > 38.901 & lat < 38.92 & lon > -77.10 & lon < -77.055 ~ 1,
    lat > 38.89 & lat <= 38.901 & lon > -77.061 & lon < -77.052 ~ 1,
    lat > 38.875 & lat <= 38.901 & lon < -77.061 ~ -1,
    lat > 38.84 & lat <= 38.875 & lon < -77.035 ~ -1,
    lat > 38.84 & lat < 38.92 & lon >= -77.061 ~ 1,
    TRUE ~ 0
  )
}

planningRegion <- function(lat, lon) {
  lower_side <- lowerPotomacSide(lat, lon)
  central_side <- centralPotomacSide(lat, lon)
  case_when(
    lat < 38.82 & lon <= -77.14 ~ "franconia_pocket",
    lat > 38.93 & lat < 38.98 & lon <= -77.38 ~ "innovation_herndon",
    lat > 38.93 & lat < 38.98 & lon > -77.38 & lon <= -77.33 ~ "reston_pocket",
    lower_side == 1 ~ "lower_potomac_east",
    lower_side == -1 ~ "lower_potomac_west",
    central_side == 1 ~ "central_potomac_dc",
    central_side == -1 ~ "central_potomac_va",
    lat >= 38.93 & lon <= -77.09 ~ "montgomery_west",
    lat >= 38.93 & lon > -77.09 & lon <= -77.01 ~ "montgomery_central",
    lat >= 38.93 & lon > -77.01 ~ "montgomery_east",
    lat > 38.89 & lat < 38.94 & lon <= -77.16 ~ "tysons_outer",
    lat > 38.89 & lat < 38.94 & lon > -77.16 & lon <= -77.07 ~ "arlington_inner",
    lat < 38.86 & lon <= -77.07 ~ "alexandria_far_southwest",
    lat < 38.86 & lon > -77.07 ~ "alexandria_south",
    TRUE ~ "other"
  )
}

pairwiseHaversineMeters <- function(fromLat, fromLon, toLat, toLon) {
  outer(seq_along(fromLat), seq_along(toLat), Vectorize(function(i, j) {
    haversineMeters(fromLat[[i]], fromLon[[i]], toLat[[j]], toLon[[j]])
  }))
}

computeDistanceMatrix <- function(stationsDf, costModel = c("haversine"), applyPenalties = TRUE) {
  costModel <- match.arg(costModel)
  if (costModel != "haversine") {
    stop("Unsupported cost model: ", costModel, call. = FALSE)
  }

  mat <- pairwiseHaversineMeters(stationsDf$lat, stationsDf$lon, stationsDf$lat, stationsDf$lon)
  if (applyPenalties) {
    lower_side <- lowerPotomacSide(stationsDf$lat, stationsDf$lon)
    lower_potomac_crossing <- outer(lower_side, lower_side, Vectorize(function(a, b) {
      a != 0 && b != 0 && a != b
    }))
    mat <- mat + lower_potomac_crossing * env_num("ROUTE_PLAN_LOWER_POTOMAC_CROSSING_PENALTY_M", 12000)

    central_side <- centralPotomacSide(stationsDf$lat, stationsDf$lon)
    central_potomac_crossing <- outer(central_side, central_side, Vectorize(function(a, b) {
      a != 0 && b != 0 && a != b
    }))
    mat <- mat + central_potomac_crossing * env_num("ROUTE_PLAN_CENTRAL_POTOMAC_CROSSING_PENALTY_M", 25000)
  }
  rownames(mat) <- stationsDf$station_id
  colnames(mat) <- stationsDf$station_id
  mat
}

normalizeOsrmBaseUrl <- function(url) {
  url <- trimws(as.character(url))
  sub("/+$", "", url)
}

osrmAvailable <- function() {
  nzchar(normalizeOsrmBaseUrl(Sys.getenv("ROUTE_PLAN_OSRM_URL", unset = "")))
}

osrmTableRequest <- function(coordsDf, annotations = c("duration", "distance"), sources = NULL, destinations = NULL) {
  need_pkg("jsonlite")
  annotations <- match.arg(annotations)
  base_url <- normalizeOsrmBaseUrl(Sys.getenv("ROUTE_PLAN_OSRM_URL", unset = ""))
  if (!nzchar(base_url)) stop("ROUTE_PLAN_OSRM_URL is not set.", call. = FALSE)

  profile <- trimws(Sys.getenv("ROUTE_PLAN_OSRM_PROFILE", unset = "cycling"))
  coord_string <- paste(sprintf("%.6f,%.6f", coordsDf$lon, coordsDf$lat), collapse = ";")
  query <- paste0(
    base_url, "/table/v1/", profile, "/", coord_string,
    "?annotations=", annotations
  )
  if (!is.null(sources)) {
    query <- paste0(query, "&sources=", paste(sources, collapse = ";"))
  }
  if (!is.null(destinations)) {
    query <- paste0(query, "&destinations=", paste(destinations, collapse = ";"))
  }

  payload <- jsonlite::fromJSON(query)
  if (!identical(payload$code, "Ok")) {
    stop("OSRM table request failed with code: ", payload$code, call. = FALSE)
  }

  if (annotations == "duration") payload$durations else payload$distances
}

computeClusterTravelModel <- function(clusterDf, homeLat, homeLon, costModel = routeCostModel(), applyPenalties = TRUE) {
  hav_dist_m <- computeDistanceMatrix(clusterDf, costModel = "haversine", applyPenalties = applyPenalties)
  hav_raw_dist_m <- computeDistanceMatrix(clusterDf, costModel = "haversine", applyPenalties = FALSE)
  hav_duration_min <- metersToBikeMinutes(hav_dist_m)

  home_hav_m <- if (is.na(homeLat) || is.na(homeLon)) rep(NA_real_, nrow(clusterDf)) else {
    haversineMeters(homeLat, homeLon, clusterDf$lat, clusterDf$lon)
  }
  home_hav_bike_min <- metersToBikeMinutes(home_hav_m)

  access_from_home_min <- pmin(
    home_hav_bike_min,
    metersToTransitMinutes(home_hav_m) + clusterDf$nearest_metro_walk_min,
    na.rm = TRUE
  )
  access_to_home_min <- access_from_home_min

  if (costModel != "osrm" || !osrmAvailable()) {
    return(list(
      cost_model = "haversine",
      route_cost_min = hav_duration_min,
      route_distance_m = hav_raw_dist_m,
      home_bike_min = home_hav_bike_min,
      access_from_home_min = access_from_home_min,
      access_to_home_min = access_to_home_min
    ))
  }

  coords_df <- bind_rows(
    tibble(station_id = "__home__", lat = homeLat, lon = homeLon),
    clusterDf %>% select(station_id, lat, lon)
  )

  duration_mat <- tryCatch(
    osrmTableRequest(coords_df, annotations = "duration") / 60,
    error = function(e) {
      message("OSRM duration lookup failed for cluster; falling back to haversine: ", conditionMessage(e))
      NULL
    }
  )

  if (is.null(duration_mat)) {
    return(list(
      cost_model = "haversine",
      route_cost_min = hav_duration_min,
      route_distance_m = hav_raw_dist_m,
      home_bike_min = home_hav_bike_min,
      access_from_home_min = access_from_home_min,
      access_to_home_min = access_to_home_min
    ))
  }

  distance_mat <- tryCatch(
    osrmTableRequest(coords_df, annotations = "distance"),
    error = function(e) {
      message("OSRM distance lookup failed for cluster; using haversine distances in summaries: ", conditionMessage(e))
      NULL
    }
  )

  route_duration_min <- duration_mat[-1, -1, drop = FALSE]
  route_distance_m <- if (is.null(distance_mat)) {
    hav_raw_dist_m
  } else {
    distance_mat[-1, -1, drop = FALSE]
  }

  home_bike_min <- duration_mat[1, -1, drop = TRUE]
  home_hav_transit_min <- metersToTransitMinutes(home_hav_m)
  access_from_home_min <- pmin(
    home_bike_min,
    home_hav_transit_min + clusterDf$nearest_metro_walk_min,
    na.rm = TRUE
  )
  access_to_home_min <- pmin(
    duration_mat[-1, 1, drop = TRUE],
    home_hav_transit_min + clusterDf$nearest_metro_walk_min,
    na.rm = TRUE
  )

  rownames(route_duration_min) <- clusterDf$station_id
  colnames(route_duration_min) <- clusterDf$station_id
  rownames(route_distance_m) <- clusterDf$station_id
  colnames(route_distance_m) <- clusterDf$station_id

  list(
    cost_model = "osrm",
    route_cost_min = route_duration_min,
    route_distance_m = route_distance_m,
    home_bike_min = home_bike_min,
    access_from_home_min = access_from_home_min,
    access_to_home_min = access_to_home_min
  )
}

nearestMetro <- function(stationsDf, metroDf) {
  if (nrow(metroDf) == 0) {
    return(stationsDf %>% mutate(
      nearest_metro = NA_character_,
      nearest_metro_distance_m = NA_real_,
      nearest_metro_walk_min = NA_real_,
      endPointScore = 0
    ))
  }

  dist_mat <- pairwiseHaversineMeters(stationsDf$lat, stationsDf$lon, metroDf$metro_lat, metroDf$metro_lon)
  nearest_idx <- max.col(-dist_mat, ties.method = "first")
  nearest_dist <- dist_mat[cbind(seq_len(nrow(stationsDf)), nearest_idx)]
  walk_speed_m_per_min <- env_num("ROUTE_PLAN_WALK_SPEED_M_PER_MIN", 80)
  endpoint_scale_m <- env_num("ROUTE_PLAN_METRO_SCORE_SCALE_M", 1200)

  stationsDf %>%
    mutate(
      nearest_metro = metroDf$metro_name[nearest_idx],
      nearest_metro_distance_m = nearest_dist,
      nearest_metro_walk_min = nearest_dist / walk_speed_m_per_min,
      endPointScore = exp(-nearest_dist / endpoint_scale_m)
    )
}

scoreMetroAccessibility <- nearestMetro

chooseClusterCount <- function(nStations, targetStationsPerDay = NA_integer_, targetDays = NA_integer_) {
  if (!is.na(targetDays) && targetDays > 0) return(min(nStations, targetDays))
  if (is.na(targetStationsPerDay) || targetStationsPerDay <= 0) targetStationsPerDay <- 25L
  max(1L, ceiling(nStations / targetStationsPerDay))
}

balanceKmeansClusters <- function(stationsDf, initialCluster, targetSize) {
  stationsDf$day <- initialCluster
  if (targetSize <= 0) return(stationsDf$day)

  centers <- stationsDf %>%
    group_by(day) %>%
    summarise(center_lat = mean(lat), center_lon = mean(lon), .groups = "drop")

  max_size <- ceiling(targetSize * env_num("ROUTE_PLAN_MAX_CLUSTER_SIZE_FACTOR", 1.5))

  repeat {
    counts <- table(stationsDf$day)
    overloaded <- as.integer(names(counts[counts > max_size]))
    if (length(overloaded) == 0) break

    changed <- FALSE
    for (cluster_id in overloaded) {
      cluster_rows <- which(stationsDf$day == cluster_id)
      extra_count <- length(cluster_rows) - max_size
      if (extra_count <= 0) next

      center <- centers %>% filter(day == cluster_id)
      dist_to_own_center <- haversineMeters(
        stationsDf$lat[cluster_rows],
        stationsDf$lon[cluster_rows],
        center$center_lat,
        center$center_lon
      )
      move_candidates <- cluster_rows[order(dist_to_own_center, decreasing = TRUE)][seq_len(extra_count)]

      for (row_idx in move_candidates) {
        recipient_counts <- table(factor(stationsDf$day, levels = centers$day))
        open_clusters <- centers$day[recipient_counts < max_size & centers$day != cluster_id]
        if (length(open_clusters) == 0) next

        open_centers <- centers %>% filter(day %in% open_clusters)
        dist_to_open <- haversineMeters(
          stationsDf$lat[row_idx],
          stationsDf$lon[row_idx],
          open_centers$center_lat,
          open_centers$center_lon
        )
        stationsDf$day[row_idx] <- open_centers$day[which.min(dist_to_open)]
        changed <- TRUE
      }
    }

    if (!changed) break
  }

  stationsDf$day
}

remoteClusterMinSize <- function(nearestHomeAccessM, targetStationsPerDay) {
  base_min <- targetMinClusterSize(targetStationsPerDay)
  if (is.na(nearestHomeAccessM) || nearestHomeAccessM <= 0) return(base_min)

  transit_speed_m_per_min <- env_num("ROUTE_PLAN_TRANSIT_SPEED_M_PER_MIN", 500)
  remote_extra_step_min <- env_num("ROUTE_PLAN_REMOTE_ACCESS_MIN_PER_EXTRA_STATION", 20)
  cap <- floor(targetStationsPerDay * env_num("ROUTE_PLAN_REMOTE_MIN_SIZE_CAP_FACTOR", 0.8))
  access_min <- nearestHomeAccessM / transit_speed_m_per_min
  extra_stations <- floor(access_min / remote_extra_step_min)
  max(base_min, min(cap, base_min + extra_stations))
}

smallLoopProtectedRegions <- function() {
  configured <- trimws(Sys.getenv("ROUTE_PLAN_SMALL_LOOP_REGIONS", unset = "alexandria_far_southwest,franconia_pocket,innovation_herndon,reston_pocket"))
  if (!nzchar(configured)) return(character())
  unique(trimws(strsplit(configured, ",", fixed = TRUE)[[1]]))
}

effectiveMinClusterSize <- function(planningRegionName, nearestHomeAccessM, targetStationsPerDay) {
  required_min <- remoteClusterMinSize(nearestHomeAccessM, targetStationsPerDay)
  protected_regions <- smallLoopProtectedRegions()
  if (!(planningRegionName %in% protected_regions)) return(required_min)

  min(required_min, env_int("ROUTE_PLAN_SMALL_LOOP_MIN_SIZE", 4L))
}

dominantPlanningRegion <- function(stationsDf) {
  regions <- planningRegion(stationsDf$lat, stationsDf$lon)
  names(sort(table(regions), decreasing = TRUE))[1]
}

repairMoveAllowed <- function(clustered, moveStationIds, sourceDay, targetDay) {
  protected_regions <- smallLoopProtectedRegions()
  if (length(protected_regions) == 0) return(TRUE)

  move_df <- clustered %>% filter(station_id %in% moveStationIds)
  source_df <- clustered %>% filter(day == sourceDay)
  target_df <- clustered %>% filter(day == targetDay)
  if (nrow(move_df) == 0 || nrow(source_df) == 0 || nrow(target_df) == 0) return(TRUE)

  move_region <- dominantPlanningRegion(move_df)
  source_region <- dominantPlanningRegion(source_df)
  target_region <- dominantPlanningRegion(target_df)

  if (move_region %in% protected_regions && target_region != move_region) return(FALSE)
  if (source_region %in% protected_regions && move_region != source_region) return(FALSE)
  if (target_region %in% protected_regions && move_region != target_region) return(FALSE)

  TRUE
}

moveStationsToAnchorDay <- function(clustered, stationNames, anchorStationName) {
  target_day <- clustered %>%
    filter(station_name == anchorStationName) %>%
    pull(day) %>%
    unique()
  if (length(target_day) != 1) return(clustered)

  move_idx <- clustered$station_name %in% stationNames
  if (!any(move_idx)) return(clustered)

  clustered$day[move_idx] <- target_day[[1]]
  clustered
}

applyManualBoundaryFixes <- function(clustered) {
  if (!parse_bool(Sys.getenv("ROUTE_PLAN_ENABLE_MANUAL_BOUNDARY_FIXES", unset = "true"), TRUE)) {
    return(clustered)
  }

  # Keep the Rosslyn/Fort Myer corridor together.
  clustered <- moveStationsToAnchorDay(
    clustered,
    stationNames = c("19th St N & Ft Myer Dr"),
    anchorStationName = "Rosslyn Metro / Wilson Blvd & N Moore St"
  )

  # Keep the small SW waterfront triangle with the broader SW loop.
  clustered <- moveStationsToAnchorDay(
    clustered,
    stationNames = c(
      "2nd & U St SW",
      "2nd & V St SW / James Creek Marina",
      "Half & Water St SW"
    ),
    anchorStationName = "Waterfront Park"
  )

  renumberDays(clustered)
}

mergeSmallDayClusters <- function(stationsDf, targetStationsPerDay, maxSize, homeLat, homeLon) {
  if (!("planning_region" %in% names(stationsDf))) return(stationsDf)

  repeat {
    stats <- stationsDf %>%
      group_by(day) %>%
      summarise(
        n = n(),
        center_lat = mean(lat),
        center_lon = mean(lon),
        nearest_home_access_m = if (is.na(homeLat) || is.na(homeLon)) 0 else min(haversineMeters(homeLat, homeLon, lat, lon), na.rm = TRUE),
        planning_region = names(sort(table(planning_region), decreasing = TRUE))[1],
        .groups = "drop"
      ) %>%
      mutate(required_min_stations = mapply(
        effectiveMinClusterSize,
        planning_region,
        nearest_home_access_m,
        MoreArgs = list(targetStationsPerDay = targetStationsPerDay)
      ))

    small <- stats %>%
      filter(n < required_min_stations) %>%
      mutate(station_deficit = required_min_stations - n) %>%
      arrange(desc(station_deficit), n)
    if (nrow(small) == 0 || nrow(stats) <= 1) break

    source <- small[1, ]
    candidates <- stats %>%
      filter(day != source$day, planning_region == source$planning_region, n + source$n <= maxSize)
    if (nrow(candidates) == 0) {
      candidates <- stats %>% filter(day != source$day, n + source$n <= maxSize)
    }
    if (nrow(candidates) == 0) break

    candidate_dist <- haversineMeters(source$center_lat, source$center_lon, candidates$center_lat, candidates$center_lon)
    target_day <- candidates$day[which.min(candidate_dist)]
    stationsDf$day[stationsDf$day == source$day] <- target_day
  }

  stationsDf
}

targetMinClusterSize <- function(targetStationsPerDay) {
  max(8L, floor(targetStationsPerDay * env_num("ROUTE_PLAN_MIN_CLUSTER_SIZE_FACTOR", 0.4)))
}

buildDayClusters <- function(
  stationsDf,
  targetStationsPerDay = env_int("ROUTE_PLAN_TARGET_STATIONS_PER_DAY", 25L),
  targetDays = env_int("ROUTE_PLAN_TARGET_DAYS", NA_integer_)
) {
  n <- nrow(stationsDf)
  if (!is.na(targetDays) && targetDays > 0) {
    k <- chooseClusterCount(n, targetStationsPerDay, targetDays)
    return(buildKmeansClusters(stationsDf, k))
  }

  if (is.na(targetStationsPerDay) || targetStationsPerDay <= 0) {
    targetStationsPerDay <- 25L
  }

  region_df <- stationsDf %>%
    mutate(planning_region = planningRegion(lat, lon))

  clustered_regions <- list()
  next_day <- 1L
  for (region_name in unique(region_df$planning_region)) {
    region_stations <- region_df %>% filter(planning_region == region_name)
    region_k <- max(1L, round(nrow(region_stations) / targetStationsPerDay))
    region_clustered <- buildKmeansClusters(region_stations, region_k) %>%
      mutate(day = day + next_day - 1L)
    clustered_regions[[region_name]] <- region_clustered
    next_day <- max(region_clustered$day) + 1L
  }

  max_size <- ceiling(targetStationsPerDay * env_num("ROUTE_PLAN_MAX_CLUSTER_SIZE_FACTOR", 1.5))
  bind_rows(clustered_regions) %>%
    mergeSmallDayClusters(targetStationsPerDay, max_size, env_num("ROUTE_PLAN_HOME_LAT", default_home_lat), env_num("ROUTE_PLAN_HOME_LON", default_home_lon)) %>%
    arrange(day, station_name, station_id) %>%
    renumberDays() %>%
    select(-planning_region)
}

buildKmeansClusters <- function(stationsDf, k) {
  n <- nrow(stationsDf)
  if (k == 1) {
    return(stationsDf %>% mutate(day = 1L))
  }

  set.seed(env_int("ROUTE_PLAN_SEED", 42L))
  coords <- scale(cbind(stationsDf$lon, stationsDf$lat))
  km <- kmeans(coords, centers = k, nstart = env_int("ROUTE_PLAN_KMEANS_NSTART", 50L), iter.max = 100)
  target_size <- ceiling(n / k)
  day_assignments <- balanceKmeansClusters(stationsDf, km$cluster, target_size)

  station_order <- stationsDf %>%
    mutate(raw_day = day_assignments) %>%
    group_by(raw_day) %>%
    summarise(center_lat = mean(lat), center_lon = mean(lon), .groups = "drop") %>%
    arrange(center_lon, desc(center_lat)) %>%
    mutate(day = row_number())

  stationsDf %>%
    mutate(raw_day = day_assignments) %>%
    left_join(station_order %>% select(raw_day, day), by = "raw_day") %>%
    select(-raw_day)
}

renumberDays <- function(stationsDf) {
  day_order <- stationsDf %>%
    group_by(day) %>%
    summarise(center_lat = mean(lat), center_lon = mean(lon), .groups = "drop") %>%
    arrange(center_lon, desc(center_lat)) %>%
    mutate(new_day = row_number())

  stationsDf %>%
    left_join(day_order %>% select(day, new_day), by = "day") %>%
    mutate(day = new_day) %>%
    select(-new_day)
}

routeDistance <- function(routeIdx, distMat) {
  if (length(routeIdx) <= 1) return(0)
  sum(distMat[cbind(routeIdx[-length(routeIdx)], routeIdx[-1])])
}

routeLegPenalty <- function(
  routeIdx,
  clusterDf,
  routeDistanceMat,
  ratioThreshold = env_num("ROUTE_PLAN_BAD_LEG_RATIO_THRESHOLD", 1.85),
  minExcessMeters = env_num("ROUTE_PLAN_BAD_LEG_MIN_EXCESS_M", 450),
  ratioPenaltyWeight = env_num("ROUTE_PLAN_BAD_LEG_RATIO_PENALTY", 18),
  excessPenaltyPerKm = env_num("ROUTE_PLAN_BAD_LEG_EXCESS_PENALTY_PER_KM", 10)
) {
  if (length(routeIdx) <= 1) return(0)

  from_idx <- routeIdx[-length(routeIdx)]
  to_idx <- routeIdx[-1]
  route_m <- routeDistanceMat[cbind(from_idx, to_idx)]
  beeline_m <- haversineMeters(
    clusterDf$lat[from_idx],
    clusterDf$lon[from_idx],
    clusterDf$lat[to_idx],
    clusterDf$lon[to_idx]
  )

  valid <- !is.na(route_m) & !is.na(beeline_m) & beeline_m > 0
  if (!any(valid)) return(0)

  route_m <- route_m[valid]
  beeline_m <- beeline_m[valid]
  ratio <- route_m / pmax(beeline_m, 1)
  excess_m <- pmax(0, route_m - beeline_m)
  flagged <- ratio > ratioThreshold & excess_m > minExcessMeters
  if (!any(flagged)) return(0)

  sum(
    (ratio[flagged] - ratioThreshold) * ratioPenaltyWeight +
      (excess_m[flagged] / 1000) * excessPenaltyPerKm,
    na.rm = TRUE
  )
}

nearestNeighborOpenPath <- function(distMat, startIdx, endIdx = NA_integer_) {
  n <- nrow(distMat)
  if (n == 1) return(1L)
  if (!is.na(endIdx) && startIdx == endIdx && n > 1) {
    stop("Start and end cannot be the same for a multi-station route.", call. = FALSE)
  }

  remaining <- setdiff(seq_len(n), c(startIdx, endIdx))
  route <- startIdx
  current <- startIdx

  while (length(remaining) > 0) {
    next_idx <- remaining[which.min(distMat[current, remaining])]
    route <- c(route, next_idx)
    remaining <- setdiff(remaining, next_idx)
    current <- next_idx
  }

  if (!is.na(endIdx)) route <- c(route, endIdx)
  route
}

twoOptOpenPath <- function(routeIdx, distMat) {
  if (length(routeIdx) < 4) return(routeIdx)

  improved <- TRUE
  best <- routeIdx
  best_dist <- routeDistance(best, distMat)
  pass <- 0L
  max_passes <- env_int("ROUTE_PLAN_TWO_OPT_MAX_PASSES", 2L)

  while (improved && pass < max_passes) {
    improved <- FALSE
    pass <- pass + 1L
    for (i in 2:(length(best) - 2)) {
      for (j in (i + 1):(length(best) - 1)) {
        candidate <- c(best[1:(i - 1)], rev(best[i:j]), best[(j + 1):length(best)])
        candidate_dist <- routeDistance(candidate, distMat)
        if (candidate_dist + 1e-6 < best_dist) {
          best <- candidate
          best_dist <- candidate_dist
          improved <- TRUE
        }
      }
    }
  }

  best
}

relocateOpenPath <- function(routeIdx, distMat) {
  if (length(routeIdx) < 5) return(routeIdx)

  improved <- TRUE
  best <- routeIdx
  best_dist <- routeDistance(best, distMat)
  pass <- 0L
  max_passes <- env_int("ROUTE_PLAN_RELOCATE_MAX_PASSES", 2L)

  while (improved && pass < max_passes) {
    improved <- FALSE
    pass <- pass + 1L

    for (i in 2:(length(best) - 1)) {
      node <- best[i]
      remainder <- best[-i]
      insert_positions <- 2:length(remainder)

      for (pos in insert_positions) {
        if (pos == i) next
        candidate <- append(remainder, node, after = pos - 1L)
        candidate_dist <- routeDistance(candidate, distMat)
        if (candidate_dist + 1e-6 < best_dist) {
          best <- candidate
          best_dist <- candidate_dist
          improved <- TRUE
        }
      }
    }
  }

  best
}

improveOpenPathByScore <- function(routeIdx, scoreFn) {
  if (length(routeIdx) < 4) return(routeIdx)

  best <- routeIdx
  best_score <- scoreFn(best)
  improved <- TRUE
  pass <- 0L
  max_passes <- env_int("ROUTE_PLAN_SCORE_LOCAL_MAX_PASSES", 2L)

  while (improved && pass < max_passes) {
    improved <- FALSE
    pass <- pass + 1L

    for (i in 2:(length(best) - 1)) {
      node <- best[i]
      remainder <- best[-i]
      for (pos in 2:length(remainder)) {
        if (pos == i) next
        candidate <- append(remainder, node, after = pos - 1L)
        candidate_score <- scoreFn(candidate)
        if (candidate_score + 1e-6 < best_score) {
          best <- candidate
          best_score <- candidate_score
          improved <- TRUE
        }
      }
    }

    for (i in 2:(length(best) - 2)) {
      candidate <- best
      candidate[c(i, i + 1)] <- candidate[c(i + 1, i)]
      candidate_score <- scoreFn(candidate)
      if (candidate_score + 1e-6 < best_score) {
        best <- candidate
        best_score <- candidate_score
        improved <- TRUE
      }
    }
  }

  best
}

scoreRoute <- function(
  routeIdx,
  clusterDf,
  distMat,
  routeDistanceMat = distMat,
  homeLat,
  homeLon,
  allStationsDf = NULL,
  globalDistMat = NULL,
  bikeWeight = env_num("ROUTE_PLAN_BIKE_WEIGHT", 1),
  accessWeight = env_num("ROUTE_PLAN_ACCESS_WEIGHT", 1),
  imbalanceWeight = env_num("ROUTE_PLAN_IMBALANCE_WEIGHT", 0),
  maxTotalDayMinutes = env_num("ROUTE_PLAN_MAX_TOTAL_DAY_MINUTES", 300),
  overCapPenaltyPerMinute = env_num("ROUTE_PLAN_DAY_OVERCAP_PENALTY_PER_MIN", 30),
  targetStationsPerDay = env_int("ROUTE_PLAN_TARGET_STATIONS_PER_DAY", 25L)
) {
  start_idx <- routeIdx[1]
  end_idx <- routeIdx[length(routeIdx)]
  route_min <- routeDistance(routeIdx, distMat)
  start_access_min <- clusterDf$access_from_home_min[start_idx]
  end_access_min <- clusterDf$access_to_home_min[end_idx]
  total_day_minutes <- route_min + start_access_min + end_access_min
  over_cap_penalty <- max(0, total_day_minutes - maxTotalDayMinutes) * overCapPenaltyPerMinute
  imbalance_penalty <- if (is.na(targetStationsPerDay) || targetStationsPerDay <= 0) 0 else {
    abs(length(routeIdx) - targetStationsPerDay) * env_num("ROUTE_PLAN_IMBALANCE_PENALTY_PER_STATION", 8)
  }
  bad_leg_penalty <- routeLegPenalty(routeIdx, clusterDf, routeDistanceMat)

  bikeWeight * route_min +
    accessWeight * (start_access_min + end_access_min) +
    imbalanceWeight * imbalance_penalty +
    bad_leg_penalty +
    over_cap_penalty
}

accessCandidateIndices <- function(accessMeters, n, fallbackValues = accessMeters) {
  max_access_min <- env_num("ROUTE_PLAN_MAX_CANDIDATE_ACCESS_MIN", 45)
  accessible <- which(!is.na(accessMeters) & accessMeters <= max_access_min)
  if (length(accessible) > 0) {
    return(accessible[order(accessMeters[accessible], na.last = TRUE)][seq_len(min(n, length(accessible)))])
  }

  candidateIndices(fallbackValues, n = n, decreasing = FALSE)
}

candidateIndices <- function(values, n = 5, decreasing = FALSE) {
  if (length(values) == 0) return(integer())
  ord <- order(values, decreasing = decreasing, na.last = TRUE)
  ord[seq_len(min(n, length(ord)))]
}

metroExitCostMeters <- function(endIdx, clusterDf, distMat, allStationsDf = NULL, globalDistMat = NULL) {
  direct_m <- clusterDf$nearest_metro_distance_m[endIdx]
  max_walk_m <- maxMetroWalkMeters()

  if (is.na(direct_m)) {
    return(list(exit_cost_m = 0, strategy = "metro_unavailable", via_station_id = NA_character_, via_station_name = NA_character_))
  }

  if (direct_m <= max_walk_m) {
    return(list(exit_cost_m = direct_m, strategy = "direct_walk", via_station_id = NA_character_, via_station_name = NA_character_))
  }

  accessible_idx <- which(!is.na(clusterDf$nearest_metro_distance_m) & clusterDf$nearest_metro_distance_m <= max_walk_m)
  if (length(accessible_idx) == 0) {
    if (!is.null(allStationsDf) && !is.null(globalDistMat)) {
      accessible_system_idx <- which(!is.na(allStationsDf$nearest_metro_distance_m) & allStationsDf$nearest_metro_distance_m <= max_walk_m)
      if (length(accessible_system_idx) > 0) {
        end_station_id <- clusterDf$station_id[endIdx]
        accessible_station_ids <- allStationsDf$station_id[accessible_system_idx]
        double_back_costs <- globalDistMat[end_station_id, accessible_station_ids] + allStationsDf$nearest_metro_distance_m[accessible_system_idx]
        best_pos <- which.min(double_back_costs)
        best_access_idx <- accessible_system_idx[best_pos]
        return(list(
          exit_cost_m = double_back_costs[[best_pos]],
          strategy = "bike_to_system_metro_accessible_station",
          via_station_id = allStationsDf$station_id[best_access_idx],
          via_station_name = allStationsDf$station_name[best_access_idx]
        ))
      }
    }
    return(list(exit_cost_m = direct_m, strategy = "over_cap_walk", via_station_id = NA_character_, via_station_name = NA_character_))
  }

  double_back_costs <- distMat[endIdx, accessible_idx] + clusterDf$nearest_metro_distance_m[accessible_idx]
  best_access_idx <- accessible_idx[which.min(double_back_costs)]
  list(
    exit_cost_m = double_back_costs[[which.min(double_back_costs)]],
    strategy = "bike_to_metro_accessible_station",
    via_station_id = clusterDf$station_id[best_access_idx],
    via_station_name = clusterDf$station_name[best_access_idx]
  )
}

solveClusterRoute <- function(
  clusterDf,
  routeCostMat,
  routeDistanceMat = routeCostMat,
  homeLat = env_num("ROUTE_PLAN_HOME_LAT", default_home_lat),
  homeLon = env_num("ROUTE_PLAN_HOME_LON", default_home_lon)
) {
  n <- nrow(clusterDf)
  if (n == 1) {
    return(list(order = 1L, score = 0, route_m = 0))
  }

  if (all(is.na(clusterDf$nearest_metro_distance_m))) {
    end_values <- clusterDf$access_to_home_min
    start_values <- clusterDf$access_from_home_min
  } else {
    end_values <- clusterDf$access_to_home_min
    start_values <- clusterDf$access_from_home_min
  }
  start_candidates <- accessCandidateIndices(
    start_values,
    n = env_int("ROUTE_PLAN_START_CANDIDATES", 3L),
    fallbackValues = start_values
  )
  end_candidates <- accessCandidateIndices(
    end_values,
    n = env_int("ROUTE_PLAN_END_CANDIDATES", 4L),
    fallbackValues = end_values
  )

  best_route <- NULL
  best_score <- Inf
  best_route_m <- Inf

  for (start_idx in start_candidates) {
    for (end_idx in setdiff(end_candidates, start_idx)) {
      score_fn <- function(route) scoreRoute(
        route,
        clusterDf,
        routeCostMat,
        routeDistanceMat = routeDistanceMat,
        homeLat,
        homeLon
      )
      initial <- nearestNeighborOpenPath(routeCostMat, start_idx, end_idx)
      improved <- twoOptOpenPath(initial, routeCostMat)
      improved <- relocateOpenPath(improved, routeCostMat)
      improved <- twoOptOpenPath(improved, routeCostMat)
      improved <- improveOpenPathByScore(improved, score_fn)
      score <- score_fn(improved)
      if (score < best_score) {
        best_route <- improved
        best_score <- score
        best_route_m <- routeDistance(improved, routeCostMat)
      }
    }
  }

  if (is.null(best_route)) {
    score_fn <- function(route) scoreRoute(
      route,
      clusterDf,
      routeCostMat,
      routeDistanceMat = routeDistanceMat,
      homeLat,
      homeLon
    )
    initial <- nearestNeighborOpenPath(routeCostMat, start_candidates[[1]], NA_integer_)
    best_route <- twoOptOpenPath(initial, routeCostMat)
    best_route <- relocateOpenPath(best_route, routeCostMat)
    best_route <- twoOptOpenPath(best_route, routeCostMat)
    best_route <- improveOpenPathByScore(best_route, score_fn)
    best_score <- score_fn(best_route)
    best_route_m <- routeDistance(best_route, routeCostMat)
  }

  list(order = best_route, score = best_score, route_m = best_route_m)
}

detectRouteSegments <- function(
  ordered,
  solved_order,
  travel_model,
  minStationsPerSegment = env_int("ROUTE_PLAN_SEGMENT_MIN_STATIONS", 2L),
  minRouteMeters = env_num("ROUTE_PLAN_SEGMENT_MIN_ROUTE_M", 2500),
  minExcessMeters = env_num("ROUTE_PLAN_SEGMENT_MIN_EXCESS_M", 1500),
  ratioThreshold = env_num("ROUTE_PLAN_SEGMENT_BAD_LEG_RATIO", 2.2)
) {
  n <- nrow(ordered)
  segments <- rep(1L, n)
  if (n < (minStationsPerSegment * 2)) return(segments)

  route_m <- travel_model$route_distance_m[cbind(solved_order[-n], solved_order[-1])]
  beeline_m <- haversineMeters(
    ordered$lat[-n],
    ordered$lon[-n],
    ordered$lat[-1],
    ordered$lon[-1]
  )
  excess_m <- route_m - beeline_m
  ratio <- route_m / pmax(beeline_m, 1)

  candidate_idx <- which(
    !is.na(route_m) &
      !is.na(excess_m) &
      !is.na(ratio) &
      route_m >= minRouteMeters &
      excess_m >= minExcessMeters &
      ratio >= ratioThreshold
  )
  if (!length(candidate_idx)) return(segments)

  # Split on the single worst connector. Keep the model simple.
  split_idx <- candidate_idx[which.max(excess_m[candidate_idx] * ratio[candidate_idx])]
  if (split_idx < minStationsPerSegment || (n - split_idx) < minStationsPerSegment) {
    return(segments)
  }

  segments[(split_idx + 1):n] <- 2L
  segments
}

evaluateDayCluster <- function(
  clusterDf,
  clusteredAll,
  rawDistMatAll,
  homeLat,
  homeLon,
  costModel
) {
  travel_model <- computeClusterTravelModel(clusterDf, homeLat, homeLon, costModel = costModel, applyPenalties = TRUE)
  cluster_route_df <- clusterDf %>%
    mutate(
      access_from_home_min = travel_model$access_from_home_min,
      access_to_home_min = travel_model$access_to_home_min,
      home_bike_min = travel_model$home_bike_min
    )
  solved <- solveClusterRoute(
    cluster_route_df,
    travel_model$route_cost_min,
    routeDistanceMat = travel_model$route_distance_m,
    homeLat,
    homeLon
  )
  route_segments <- detectRouteSegments(cluster_route_df[solved$order, , drop = FALSE], solved$order, travel_model)
  ordered <- cluster_route_df[solved$order, , drop = FALSE] %>%
    mutate(
      visit_order = row_number(),
      route_segment = route_segments
    ) %>%
    group_by(route_segment) %>%
    mutate(segment_visit_order = row_number()) %>%
    ungroup()

  start_row <- ordered[1, ]
  end_row <- ordered[nrow(ordered), ]
  exit <- metroExitCostMeters(
    solved$order[length(solved$order)],
    clusterDf,
    rawDistMatAll[clusterDf$station_id, clusterDf$station_id, drop = FALSE],
    clusteredAll,
    rawDistMatAll
  )
  route_km <- routeDistance(solved$order, travel_model$route_distance_m) / 1000
  route_minutes <- routeDistance(solved$order, travel_model$route_cost_min)
  home_to_start_access_min <- start_row$access_from_home_min
  end_to_home_access_min <- end_row$access_to_home_min
  total_access_overhead_min_est <- home_to_start_access_min + end_to_home_access_min

  summary_row <- tibble(
    day = unique(clusterDf$day)[1],
    stations = nrow(ordered),
    route_distance_km = route_km,
    route_distance_mi = route_km * 0.621371,
    estimated_bike_minutes = route_minutes,
    estimated_total_day_minutes = route_minutes + total_access_overhead_min_est,
    route_score = solved$score,
    route_cost_model = travel_model$cost_model,
    start_station_id = start_row$station_id,
    start_station_name = start_row$station_name,
    home_to_start_transit_min_est = home_to_start_access_min,
    nearest_metro_at_start = start_row$nearest_metro,
    start_to_metro_m = start_row$nearest_metro_distance_m,
    start_to_metro_walk_min = start_row$nearest_metro_walk_min,
    start_metro_access_ok = !is.na(start_row$nearest_metro_distance_m) & start_row$nearest_metro_distance_m <= maxMetroWalkMeters(),
    end_station_id = end_row$station_id,
    end_station_name = end_row$station_name,
    end_to_home_transit_min_est = end_to_home_access_min,
    nearest_metro_at_end = end_row$nearest_metro,
    end_to_metro_m = end_row$nearest_metro_distance_m,
    end_to_metro_walk_min = end_row$nearest_metro_walk_min,
    end_metro_access_ok = !is.na(end_row$nearest_metro_distance_m) & end_row$nearest_metro_distance_m <= maxMetroWalkMeters(),
    end_exit_strategy = exit$strategy,
    exit_via_station_id = exit$via_station_id,
    exit_via_station_name = exit$via_station_name,
    exit_cost_m = exit$exit_cost_m,
    exit_cost_walk_min_equivalent = exit$exit_cost_m / env_num("ROUTE_PLAN_WALK_SPEED_M_PER_MIN", 80),
    total_access_overhead_min_est = total_access_overhead_min_est
  )

  list(
    ordered = ordered,
    summary = summary_row,
    solved = solved,
    travel_model = travel_model
  )
}

dayCentroids <- function(stationsDf) {
  stationsDf %>%
    group_by(day) %>%
    summarise(center_lat = mean(lat), center_lon = mean(lon), n = n(), .groups = "drop")
}

clusterCompactnessPenalty <- function(clusterDf) {
  if (nrow(clusterDf) <= 1) return(0)

  dists_m <- haversineMeters(
    clusterDf$lat,
    clusterDf$lon,
    mean(clusterDf$lat),
    mean(clusterDf$lon)
  )

  mean_penalty <- mean(dists_m, na.rm = TRUE) / 1000 * env_num("ROUTE_PLAN_REPAIR_MEAN_SPREAD_PENALTY_PER_KM", 1.2)
  max_penalty <- max(dists_m, na.rm = TRUE) / 1000 * env_num("ROUTE_PLAN_REPAIR_MAX_SPREAD_PENALTY_PER_KM", 0.8)
  mean_penalty + max_penalty
}

detectRepairCandidateWindows <- function(dayEval) {
  ordered <- dayEval$ordered
  n <- nrow(ordered)
  if (n < 6) return(list())

  seg_m <- dayEval$travel_model$route_distance_m[cbind(dayEval$solved$order[-n], dayEval$solved$order[-1])]
  if (length(seg_m) == 0) return(list())

  threshold_m <- env_num("ROUTE_PLAN_REPAIR_LONG_LEG_M", 4000)
  split_idx <- which.max(seg_m)
  if (length(split_idx) == 0 || is.na(seg_m[split_idx]) || seg_m[split_idx] < threshold_m) return(list())

  max_group <- env_int("ROUTE_PLAN_REPAIR_MAX_GROUP_SIZE", 6L)
  min_day_size <- env_int("ROUTE_PLAN_REPAIR_MIN_DAY_SIZE", 10L)
  candidates <- list()

  if (split_idx <= max_group && (n - split_idx) >= min_day_size) {
    candidates[[length(candidates) + 1L]] <- ordered$station_id[seq_len(split_idx)]
  }
  suffix_size <- n - split_idx
  if (suffix_size <= max_group && split_idx >= min_day_size) {
    candidates[[length(candidates) + 1L]] <- ordered$station_id[(split_idx + 1):n]
  }

  long_idx <- which(seg_m >= threshold_m)
  if (length(long_idx) >= 2) {
    for (k in seq_len(length(long_idx) - 1L)) {
      i <- long_idx[k]
      j <- long_idx[k + 1L]
      if (j <= i) next
      window_size <- j - i
      if (window_size <= 0 || window_size > max_group) next
      if (i < min_day_size || (n - j) < min_day_size) next
      candidates[[length(candidates) + 1L]] <- ordered$station_id[(i + 1L):j]
    }
  }

  deduped <- list()
  seen <- character()
  for (candidate in candidates) {
    key <- paste(candidate, collapse = "|")
    if (key %in% seen) next
    seen <- c(seen, key)
    deduped[[length(deduped) + 1L]] <- candidate
  }

  deduped
}

detectOutlierRepairCandidates <- function(dayEval, clustered) {
  ordered <- dayEval$ordered
  n <- nrow(ordered)
  min_day_size <- env_int("ROUTE_PLAN_REPAIR_MIN_DAY_SIZE", 10L)
  if (n <= min_day_size) return(list())

  own_center <- dayCentroids(clustered) %>% filter(day == unique(ordered$day)[1])
  other_centers <- dayCentroids(clustered) %>% filter(day != unique(ordered$day)[1])
  if (nrow(other_centers) == 0) return(list())

  own_dist_m <- haversineMeters(ordered$lat, ordered$lon, own_center$center_lat, own_center$center_lon)
  target_day <- integer(n)
  nearest_other_m <- numeric(n)

  for (i in seq_len(n)) {
    dists <- haversineMeters(ordered$lat[i], ordered$lon[i], other_centers$center_lat, other_centers$center_lon)
    best_idx <- which.min(dists)
    target_day[i] <- other_centers$day[best_idx]
    nearest_other_m[i] <- dists[[best_idx]]
  }

  ordered <- ordered %>%
    mutate(
      own_dist_m = own_dist_m,
      target_day = target_day,
      nearest_other_m = nearest_other_m,
      target_gain_m = own_dist_m - nearest_other_m
    ) %>%
    arrange(desc(target_gain_m))

  min_gain_m <- env_num("ROUTE_PLAN_REPAIR_OUTLIER_MIN_DELTA_M", 2200)
  ratio <- env_num("ROUTE_PLAN_REPAIR_OUTLIER_RATIO", 0.72)
  max_candidates <- env_int("ROUTE_PLAN_REPAIR_OUTLIER_CANDIDATES", 4L)
  group_radius_m <- env_num("ROUTE_PLAN_REPAIR_OUTLIER_GROUP_RADIUS_M", 2500)
  max_group <- env_int("ROUTE_PLAN_REPAIR_OUTLIER_MAX_GROUP_SIZE", 5L)

  flagged <- ordered %>%
    filter(
      target_gain_m >= min_gain_m,
      nearest_other_m <= own_dist_m * ratio
    ) %>%
    slice_head(n = max_candidates)

  if (nrow(flagged) == 0) return(list())

  candidates <- list()
  for (idx in seq_len(nrow(flagged))) {
    row <- flagged[idx, ]
    candidates[[length(candidates) + 1L]] <- row$station_id

    compatible <- ordered %>%
      filter(target_day == row$target_day) %>%
      mutate(seed_dist_m = haversineMeters(lat, lon, row$lat, row$lon)) %>%
      arrange(seed_dist_m) %>%
      filter(seed_dist_m <= group_radius_m) %>%
      slice_head(n = max_group)

    if (nrow(compatible) > 1 && (n - nrow(compatible)) >= min_day_size) {
      candidates[[length(candidates) + 1L]] <- compatible$station_id
    }
  }

  deduped <- list()
  seen <- character()
  for (candidate in candidates) {
    key <- paste(sort(candidate), collapse = "|")
    if (key %in% seen) next
    seen <- c(seen, key)
    deduped[[length(deduped) + 1L]] <- candidate
  }

  deduped
}

repairTargetDays <- function(clustered, moveStationIds, sourceDay, maxCandidates = env_int("ROUTE_PLAN_REPAIR_TARGET_DAY_CANDIDATES", 5L)) {
  move_df <- clustered %>% filter(station_id %in% moveStationIds)
  if (nrow(move_df) == 0) return(integer())

  move_center_lat <- mean(move_df$lat)
  move_center_lon <- mean(move_df$lon)
  centroids <- dayCentroids(clustered) %>% filter(day != sourceDay)
  if (nrow(centroids) == 0) return(integer())

  centroids %>%
    mutate(center_dist_m = haversineMeters(move_center_lat, move_center_lon, center_lat, center_lon)) %>%
    arrange(center_dist_m) %>%
    slice_head(n = maxCandidates) %>%
    pull(day)
}

evaluateRepairMove <- function(clustered, moveStationIds, sourceDay, targetDay, rawDistMatAll, homeLat, homeLon, costModel) {
  if (!repairMoveAllowed(clustered, moveStationIds, sourceDay, targetDay)) {
    return(NULL)
  }

  moved <- clustered
  moved$day[moved$station_id %in% moveStationIds] <- targetDay

  source_after <- moved %>% filter(day == sourceDay)
  target_after <- moved %>% filter(day == targetDay)
  min_day_size <- env_int("ROUTE_PLAN_REPAIR_MIN_DAY_SIZE", 10L)
  max_day_size <- ceiling(env_int("ROUTE_PLAN_TARGET_STATIONS_PER_DAY", 25L) * env_num("ROUTE_PLAN_MAX_CLUSTER_SIZE_FACTOR", 1.5)) +
    env_int("ROUTE_PLAN_REPAIR_TARGET_OVERFLOW", 4L)

  if (nrow(source_after) < min_day_size || nrow(target_after) > max_day_size) {
    return(NULL)
  }

  source_before <- clustered %>% filter(day == sourceDay)
  target_before <- clustered %>% filter(day == targetDay)

  source_before_eval <- evaluateDayCluster(source_before, clustered, rawDistMatAll, homeLat, homeLon, costModel)
  target_before_eval <- evaluateDayCluster(target_before, clustered, rawDistMatAll, homeLat, homeLon, costModel)
  source_after_eval <- evaluateDayCluster(source_after, moved, rawDistMatAll, homeLat, homeLon, costModel)
  target_after_eval <- evaluateDayCluster(target_after, moved, rawDistMatAll, homeLat, homeLon, costModel)

  before_total_minutes <- source_before_eval$summary$estimated_total_day_minutes + target_before_eval$summary$estimated_total_day_minutes
  after_total_minutes <- source_after_eval$summary$estimated_total_day_minutes + target_after_eval$summary$estimated_total_day_minutes
  total_minutes_delta <- before_total_minutes - after_total_minutes

  before_compactness <- clusterCompactnessPenalty(source_before) + clusterCompactnessPenalty(target_before)
  after_compactness <- clusterCompactnessPenalty(source_after) + clusterCompactnessPenalty(target_after)
  compactness_delta <- before_compactness - after_compactness

  before_route_score <- source_before_eval$summary$route_score + target_before_eval$summary$route_score
  after_route_score <- source_after_eval$summary$route_score + target_after_eval$summary$route_score
  route_score_delta <- before_route_score - after_route_score

  primary_min_improvement <- env_num("ROUTE_PLAN_REPAIR_MIN_TOTAL_MINUTES_IMPROVEMENT", 3)
  secondary_compactness_weight <- env_num("ROUTE_PLAN_REPAIR_COMPACTNESS_TIEBREAKER_WEIGHT", 0.35)
  secondary_route_score_weight <- env_num("ROUTE_PLAN_REPAIR_ROUTE_SCORE_TIEBREAKER_WEIGHT", 0.05)
  effective_delta <- total_minutes_delta +
    secondary_compactness_weight * compactness_delta +
    secondary_route_score_weight * route_score_delta

  list(
    improved = total_minutes_delta > primary_min_improvement || effective_delta > primary_min_improvement,
    score_delta = effective_delta,
    total_minutes_delta = total_minutes_delta,
    compactness_delta = compactness_delta,
    route_score_delta = route_score_delta,
    clustered = moved
  )
}

postClusterRepair <- function(clustered, rawDistMatAll, homeLat, homeLon, costModel) {
  if (!parse_bool(Sys.getenv("ROUTE_PLAN_ENABLE_REPAIR_PASS", unset = "true"), TRUE)) return(clustered)

  max_passes <- env_int("ROUTE_PLAN_REPAIR_MAX_PASSES", 2L)
  pass <- 0L

  while (pass < max_passes) {
    pass <- pass + 1L
    changed <- FALSE

    for (day_id in sort(unique(clustered$day))) {
      day_df <- clustered %>% filter(day == day_id)
      if (nrow(day_df) < env_int("ROUTE_PLAN_REPAIR_MIN_DAY_SIZE", 10L)) next

      day_eval <- evaluateDayCluster(day_df, clustered, rawDistMatAll, homeLat, homeLon, costModel)
      candidate_windows <- c(
        detectRepairCandidateWindows(day_eval),
        detectOutlierRepairCandidates(day_eval, clustered)
      )
      if (length(candidate_windows) == 0) next

      best_move <- NULL
      best_delta <- 0
      for (move_ids in candidate_windows) {
        targets <- repairTargetDays(clustered, move_ids, day_id)
        for (target_day in targets) {
          attempt <- evaluateRepairMove(clustered, move_ids, day_id, target_day, rawDistMatAll, homeLat, homeLon, costModel)
          if (is.null(attempt) || !isTRUE(attempt$improved)) next
          if (attempt$score_delta > best_delta) {
            best_delta <- attempt$score_delta
            best_move <- attempt
          }
        }
      }

      if (!is.null(best_move)) {
        clustered <- best_move$clustered
        changed <- TRUE
      }
    }

    if (!changed) break
  }

  renumberDays(clustered)
}

assemblePlan <- function(
  stationsDf,
  metroDf,
  homeLat = env_num("ROUTE_PLAN_HOME_LAT", default_home_lat),
  homeLon = env_num("ROUTE_PLAN_HOME_LON", default_home_lon),
  costModel = routeCostModel(),
  targetStationsPerDay = env_int("ROUTE_PLAN_TARGET_STATIONS_PER_DAY", 25L),
  targetDays = env_int("ROUTE_PLAN_TARGET_DAYS", NA_integer_)
) {
  stations_with_metro <- scoreMetroAccessibility(stationsDf, metroDf)
  clustered <- buildDayClusters(stations_with_metro, targetStationsPerDay, targetDays)
  raw_dist_mat <- computeDistanceMatrix(clustered, applyPenalties = FALSE)
  attr(raw_dist_mat, "stations") <- clustered

  clustered <- postClusterRepair(clustered, raw_dist_mat, homeLat, homeLon, costModel)
  clustered <- applyManualBoundaryFixes(clustered)
  raw_dist_mat <- computeDistanceMatrix(clustered, applyPenalties = FALSE)
  attr(raw_dist_mat, "stations") <- clustered

  route_rows <- list()
  summary_rows <- list()

  for (day_id in sort(unique(clustered$day))) {
    cluster_df <- clustered %>% filter(day == day_id)
    day_eval <- evaluateDayCluster(cluster_df, clustered, raw_dist_mat, homeLat, homeLon, costModel)
    route_rows[[as.character(day_id)]] <- day_eval$ordered
    summary_rows[[as.character(day_id)]] <- day_eval$summary
  }

  station_plan <- bind_rows(route_rows) %>%
    arrange(day, visit_order) %>%
    select(
      day,
      route_segment,
      visit_order,
      segment_visit_order,
      station_id,
      station_name,
      lat,
      lon,
      nearest_metro,
      nearest_metro_distance_m,
      nearest_metro_walk_min,
      endPointScore,
      everything()
    )

  day_summary <- bind_rows(summary_rows) %>% arrange(day)
  total_summary <- tibble(
    planned_stations = nrow(station_plan),
    planned_days = nrow(day_summary),
    total_route_distance_km = sum(day_summary$route_distance_km),
    total_route_distance_mi = sum(day_summary$route_distance_mi),
    total_estimated_bike_minutes = sum(day_summary$estimated_bike_minutes),
    total_estimated_day_minutes = sum(day_summary$estimated_total_day_minutes),
    average_stations_per_day = mean(day_summary$stations),
    smallest_day_stations = min(day_summary$stations),
    largest_day_stations = max(day_summary$stations),
    best_day_by_score = day_summary$day[which.min(day_summary$route_score)],
    worst_day_by_score = day_summary$day[which.max(day_summary$route_score)],
    weak_transit_start_count = sum(!day_summary$start_metro_access_ok, na.rm = TRUE),
    weak_transit_exit_count = sum(!day_summary$end_metro_access_ok, na.rm = TRUE),
    double_back_exit_count = sum(day_summary$end_exit_strategy %in% c("bike_to_metro_accessible_station", "bike_to_system_metro_accessible_station"), na.rm = TRUE)
  )

  list(
    station_plan = station_plan,
    day_summary = day_summary,
    total_summary = total_summary,
    weak_transit_exits = day_summary %>%
      filter(!end_metro_access_ok | !start_metro_access_ok)
  )
}

plotPlan <- function(plan, outputDir = route_output_dir) {
  if (!requireNamespace("leaflet", quietly = TRUE) || !requireNamespace("htmlwidgets", quietly = TRUE)) {
    message("Skipping maps because leaflet/htmlwidgets are not installed.")
    return(invisible(FALSE))
  }

  dir.create(outputDir, recursive = TRUE, showWarnings = FALSE)

  for (day_id in sort(unique(plan$station_plan$day))) {
    df <- plan$station_plan %>% filter(day == day_id) %>% arrange(visit_order)
    labels <- paste0(df$visit_order, ". ", df$station_name)
    map <- leaflet::leaflet(df) %>%
      leaflet::addTiles() %>%
      leaflet::addCircleMarkers(
        lng = ~lon,
        lat = ~lat,
        radius = 5,
        stroke = TRUE,
        fillOpacity = 0.8,
        label = labels
      ) %>%
      leaflet::addPolylines(lng = ~lon, lat = ~lat, weight = 3, opacity = 0.8)

    htmlwidgets::saveWidget(map, file.path(outputDir, sprintf("day_%02d_map.html", day_id)), selfcontained = TRUE)
  }

  invisible(TRUE)
}

writePlanOutputs <- function(plan, outputDir = route_output_dir) {
  dir.create(outputDir, recursive = TRUE, showWarnings = FALSE)
  write_csv(plan$station_plan, file.path(outputDir, "station_route_plan.csv"), na = "")
  write_csv(plan$day_summary, file.path(outputDir, "day_route_summary.csv"), na = "")
  write_csv(plan$total_summary, file.path(outputDir, "total_route_summary.csv"), na = "")
  write_csv(plan$weak_transit_exits, file.path(outputDir, "weak_transit_exits.csv"), na = "")
}

main <- function() {
  stations <- loadStations()
  metro <- loadMetroStations()
  plan <- assemblePlan(stations, metro)
  writePlanOutputs(plan)
  if (parse_bool(Sys.getenv("ROUTE_PLAN_WRITE_MAPS", unset = "true"), default = TRUE)) {
    plotPlan(plan)
  }

  message("Route plan written to: ", route_output_dir)
  message("Route cost model: ", routeCostModel(), if (routeCostModel() == "osrm" && !osrmAvailable()) " (fallback to haversine; ROUTE_PLAN_OSRM_URL not set)" else "")
  message("Stations planned: ", plan$total_summary$planned_stations)
  message("Days planned: ", plan$total_summary$planned_days)
  message("Total estimated route miles: ", round(plan$total_summary$total_route_distance_mi, 1))
  message("Weak transit exits: ", plan$total_summary$weak_transit_exit_count)
}

if (sys.nframe() == 0) {
  main()
}
