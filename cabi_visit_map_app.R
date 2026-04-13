library(shiny)
library(dplyr)
library(readr)
library(leaflet)

pick_inventory_file <- function() {
  candidates <- c(
    "station_inventory_scoring.csv",
    file.path("outputs", "station_inventory_with_history_match.csv")
  )
  hit <- candidates[file.exists(candidates)]
  if (length(hit) == 0) {
    stop("Missing inventory CSV. Expected one of: ", paste(candidates, collapse = ", "))
  }
  hit[[1]]
}

csv_file <- pick_inventory_file()
history_match_file <- file.path("outputs", "station_inventory_with_history_match.csv")
latest_snapshot_file <- file.path("outputs", "station_inventory_latest.csv")
route_plan_file <- file.path("outputs", "route_plan_ors", "station_route_plan.csv")
route_summary_file <- file.path("outputs", "route_plan_ors", "day_route_summary.csv")
proposed_i66_file <- file.path("data", "fairfax_i66_proposed_stations_2026_04.csv")
proposed_older_file <- file.path("data", "fairfax_older_unbuilt_proposals_2026_04.csv")
message("Using inventory file: ", csv_file)

route_source_options <- list(
  "Current Best" = list(
    key = "current_best",
    plan = file.path("outputs", "route_plan_ors", "station_route_plan.csv"),
    summary = file.path("outputs", "route_plan_ors", "day_route_summary.csv")
  ),
  "Legacy Baseline" = list(
    key = "legacy_baseline",
    plan = file.path("outputs", "route_plan", "station_route_plan.csv"),
    summary = file.path("outputs", "route_plan", "day_route_summary.csv")
  )
)

route_source_labels <- names(route_source_options)
route_source_values <- vapply(route_source_options, `[[`, character(1), "key")

resolve_route_source <- function(key) {
  matches <- route_source_options[vapply(route_source_options, function(opt) identical(opt$key, key), logical(1))]
  if (length(matches) == 0) {
    return(route_source_options[[1]])
  }
  matches[[1]]
}

to_bool <- function(x) {
  lx <- tolower(trimws(as.character(x)))
  lx %in% c("true", "t", "1", "yes", "y")
}

load_latest_snapshot <- function(path) {
  if (!file.exists(path)) {
    return(NULL)
  }

  read_csv(path, show_col_types = FALSE, progress = FALSE) %>%
    transmute(
      station_id = as.character(station_id),
      station_name = as.character(station_name),
      lat = suppressWarnings(as.numeric(lat)),
      lon = suppressWarnings(as.numeric(lon))
    ) %>%
    filter(!is.na(station_id), station_id != "")
}

merge_latest_snapshot <- function(df, snapshot_path) {
  snapshot_df <- load_latest_snapshot(snapshot_path)
  if (is.null(snapshot_df) || nrow(snapshot_df) == 0) {
    return(df)
  }

  existing_cols <- names(df)

  merged <- snapshot_df %>%
    rename(
      latest_station_name = station_name,
      latest_lat = lat,
      latest_lon = lon
    ) %>%
    left_join(
      df,
      by = "station_id"
    ) %>%
    mutate(
      station_name = coalesce(latest_station_name, station_name),
      lat = coalesce(latest_lat, lat),
      lon = coalesce(latest_lon, lon)
    ) %>%
    select(-latest_station_name, -latest_lat, -latest_lon)

  missing_from_snapshot <- df %>%
    filter(!(station_id %in% snapshot_df$station_id))

  bind_rows(merged, missing_from_snapshot) %>%
    mutate(
      station_name = as.character(station_name),
      lat = suppressWarnings(as.numeric(lat)),
      lon = suppressWarnings(as.numeric(lon))
    ) %>%
    select(any_of(existing_cols), everything()) %>%
    arrange(station_name, station_id)
}

