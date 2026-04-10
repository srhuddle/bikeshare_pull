#!/usr/bin/env Rscript

# Build a unique list of visited station names from scraped ride history.
# This keeps stations even if they no longer exist in current inventory.

input_file <- "cabi_ride_history_all.csv"
output_dir <- "outputs"
unique_output_file <- file.path(output_dir, "visited_station_names_unique.csv")
summary_output_file <- file.path(output_dir, "visited_station_names_summary.csv")

normalize_station <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  x <- gsub("\u00A0", " ", x, fixed = TRUE)  # non-breaking spaces
  x <- trimws(gsub("\\s+", " ", x))
  x
}

safe_min_date <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0L) as.Date(NA) else min(x)
}

safe_max_date <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0L) as.Date(NA) else max(x)
}

if (!file.exists(input_file)) {
  stop("Missing input file: ", input_file, call. = FALSE)
}
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

rides <- read.csv(input_file, stringsAsFactors = FALSE)
needed <- c("ride_date", "start_station", "end_station")
missing <- setdiff(needed, names(rides))
if (length(missing) > 0L) {
  stop("Input is missing required columns: ", paste(missing, collapse = ", "), call. = FALSE)
}

ride_dates <- as.Date(rides$ride_date, format = "%B %d, %Y")

starts <- data.frame(
  station_name = normalize_station(rides$start_station),
  leg_type = "start",
  ride_date = ride_dates,
  stringsAsFactors = FALSE
)
ends <- data.frame(
  station_name = normalize_station(rides$end_station),
  leg_type = "end",
  ride_date = ride_dates,
  stringsAsFactors = FALSE
)

long <- rbind(starts, ends)
long <- long[long$station_name != "", , drop = FALSE]
if (nrow(long) == 0L) {
  stop("No non-empty station names found in ride history.", call. = FALSE)
}

# Unique station list requested.
unique_stations <- sort(unique(long$station_name))
write.csv(
  data.frame(station_name = unique_stations, stringsAsFactors = FALSE),
  unique_output_file,
  row.names = FALSE,
  na = ""
)

# Optional summary for downstream checks.
touches <- aggregate(
  rep.int(1L, nrow(long)),
  by = list(station_name = long$station_name),
  FUN = sum
)
names(touches)[2] <- "total_touches"

starts_only <- long[long$leg_type == "start", , drop = FALSE]
ends_only <- long[long$leg_type == "end", , drop = FALSE]
start_counts <- aggregate(rep.int(1L, nrow(starts_only)), by = list(station_name = starts_only$station_name), FUN = sum)
end_counts <- aggregate(rep.int(1L, nrow(ends_only)), by = list(station_name = ends_only$station_name), FUN = sum)
names(start_counts)[2] <- "starts"
names(end_counts)[2] <- "ends"

first_seen <- aggregate(long$ride_date, by = list(station_name = long$station_name), FUN = safe_min_date)
last_seen <- aggregate(long$ride_date, by = list(station_name = long$station_name), FUN = safe_max_date)
names(first_seen)[2] <- "first_seen_date"
names(last_seen)[2] <- "last_seen_date"

summary_df <- Reduce(
  function(x, y) merge(x, y, by = "station_name", all = TRUE),
  list(touches, start_counts, end_counts, first_seen, last_seen)
)
summary_df <- summary_df[order(summary_df$station_name), ]

write.csv(summary_df, summary_output_file, row.names = FALSE, na = "")

message("Unique stations: ", length(unique_stations))
message("Unique list: ", file.path(getwd(), unique_output_file))
message("Summary: ", file.path(getwd(), summary_output_file))
