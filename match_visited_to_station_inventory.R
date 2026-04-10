#!/usr/bin/env Rscript

# Match visited station names from ride history to current station inventory.
# Produces:
# - inventory with visited_by_history flag
# - unvisited current stations
# - visited names not found in current inventory (retired stations / e-bike drop-anywhere addresses)

inventory_file <- "station_inventory_scoring.csv"
output_dir <- "outputs"
visited_file <- file.path(output_dir, "visited_station_names_unique.csv")

out_inventory_match <- file.path(output_dir, "station_inventory_with_history_match.csv")
out_unvisited <- file.path(output_dir, "station_inventory_unvisited_by_history.csv")
out_unvisited_effective <- file.path(output_dir, "station_inventory_unvisited_effective.csv")
out_visited_not_in_inventory <- file.path(output_dir, "visited_names_not_in_current_inventory.csv")

normalize_name <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  x <- gsub("\u00A0", " ", x, fixed = TRUE)
  x <- tolower(x)
  x <- gsub("&", " and ", x, fixed = TRUE)
  x <- gsub("[^a-z0-9]+", " ", x)
  x <- trimws(gsub("\\s+", " ", x))
  x
}

if (!file.exists(inventory_file)) {
  stop("Missing inventory file: ", inventory_file, call. = FALSE)
}
if (!file.exists(visited_file)) {
  stop("Missing visited file: ", visited_file, call. = FALSE)
}
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

inv <- read.csv(inventory_file, stringsAsFactors = FALSE)
vis <- read.csv(visited_file, stringsAsFactors = FALSE)

if (!("station_name" %in% names(inv))) {
  stop("Inventory file must include station_name column.", call. = FALSE)
}
if (!("station_name" %in% names(vis))) {
  stop("Visited file must include station_name column.", call. = FALSE)
}

inv$station_name <- as.character(inv$station_name)
vis$station_name <- as.character(vis$station_name)

inv$station_name_norm <- normalize_name(inv$station_name)
vis$station_name_norm <- normalize_name(vis$station_name)

vis_nonempty <- unique(vis[vis$station_name_norm != "", c("station_name", "station_name_norm"), drop = FALSE])
inv_nonempty <- inv[inv$station_name_norm != "", , drop = FALSE]

exact_set <- unique(vis_nonempty$station_name)
norm_set <- unique(vis_nonempty$station_name_norm)

inv$visited_by_history_exact <- inv$station_name %in% exact_set
inv$visited_by_history_norm <- inv$station_name_norm %in% norm_set
inv$visited_by_history <- inv$visited_by_history_exact | inv$visited_by_history_norm
manual_visited <- if ("visited" %in% names(inv)) as.logical(inv$visited) else FALSE
manual_visited[is.na(manual_visited)] <- FALSE
inv$visited_effective <- manual_visited | inv$visited_by_history

write.csv(inv, out_inventory_match, row.names = FALSE, na = "")

unvisited <- inv[!inv$visited_by_history, , drop = FALSE]
unvisited <- unvisited[order(unvisited$station_name), , drop = FALSE]
write.csv(unvisited, out_unvisited, row.names = FALSE, na = "")

unvisited_effective <- inv[!inv$visited_effective, , drop = FALSE]
unvisited_effective <- unvisited_effective[order(unvisited_effective$station_name), , drop = FALSE]
write.csv(unvisited_effective, out_unvisited_effective, row.names = FALSE, na = "")

visited_not_in_inventory <- vis_nonempty[!(vis_nonempty$station_name_norm %in% unique(inv_nonempty$station_name_norm)), , drop = FALSE]
visited_not_in_inventory <- visited_not_in_inventory[order(visited_not_in_inventory$station_name), , drop = FALSE]
write.csv(visited_not_in_inventory, out_visited_not_in_inventory, row.names = FALSE, na = "")

message("Current inventory stations: ", nrow(inv))
message("Visited matches in current inventory: ", sum(inv$visited_by_history, na.rm = TRUE))
message("Unvisited current stations: ", nrow(unvisited))
message("Unvisited effective (manual OR history): ", nrow(unvisited_effective))
message("Visited names not in current inventory: ", nrow(visited_not_in_inventory))
message("Wrote: ", file.path(getwd(), out_inventory_match))
message("Wrote: ", file.path(getwd(), out_unvisited))
message("Wrote: ", file.path(getwd(), out_unvisited_effective))
message("Wrote: ", file.path(getwd(), out_visited_not_in_inventory))