load_inventory <- function(path) {
  if (!file.exists(path)) {
    stop("Missing file: ", path)
  }

  df <- read_csv(path, show_col_types = FALSE, progress = FALSE) %>%
    mutate(
      station_id = as.character(station_id),
      station_name = as.character(station_name),
      lat = suppressWarnings(as.numeric(lat)),
      lon = suppressWarnings(as.numeric(lon)),
      visited = if ("visited" %in% names(.)) to_bool(visited) else FALSE,
      visited_by_history = if ("visited_by_history" %in% names(.)) to_bool(visited_by_history) else FALSE,
      first_visited_date = as.character(first_visited_date),
      source = as.character(source),
      notes = as.character(notes)
    ) %>%
    mutate(
      # Keep any prior manual marks and auto-marks from history matching.
      visited = visited | visited_by_history
    )

  # If base scoring file is loaded, optionally overlay history matches.
  if (basename(path) == "station_inventory_scoring.csv" && file.exists(history_match_file)) {
    hist_df <- tryCatch(
      read_csv(history_match_file, show_col_types = FALSE, progress = FALSE) %>%
        transmute(
          station_id = as.character(station_id),
          station_name = as.character(station_name),
          visited_by_history_overlay = if ("visited_by_history" %in% names(.)) to_bool(visited_by_history) else FALSE
        ),
      error = function(e) NULL
    )
    if (!is.null(hist_df) && nrow(hist_df) > 0) {
      df <- df %>%
        left_join(hist_df, by = c("station_id", "station_name")) %>%
        mutate(
          visited_by_history = visited_by_history | if_else(is.na(visited_by_history_overlay), FALSE, visited_by_history_overlay),
          visited = visited | visited_by_history
        ) %>%
        select(-visited_by_history_overlay)
    }
  }

  if (!("address" %in% names(df))) df$address <- NA_character_
  if (!("maps_url" %in% names(df))) {
    df$maps_url <- paste0("https://maps.google.com/?q=", df$lat, ",", df$lon)
  }
  if (!("source" %in% names(df))) df$source <- NA_character_
  if (!("notes" %in% names(df))) df$notes <- NA_character_
  if (!("first_visited_date" %in% names(df))) df$first_visited_date <- NA_character_
  if (!("visited_by_history" %in% names(df))) df$visited_by_history <- FALSE
  df <- merge_latest_snapshot(df, latest_snapshot_file)
  df <- df %>%
    mutate(
      visited = coalesce(as.logical(visited), FALSE),
      visited_by_history = coalesce(as.logical(visited_by_history), FALSE),
      first_visited_date = if_else(is.na(first_visited_date), "", first_visited_date),
      source = if_else(is.na(source), "", source),
      notes = if_else(is.na(notes), "", notes)
    )

  df
}

load_route_plan <- function(path) {
  if (!file.exists(path)) {
    message("Route plan file not found: ", path)
    return(tibble())
  }

  required <- c("day", "visit_order", "station_id", "station_name", "lat", "lon")
  route_df <- read_csv(path, show_col_types = FALSE, progress = FALSE)
  missing_cols <- setdiff(required, names(route_df))
  if (length(missing_cols) > 0) {
    message("Route plan ignored. Missing columns in ", path, ": ", paste(missing_cols, collapse = ", "))
    return(tibble())
  }

  route_df %>%
    transmute(
      day = suppressWarnings(as.integer(day)),
      visit_order = suppressWarnings(as.integer(visit_order)),
      station_id = as.character(station_id),
      station_name = as.character(station_name),
      lat = suppressWarnings(as.numeric(lat)),
      lon = suppressWarnings(as.numeric(lon)),
      nearest_metro = if ("nearest_metro" %in% names(route_df)) as.character(nearest_metro) else NA_character_,
      nearest_metro_distance_m = if ("nearest_metro_distance_m" %in% names(route_df)) suppressWarnings(as.numeric(nearest_metro_distance_m)) else NA_real_
    ) %>%
    filter(!is.na(day), !is.na(visit_order), !is.na(lat), !is.na(lon)) %>%
    arrange(day, visit_order)
}

load_route_summary <- function(path) {
  if (!file.exists(path)) {
    return(tibble())
  }

  read_csv(path, show_col_types = FALSE, progress = FALSE) %>%
    mutate(day = suppressWarnings(as.integer(day)))
}

load_proposed_stations <- function(path) {
  if (!file.exists(path)) {
    message("Proposed station overlay file not found: ", path)
    return(tibble())
  }

  read_csv(path, show_col_types = FALSE, progress = FALSE) %>%
    transmute(
      proposal_id = as.character(proposal_id),
      station_name = as.character(station_name),
      presentation_name = if ("presentation_name" %in% names(.)) as.character(presentation_name) else NA_character_,
      planning_area = if ("planning_area" %in% names(.)) as.character(planning_area) else NA_character_,
      district = as.character(district),
      lat = suppressWarnings(as.numeric(lat)),
      lon = suppressWarnings(as.numeric(lon)),
      source = as.character(source),
      notes = as.character(notes)
    ) %>%
    filter(!is.na(lat), !is.na(lon), !is.na(station_name), station_name != "")
}

save_inventory <- function(df, path) {
  write_csv(df, path, na = "")
}

popup_html <- function(df_row) {
  nm <- ifelse(is.na(df_row$station_name), "", df_row$station_name)
  addr <- ifelse(is.na(df_row$address) || df_row$address == "", "No address in feed", df_row$address)
  status <- ifelse(isTRUE(df_row$visited), "Visited", "Not visited")
  paste0(
    "<b>", htmltools::htmlEscape(nm), "</b><br/>",
    htmltools::htmlEscape(addr), "<br/>",
    "Status: <b>", status, "</b><br/>",
    "<small>Tap marker to toggle</small>"
  )
}

add_popup_text <- function(df) {
  df %>%
    mutate(
      popup_text = mapply(
        FUN = function(station_name, address, visited) {
          popup_html(
            list(
              station_name = station_name,
              address = address,
              visited = visited
            )
          )
        },
        station_name,
        address,
        visited,
        SIMPLIFY = TRUE,
        USE.NAMES = FALSE
      )
    )
}

add_proposed_popup_text <- function(df) {
  df %>%
    mutate(
      popup_text = paste0(
        "<b>", htmltools::htmlEscape(station_name), "</b><br/>",
        "Proposal: <b>Fairfax I-66 corridor</b><br/>",
        ifelse(
          is.na(presentation_name) | presentation_name == "" | presentation_name == station_name,
          "",
          paste0("Presentation label: ", htmltools::htmlEscape(presentation_name), "<br/>")
        ),
        ifelse(is.na(planning_area) | planning_area == "", "", paste0("Area: ", htmltools::htmlEscape(planning_area), "<br/>")),
        ifelse(is.na(district) | district == "", "", paste0("District: ", htmltools::htmlEscape(district), "<br/>")),
        ifelse(is.na(notes) | notes == "", "", paste0("<small>", htmltools::htmlEscape(notes), "</small><br/>")),
        ifelse(is.na(source) | source == "", "", paste0("<small>", htmltools::htmlEscape(source), "</small>"))
      )
    )
}

central_potomac_side <- function(lat, lon) {
  dplyr::case_when(
    lat > 38.901 & lat < 38.92 & lon > -77.10 & lon < -77.055 ~ "dc",
    lat > 38.89 & lat <= 38.901 & lon > -77.061 & lon < -77.052 ~ "dc",
    lat > 38.875 & lat <= 38.901 & lon < -77.061 ~ "va",
    lat > 38.84 & lat <= 38.875 & lon < -77.035 ~ "va",
    lat > 38.84 & lat < 38.92 & lon >= -77.061 ~ "dc",
    TRUE ~ "other"
  )
}

orient_waypoints <- function(waypoints, from_lat, from_lon) {
  if (is.null(waypoints) || nrow(waypoints) <= 1) return(waypoints)

  first_dist <- (waypoints$lat[1] - from_lat)^2 + (waypoints$lon[1] - from_lon)^2
  last_dist <- (waypoints$lat[nrow(waypoints)] - from_lat)^2 + (waypoints$lon[nrow(waypoints)] - from_lon)^2
  if (last_dist < first_dist) {
    return(waypoints[nrow(waypoints):1, ])
  }
  waypoints
}

bridge_waypoints <- function(from_lat, from_lon, to_lat, to_lon) {
  from_side <- central_potomac_side(from_lat, from_lon)
  to_side <- central_potomac_side(to_lat, to_lon)
  if (from_side == to_side || "other" %in% c(from_side, to_side)) {
    return(NULL)
  }

  avg_lat <- mean(c(from_lat, to_lat))
  avg_lon <- mean(c(from_lon, to_lon))

  if (avg_lat >= 38.898) {
    # Key Bridge corridor between Georgetown and Rosslyn.
    return(orient_waypoints(
      tibble(lat = c(38.9027, 38.8995), lon = c(-77.0699, -77.0756)),
      from_lat,
      from_lon
    ))
  }
  if (avg_lat >= 38.884 && avg_lon < -77.058) {
    # Arlington Memorial Bridge corridor.
    return(orient_waypoints(
      tibble(lat = c(38.8879, 38.8874), lon = c(-77.0528, -77.0648)),
      from_lat,
      from_lon
    ))
  }

  # 14th Street Bridge / Mount Vernon Trail corridor.
  orient_waypoints(
    tibble(lat = c(38.8762, 38.8708), lon = c(-77.0356, -77.0446)),
    from_lat,
    from_lon
  )
}

route_display_points <- function(route_df) {
  if (nrow(route_df) <= 1) return(route_df)

  pieces <- vector("list", nrow(route_df) * 2)
  out_idx <- 1
  for (i in seq_len(nrow(route_df) - 1)) {
    pieces[[out_idx]] <- route_df[i, ]
    out_idx <- out_idx + 1

    waypoints <- bridge_waypoints(route_df$lat[i], route_df$lon[i], route_df$lat[i + 1], route_df$lon[i + 1])
    if (!is.null(waypoints)) {
      pieces[[out_idx]] <- tibble(
        day = route_df$day[i],
        visit_order = route_df$visit_order[i] + seq_len(nrow(waypoints)) / 10,
        station_id = paste0(route_df$station_id[i], "_bridge_", seq_len(nrow(waypoints))),
        station_name = "Bridge display waypoint",
        lat = waypoints$lat,
        lon = waypoints$lon,
        nearest_metro = NA_character_,
        nearest_metro_distance_m = NA_real_
      )
      out_idx <- out_idx + 1
    }
  }
  pieces[[out_idx]] <- route_df[nrow(route_df), ]

  bind_rows(pieces[seq_len(out_idx)]) %>%
    arrange(day, visit_order)
}

route_segment_crosses_central_potomac <- function(route_df) {
  if (nrow(route_df) <= 1) return(FALSE)
  sides <- central_potomac_side(route_df$lat, route_df$lon)
  any(sides[-length(sides)] != sides[-1] & sides[-length(sides)] != "other" & sides[-1] != "other")
}

ui <- fluidPage(
  tags$head(
    tags$meta(name = "viewport", content = "width=device-width, initial-scale=1"),
    tags$style(HTML("
      html, body { height: 100%; }
      #map { height: calc(100vh - 220px) !important; min-height: 460px; }
      .small-note { color: #555; font-size: 12px; }
    "))
  ),
  titlePanel("Capital Bikeshare Visit Tracker"),
  fluidRow(
    column(
      width = 12,
      div(
        class = "small-note",
        "Tap a station circle to toggle visited: white = not visited, black = visited. Proposed Fairfax I-66 stations render separately in red."
      )
    )
  ),
  fluidRow(
    column(
      width = 3,
      radioButtons(
        "view_filter",
        "Show",
        choices = c("All", "Unvisited only", "Visited only"),
        selected = "All",
        inline = FALSE
      ),
      checkboxInput("autosave", "Autosave after each click", value = TRUE),
      actionButton("save_btn", "Save now"),
      actionButton("reload_btn", "Reload CSV"),
      br(), br(),
      textOutput("counts_txt"),
      br(),
      selectizeInput("jump_station", "Jump to station", choices = NULL, selected = NULL),
      hr(),
      selectInput(
        "route_source",
        "Route source",
        choices = setNames(route_source_values, route_source_labels),
        selected = route_source_options[[1]]$key
      ),
      checkboxInput("show_i66_proposed", "Overlay proposed Fairfax I-66 stations", value = TRUE),
      checkboxInput("show_older_proposed", "Overlay older Fairfax proposals not yet built", value = FALSE),
      checkboxInput("show_route", "Overlay suggested route", value = FALSE),
      selectInput("route_day", "Route day", choices = character(0), selected = NULL),
      textOutput("route_day_txt"),
      checkboxInput("show_all_routes", "Overlay all route days", value = FALSE)
    ),
    column(
      width = 9,
      leafletOutput("map")
    )
  )
)

server <- function(input, output, session) {
  rv <- reactiveValues(
    stations = load_inventory(csv_file),
    route_plan = load_route_plan(route_plan_file),
    route_summary = load_route_summary(route_summary_file),
    proposed_stations = load_proposed_stations(proposed_i66_file),
    proposed_older_stations = load_proposed_stations(proposed_older_file),
    route_source_label = route_source_labels[[1]],
    dirty = FALSE
  )

  backup_file <- paste0(
    tools::file_path_sans_ext(csv_file),
    "_backup_",
    format(Sys.time(), "%Y%m%d_%H%M%S"),
    ".csv"
  )
  file.copy(csv_file, backup_file, overwrite = FALSE)

  filtered_stations <- reactive({
    req(rv$stations)
    df <- rv$stations %>% filter(!is.na(lat), !is.na(lon))
    if (input$view_filter == "Unvisited only") df <- df %>% filter(!visited)
    if (input$view_filter == "Visited only") df <- df %>% filter(visited)
    add_popup_text(df)
  })

  proposed_stations <- reactive({
    req(rv$proposed_stations)
    add_proposed_popup_text(rv$proposed_stations)
  })

  proposed_older_stations <- reactive({
    req(rv$proposed_older_stations)
    add_proposed_popup_text(rv$proposed_older_stations)
  })

  observe({
    all_names <- rv$stations %>%
      arrange(station_name) %>%
      mutate(label = station_name)
    updateSelectizeInput(
      session,
      "jump_station",
      choices = setNames(all_names$station_id, all_names$label),
      selected = character(0),
      server = TRUE
    )
  })

  observe({
    route_source_key <- input$route_source
    if (is.null(route_source_key) || identical(route_source_key, "")) {
      route_source_key <- route_source_options[[1]]$key
    }
    src <- resolve_route_source(route_source_key)
    rv$route_plan <- load_route_plan(src$plan)
    rv$route_summary <- load_route_summary(src$summary)
    rv$route_source_label <- route_source_labels[match(src$key, route_source_values)]
    if (length(rv$route_source_label) == 0 || is.na(rv$route_source_label)) {
      rv$route_source_label <- route_source_labels[[1]]
    }
  })

  observe({
    if (nrow(rv$route_plan) == 0) {
      updateSelectInput(session, "route_day", choices = character(0), selected = character(0))
      return()
    }

    route_days <- sort(unique(rv$route_plan$day))
    labels <- vapply(route_days, function(day_id) {
      summary_row <- rv$route_summary %>% filter(day == day_id)
      if (nrow(summary_row) == 1) {
        total_hours <- if ("estimated_total_day_minutes" %in% names(summary_row) && !is.na(summary_row$estimated_total_day_minutes)) {
          paste0(", ", round(summary_row$estimated_total_day_minutes / 60, 1), " hr total")
        } else {
          ""
        }
        paste0(
          "Day ", day_id,
          " (", summary_row$stations, " stations, ",
          round(summary_row$route_distance_mi, 1), " mi, starts ",
          summary_row$start_station_name, total_hours, ")"
        )
      } else {
        paste0("Day ", day_id)
      }
    }, character(1))

    updateSelectInput(
      session,
      "route_day",
      choices = setNames(route_days, labels),
      selected = route_days[[1]]
    )
  })

  output$counts_txt <- renderText({
    total <- nrow(rv$stations)
    visited_n <- sum(rv$stations$visited, na.rm = TRUE)
    unvisited_n <- total - visited_n
    paste0("Visited: ", visited_n, " / ", total, " | Unvisited: ", unvisited_n)
  })

  selected_route <- reactive({
    if (nrow(rv$route_plan) == 0) return(tibble())
    req(input$route_day)
    rv$route_plan %>%
      filter(day == as.integer(input$route_day)) %>%
      arrange(visit_order)
  })

  observeEvent(input$route_day, {
    if (!is.null(input$route_day) && input$route_day != "" && !isTRUE(input$show_all_routes)) {
      updateCheckboxInput(session, "show_route", value = TRUE)
    }
  }, ignoreInit = TRUE)

  observeEvent(input$show_all_routes, {
    if (isTRUE(input$show_all_routes)) {
      updateCheckboxInput(session, "show_route", value = FALSE)
    }
  }, ignoreInit = TRUE)

  route_color <- function(day_id) {
    palette <- c(
      "#E67E22", "#2E86AB", "#6A4C93", "#2CA25F", "#C0392B",
      "#F1C40F", "#1ABC9C", "#8E44AD", "#D35400", "#34495E",
      "#7D3C98", "#16A085", "#B03A2E", "#2874A6", "#AF7AC5",
      "#239B56", "#CA6F1E", "#566573", "#D68910", "#117A65",
      "#CB4335", "#5DADE2", "#58D68D", "#F4D03F"
    )
    palette[((as.integer(day_id) - 1L) %% length(palette)) + 1L]
  }

  output$route_day_txt <- renderText({
    if (nrow(rv$route_plan) == 0) {
      return(paste0("No route plan found for ", rv$route_source_label, "."))
    }
    if (!isTRUE(input$show_route) || is.null(input$route_day) || input$route_day == "") {
      return(paste0(rv$route_source_label, ": route overlay is off."))
    }

    summary_row <- rv$route_summary %>% filter(day == as.integer(input$route_day))
    if (nrow(summary_row) != 1) {
      return(paste0("Day ", input$route_day, " selected."))
    }

    start_access_txt <- if (
      "nearest_metro_at_start" %in% names(summary_row) &&
        !is.na(summary_row$nearest_metro_at_start) &&
        summary_row$nearest_metro_at_start != ""
    ) {
      paste0(
        " near ", summary_row$nearest_metro_at_start,
        ifelse(
          "start_to_metro_walk_min" %in% names(summary_row) &&
            !is.na(summary_row$start_to_metro_walk_min),
          paste0(" (", round(summary_row$start_to_metro_walk_min, 1), " min walk)"),
          ""
        ),
        ifelse(
          "start_metro_access_ok" %in% names(summary_row) &&
            !isTRUE(summary_row$start_metro_access_ok),
          " [over 30 min cap]",
          ""
        )
      )
    } else {
      ""
    }

    end_access_txt <- if (
      !is.na(summary_row$nearest_metro_at_end) &&
        summary_row$nearest_metro_at_end != ""
    ) {
      paste0(
        " near ", summary_row$nearest_metro_at_end,
        ifelse(
          !is.na(summary_row$end_to_metro_walk_min),
          paste0(" (", round(summary_row$end_to_metro_walk_min, 1), " min walk)"),
          ""
        ),
        ifelse(
          "end_exit_strategy" %in% names(summary_row) &&
            summary_row$end_exit_strategy %in% c("bike_to_metro_accessible_station", "bike_to_system_metro_accessible_station"),
          paste0("; bike back via ", summary_row$exit_via_station_name),
          ""
        ),
        ifelse(
          "end_metro_access_ok" %in% names(summary_row) &&
            !isTRUE(summary_row$end_metro_access_ok),
          " [over 30 min cap]",
          ""
        )
      )
    } else {
      ""
    }

    paste0(
      "Day ", summary_row$day,
      ": ", summary_row$stations, " stations, ",
      round(summary_row$route_distance_mi, 1), " mi. Start: ",
      summary_row$start_station_name,
      start_access_txt,
      ". End: ",
      summary_row$end_station_name,
      end_access_txt,
      ifelse(
        "estimated_total_day_minutes" %in% names(summary_row) && !is.na(summary_row$estimated_total_day_minutes),
        paste0(
          ". Estimated time: ",
          round(summary_row$estimated_bike_minutes),
          " min riding + ",
          round(summary_row$total_access_overhead_min_est),
          " min access = ",
          round(summary_row$estimated_total_day_minutes),
          " min total"
        ),
        "."
      ),
      ifelse(
        "route_cost_model" %in% names(summary_row) && !is.na(summary_row$route_cost_model),
        paste0(" [", summary_row$route_cost_model, "]"),
        ""
      ),
      ". Source: ", rv$route_source_label, "."
    )
  })

  output$map <- renderLeaflet({
    leaflet() %>%
      addProviderTiles(providers$CartoDB.Positron) %>%
      setView(lng = -77.04, lat = 38.91, zoom = 11) %>%
      addLegend(
        position = "bottomright",
        colors = c("#FFFFFF", "#000000"),
        labels = c("Not visited", "Visited"),
        opacity = 1,
        title = "Status"
      ) %>%
      addLegend(
        position = "bottomright",
        colors = c("#D73027", "#B2182B"),
        labels = c("Proposed Fairfax I-66 station", "Older Fairfax proposal not yet built"),
        opacity = 1,
        title = "Overlay"
      )
  })

  observe({
    df <- filtered_stations()
    proxy <- leafletProxy("map", data = df) %>%
      clearGroup("stations")

    if (nrow(df) == 0) {
      return()
    }

    proxy %>%
      addCircleMarkers(
        lng = ~lon,
        lat = ~lat,
        group = "stations",
        layerId = ~station_id,
        radius = 7,
        stroke = TRUE,
        color = "#222222",
        weight = 1.5,
        fillOpacity = 1,
        fillColor = ~ifelse(visited, "#000000", "#FFFFFF"),
        popup = ~popup_text,
        label = ~station_name
      )
  })

  observe({
    proxy <- leafletProxy("map") %>%
      clearGroup("proposed_i66")

    if (!isTRUE(input$show_i66_proposed)) return()

    df <- proposed_stations()
    if (nrow(df) == 0) return()

    proxy %>%
      addCircleMarkers(
        data = df,
        lng = ~lon,
        lat = ~lat,
        group = "proposed_i66",
        layerId = ~paste0("proposed:", proposal_id),
        radius = 7,
        stroke = TRUE,
        color = "#8B0000",
        weight = 2,
        fillOpacity = 0.95,
        fillColor = "#D73027",
        popup = ~popup_text,
        label = ~station_name
      )
  })

  observe({
    proxy <- leafletProxy("map") %>%
      clearGroup("proposed_older")

    if (!isTRUE(input$show_older_proposed)) return()

    df <- proposed_older_stations()
    if (nrow(df) == 0) return()

    proxy %>%
      addCircleMarkers(
        data = df,
        lng = ~lon,
        lat = ~lat,
        group = "proposed_older",
        layerId = ~paste0("older:", proposal_id),
        radius = 7,
        stroke = TRUE,
        color = "#6A1B1A",
        weight = 2,
        fillOpacity = 0.85,
        fillColor = "#B2182B",
        popup = ~popup_text,
        label = ~station_name
      )
  })

  observe({
    proxy <- leafletProxy("map") %>%
      clearGroup("route_path") %>%
      clearGroup("route_stops")

    if (!isTRUE(input$show_route)) return()

    route_df <- selected_route()
    if (nrow(route_df) == 0) return()
    route_line_df <- route_display_points(route_df)

    route_labels <- paste0(
      route_df$visit_order,
      ". ",
      route_df$station_name,
      ifelse(
        !is.na(route_df$nearest_metro) & route_df$nearest_metro != "",
        paste0("<br/>Nearest Metro: ", htmltools::htmlEscape(route_df$nearest_metro)),
        ""
      )
    )

    proxy %>%
      addPolylines(
        data = route_line_df,
        lng = ~lon,
        lat = ~lat,
        group = "route_path",
        color = "#E67E22",
        weight = 4,
        opacity = 0.9
      ) %>%
      addCircleMarkers(
        data = route_df,
        lng = ~lon,
        lat = ~lat,
        group = "route_stops",
        layerId = ~paste0("route:", station_id),
        radius = 5,
        stroke = TRUE,
        color = "#E67E22",
        weight = 2,
        fillColor = "#FDEBD0",
        fillOpacity = 0.9,
        label = ~paste0(visit_order, ". ", station_name),
        popup = route_labels
      ) %>%
      fitBounds(
        lng1 = min(route_df$lon, na.rm = TRUE),
        lat1 = min(route_df$lat, na.rm = TRUE),
        lng2 = max(route_df$lon, na.rm = TRUE),
        lat2 = max(route_df$lat, na.rm = TRUE)
      )
  })

  observe({
    proxy <- leafletProxy("map") %>%
      clearGroup("all_route_paths") %>%
      clearGroup("all_route_endpoints")

    if (!isTRUE(input$show_all_routes) || nrow(rv$route_plan) == 0) return()

    all_routes <- rv$route_plan %>% arrange(day, visit_order)
    for (day_id in sort(unique(all_routes$day))) {
      route_df <- all_routes %>% filter(day == day_id) %>% arrange(visit_order)
      if (nrow(route_df) < 2) next
      route_line_df <- route_display_points(route_df)

      color <- route_color(day_id)
      day_summary <- rv$route_summary %>% filter(day == day_id)
      line_label <- if (nrow(day_summary) == 1) {
        paste0(
          "Day ", day_id,
          ": ", day_summary$stations, " stations, ",
          round(day_summary$route_distance_mi, 1), " mi"
        )
      } else {
        paste0("Day ", day_id)
      }

      endpoint_df <- bind_rows(route_df[1, ], route_df[nrow(route_df), ]) %>%
        mutate(endpoint_label = c(
          paste0("Day ", day_id, " start: ", route_df$station_name[1]),
          paste0("Day ", day_id, " end: ", route_df$station_name[nrow(route_df)])
        ))

      proxy <- proxy %>%
        addPolylines(
          data = route_line_df,
          lng = ~lon,
          lat = ~lat,
          group = "all_route_paths",
          color = color,
          weight = 3,
          opacity = 0.75,
          label = line_label
        ) %>%
        addCircleMarkers(
          data = endpoint_df,
          lng = ~lon,
          lat = ~lat,
          group = "all_route_endpoints",
          radius = 4,
          stroke = TRUE,
          color = color,
          weight = 2,
          fillColor = "#FFFFFF",
          fillOpacity = 0.9,
          label = ~endpoint_label
        )
    }

    proxy %>%
      fitBounds(
        lng1 = min(all_routes$lon, na.rm = TRUE),
        lat1 = min(all_routes$lat, na.rm = TRUE),
        lng2 = max(all_routes$lon, na.rm = TRUE),
        lat2 = max(all_routes$lat, na.rm = TRUE)
      )
  })

  observeEvent(input$map_marker_click, {
    click <- input$map_marker_click
    req(click$id)

    idx <- which(rv$stations$station_id == click$id)
    if (length(idx) != 1) return()

    rv$stations$visited[idx] <- !isTRUE(rv$stations$visited[idx])
    if (isTRUE(rv$stations$visited[idx])) {
      if (is.na(rv$stations$first_visited_date[idx]) || rv$stations$first_visited_date[idx] == "" || rv$stations$first_visited_date[idx] == "NA") {
        rv$stations$first_visited_date[idx] <- as.character(Sys.Date())
      }
      if (is.na(rv$stations$source[idx]) || rv$stations$source[idx] == "") {
        rv$stations$source[idx] <- "map_click"
      }
    }

    rv$dirty <- TRUE

    if (isTRUE(input$autosave)) {
      save_inventory(rv$stations, csv_file)
      rv$dirty <- FALSE
      showNotification("Saved", type = "message", duration = 1)
    }
  })

  observeEvent(input$save_btn, {
    save_inventory(rv$stations, csv_file)
    rv$dirty <- FALSE
    showNotification("CSV saved", type = "message", duration = 2)
  })

  observeEvent(input$reload_btn, {
    rv$stations <- load_inventory(csv_file)
    rv$dirty <- FALSE
    showNotification("Reloaded from CSV", type = "message", duration = 2)
  })

  observeEvent(input$jump_station, {
    sid <- input$jump_station
    req(sid)
    row <- rv$stations %>% filter(station_id == sid)
    if (nrow(row) != 1 || is.na(row$lat[1]) || is.na(row$lon[1])) return()
    leafletProxy("map") %>%
      setView(lng = row$lon[1], lat = row$lat[1], zoom = 15) %>%
      addPopups(
        lng = row$lon[1],
        lat = row$lat[1],
        popup = popup_html(row[1, ])
      )
  })

  session$onSessionEnded(function() {
    if (isolate(rv$dirty)) {
      save_inventory(isolate(rv$stations), csv_file)
    }
  })
}

shinyApp(ui, server)
