#!/usr/bin/env Rscript

# Milestone 2 Playwright launcher using reticulate + Python playwright.
# Goal:
# - Use local .venv Playwright install
# - Launch visible Chromium and navigate to CaBi ride history
# - Pause for manual login/MFA
# - Click first 20 "Expand for more details" buttons
# - Parse date/start/end fields and print them

need_pkg <- function(pkg) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    stop("Missing package: ", pkg, ". Install with install.packages('", pkg, "')", call. = FALSE)
  }
}

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

need_pkg("reticulate")

venv_python <- file.path(getwd(), ".venv", "bin", "python")
if (!file.exists(venv_python)) {
  stop("Could not find .venv python at: ", venv_python, call. = FALSE)
}

reticulate::use_python(venv_python, required = TRUE)

if (!reticulate::py_module_available("playwright.sync_api")) {
  stop(
    "Python module playwright.sync_api not available in .venv.\n",
    "Run:\n",
    "  source .venv/bin/activate\n",
    "  pip install playwright\n",
    "  python -m playwright install chromium",
    call. = FALSE
  )
}

playwright <- reticulate::import("playwright.sync_api")
ride_history_url <- "https://account.capitalbikeshare.com/ride-history"
profile_dir <- file.path(getwd(), ".pw_cabi_profile_py")
# Extraction controls
start_index <- 10L        # 0-based parsed-ride offset (used if no checkpoint resume)
target_rides <- 100L      # chunk size per iteration
run_until_exhausted <- TRUE
resume_from_checkpoint <- TRUE
checkpoint_file <- "cabi_ride_history_checkpoint.txt"
combined_output_file <- "cabi_ride_history_all.csv"
write_chunk_files <- FALSE
max_chunks <- NA_integer_ # set e.g. 5L for capped test runs
log_every <- 50L
dir.create(profile_dir, recursive = TRUE, showWarnings = FALSE)

message("Starting Playwright...")
pw <- playwright$sync_playwright()$start()
on.exit(try(pw$stop(), silent = TRUE), add = TRUE)

message("Launching Chromium persistent context (headless = FALSE)...")
context <- pw$chromium$launch_persistent_context(
  user_data_dir = profile_dir,
  headless = FALSE
)
on.exit(try(context$close(), silent = TRUE), add = TRUE)

pages <- context$pages
page <- if (length(pages) > 0) pages[[1]] else context$new_page()

message("Navigating to ride history...")
page$goto(ride_history_url, wait_until = "domcontentloaded")

message("\nManual step:")
message("1) Complete login + MFA in the opened Chromium window.")
message("2) Keep ride-history page open.")
invisible(readline(prompt = "Press Enter here when done: "))

current_url <- tryCatch(page$url, error = function(e) NA_character_)
initial_button_count <- tryCatch(
  as.integer(page$locator("button[aria-label='Expand for more details']")$count()),
  error = function(e) NA_integer_
)

message("Current URL: ", current_url)
message("Expand buttons initially detected: ", initial_button_count)

if (is.na(initial_button_count) || initial_button_count <= 0) {
  stop("No expand buttons found. Ensure you are on ride-history and logged in.", call. = FALSE)
}

if (is.na(start_index) || start_index < 0) start_index <- 0L

click_show_more_js <- "
() => {
  const norm = (s) => (s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
  const candidates = Array.from(
    document.querySelectorAll('button, [role=\"button\"], a, div[tabindex]')
  );
  const btn = candidates.find(el => {
    const t = norm(el.innerText);
    const aria = norm(el.getAttribute && el.getAttribute('aria-label'));
    return (
      t.includes('show more') ||
      t.includes('load more') ||
      t.includes('more rides') ||
      aria.includes('show more') ||
      aria.includes('load more')
    );
  });
  if (!btn) return false;
  btn.scrollIntoView({ block: 'center' });
  btn.click();
  return true;
}
"

extract_js <- "
beforeKeys => {
  const splitLines = (txt) => (txt || '').split('\\n').map(s => s.trim()).filter(Boolean);
  const monthLineRe = /^(January|February|March|April|May|June|July|August|September|October|November|December)\\s+\\d{1,2},\\s+\\d{4}$/;

  const blocks = Array.from(document.querySelectorAll('body *'))
    .filter(el => {
      const t = (el.innerText || '').trim();
      return t.includes('YOUR TRIP') && t.includes('Started at') && t.includes('Ended at');
    })
    .filter(el => {
      return !Array.from(el.querySelectorAll('*')).some(child => {
        if (child === el) return false;
        const t = (child.innerText || '').trim();
        return t.includes('YOUR TRIP') && t.includes('Started at') && t.includes('Ended at');
      });
    });

  const keyOf = (el) => (el.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 450);
  const prior = new Set(beforeKeys || []);
  const target = blocks.find(b => !prior.has(keyOf(b))) || blocks[0];
  if (!target) return null;

  const lines = splitLines(target.innerText || '');
  let ride_date = lines.find(x => monthLineRe.test(x)) || '';
  let duration = lines.find(x => /Duration:/i.test(x)) || '';
  let price_line = lines.find(x => /Price:/i.test(x)) || '';

  const sIdx = lines.findIndex(ln => /^Started at\\b/i.test(ln));
  const eIdx = lines.findIndex(ln => /^Ended at\\b/i.test(ln));
  const started_at = sIdx >= 0 ? lines[sIdx] : '';
  const ended_at = eIdx >= 0 ? lines[eIdx] : '';
  const start_station = sIdx > 0 ? lines[sIdx - 1] : '';
  const end_station = eIdx > 0 ? lines[eIdx - 1] : '';

  if (!ride_date || !duration || !price_line) {
    let p = target;
    for (let i = 0; i < 8 && p; i++) {
      p = p.parentElement;
      if (!p) break;
      const parentLines = splitLines(p.innerText || '');
      if (!ride_date) ride_date = parentLines.find(x => monthLineRe.test(x)) || ride_date;
      if (!duration) duration = parentLines.find(x => /Duration:/i.test(x)) || duration;
      if (!price_line) price_line = parentLines.find(x => /Price:/i.test(x)) || price_line;
      if (ride_date && duration && price_line) break;
    }
  }

  if (!start_station || !end_station) return null;
  return {
    ride_date,
    start_station,
    end_station,
    started_at,
    ended_at,
    duration,
    price_line
  };
}
"

key_js <- "
() => {
  const blocks = Array.from(document.querySelectorAll('body *'))
    .filter(el => {
      const t = (el.innerText || '').trim();
      return t.includes('YOUR TRIP') && t.includes('Started at') && t.includes('Ended at');
    })
    .filter(el => {
      return !Array.from(el.querySelectorAll('*')).some(child => {
        if (child === el) return false;
        const t = (child.innerText || '').trim();
        return t.includes('YOUR TRIP') && t.includes('Started at') && t.includes('Ended at');
      });
    });
  return blocks.map(el => (el.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 450));
}
"

to_df <- function(x) {
  data.frame(
    ride_date = as.character(x$ride_date %||% ""),
    start_station = as.character(x$start_station %||% ""),
    end_station = as.character(x$end_station %||% ""),
    started_at = as.character(x$started_at %||% ""),
    ended_at = as.character(x$ended_at %||% ""),
    duration = as.character(x$duration %||% ""),
    price_line = as.character(x$price_line %||% ""),
    stringsAsFactors = FALSE
  )
}

count_expand_buttons <- function() {
  tryCatch(
    as.integer(page$locator("button[aria-label='Expand for more details']")$count()),
    error = function(e) NA_integer_
  )
}

preload_to_required <- function(required_buttons, initial_count) {
  if (is.na(required_buttons) || is.na(initial_count) || required_buttons <= initial_count) {
    return(list(show_more_clicks = 0L, final_count = initial_count))
  }
  message(
    "Preloading rides to reach required expand buttons: ", required_buttons,
    " (currently ", initial_count, ")"
  )
  stagnant <- 0L
  prev_count <- initial_count
  show_more_clicks <- 0L
  max_preload_clicks <- 2000L

  for (i in seq_len(max_preload_clicks)) {
    page$evaluate("window.scrollTo(0, document.body.scrollHeight)")
    page$wait_for_timeout(500)

    clicked <- tryCatch({
      loc <- page$get_by_text("Show More", exact = FALSE)
      n <- as.integer(loc$count())
      if (!is.na(n) && n > 0L) {
        loc$first$scroll_into_view_if_needed()
        loc$first$click(timeout = 5000L, force = TRUE)
        TRUE
      } else {
        FALSE
      }
    }, error = function(e) FALSE)
    if (!clicked) {
      clicked <- tryCatch(isTRUE(page$evaluate(click_show_more_js)), error = function(e) FALSE)
    }
    if (!clicked) break

    show_more_clicks <- show_more_clicks + 1L
    page$wait_for_timeout(1000)

    current_count <- count_expand_buttons()
    if (!is.na(current_count) && current_count >= required_buttons) {
      message(
        "Preload done: expand buttons now ", current_count,
        " after ", show_more_clicks, " Show More clicks."
      )
      page$evaluate("window.scrollTo(0, 0)")
      page$wait_for_timeout(250)
      return(list(show_more_clicks = show_more_clicks, final_count = current_count))
    }
    if (identical(current_count, prev_count)) {
      stagnant <- stagnant + 1L
    } else {
      stagnant <- 0L
    }
    prev_count <- current_count
    if (show_more_clicks %% 10L == 0L) {
      message("Preload progress: clicks=", show_more_clicks, ", expand buttons=", current_count)
    }
    if (stagnant >= 5L) {
      message("Preload stopped due to no growth in expand button count (", current_count, ").")
      break
    }
  }
  page$evaluate("window.scrollTo(0, 0)")
  page$wait_for_timeout(250)
  list(show_more_clicks = show_more_clicks, final_count = count_expand_buttons())
}

extract_chunk <- function(click_offset, target_rides) {
  button_count <- count_expand_buttons()
  required_buttons <- as.integer(click_offset + target_rides)
  preload <- preload_to_required(required_buttons, button_count)
  button_count <- preload$final_count
  message("Expand buttons available for extraction: ", button_count)

  if (is.na(button_count) || button_count <= click_offset) {
    return(list(rows_df = NULL, parsed_total = 0L, show_more_clicks = preload$show_more_clicks))
  }

  n_to_process <- min(as.integer(target_rides), as.integer(button_count - click_offset))
  if (n_to_process <= 0L) {
    return(list(rows_df = NULL, parsed_total = 0L, show_more_clicks = preload$show_more_clicks))
  }
  needed_total <- as.integer(click_offset + n_to_process)
  message(
    "Running extraction with click_offset=", click_offset,
    ", target_rides=", as.character(target_rides),
    ", needed_total_loaded=", needed_total
  )

  out_rows <- list()
  attempts <- 0L
  max_attempts <- as.integer(max(200L, n_to_process * 8L))

  while (length(out_rows) < n_to_process && attempts < max_attempts) {
    attempts <- attempts + 1L
    i <- length(out_rows) + 1L
    message(sprintf("opening %d/%d (attempt %d) ...", i, n_to_process, attempts))

    before_keys <- tryCatch(page$evaluate(key_js), error = function(e) list())
    btns_now <- page$locator("button[aria-label='Expand for more details']")
    btn_count_now <- tryCatch(as.integer(btns_now$count()), error = function(e) 0L)
    if (is.na(btn_count_now) || btn_count_now <= click_offset) {
      message("No remaining 'Expand for more details' buttons found.")
      break
    }
    # Always click the fixed click_offset-th collapsed row.
    # As rows expand, the next target row shifts into this same position.
    btn <- btns_now$nth(as.integer(click_offset))

    try(btn$scroll_into_view_if_needed(), silent = TRUE)
    click_ok <- tryCatch({
      btn$click(timeout = 5000L, force = TRUE)
      TRUE
    }, error = function(e) FALSE)
    if (!click_ok) {
      message(sprintf("skip %d/%d: click failed at offset index %d", i, n_to_process, click_offset))
      next
    }
    page$wait_for_timeout(900)

    parsed <- tryCatch(page$evaluate(extract_js, before_keys), error = function(e) NULL)
    if (is.null(parsed)) {
      page$wait_for_timeout(800)
      parsed <- tryCatch(page$evaluate(extract_js, before_keys), error = function(e) NULL)
    }

    if (!is.null(parsed)) {
      out_rows[[length(out_rows) + 1L]] <- parsed
      if (length(out_rows) <= 10L || (length(out_rows) %% log_every == 0L)) {
        message(
          sprintf(
            "parsed %d/%d: %s | %s -> %s",
            length(out_rows), n_to_process,
            parsed$ride_date %||% "",
            parsed$start_station %||% "",
            parsed$end_station %||% ""
          )
        )
      }
    } else {
      message(sprintf("skip %d/%d: no parsed detail block", i, n_to_process))
    }
  }

  if (length(out_rows) == 0L) {
    return(list(rows_df = NULL, parsed_total = 0L, show_more_clicks = preload$show_more_clicks))
  }

  rows_df <- do.call(rbind, lapply(out_rows, to_df))

  list(rows_df = rows_df, parsed_total = length(out_rows), show_more_clicks = preload$show_more_clicks)
}

append_rows <- function(df, out_file) {
  if (is.null(df) || nrow(df) == 0L) return(invisible(NULL))
  if (file.exists(out_file)) {
    write.table(df, out_file, sep = ",", row.names = FALSE, col.names = FALSE, append = TRUE, qmethod = "double")
  } else {
    write.csv(df, out_file, row.names = FALSE, na = "")
  }
  invisible(NULL)
}

read_checkpoint <- function(path, fallback) {
  if (!resume_from_checkpoint || !file.exists(path)) return(as.integer(fallback))
  val <- suppressWarnings(as.integer(trimws(readLines(path, warn = FALSE, n = 1L))))
  if (is.na(val) || val < 0L) as.integer(fallback) else val
}

write_checkpoint <- function(path, idx) {
  writeLines(as.character(as.integer(idx)), path, useBytes = TRUE)
}

start_index <- read_checkpoint(checkpoint_file, start_index)
message("Starting index: ", start_index)
message("Combined output file: ", file.path(getwd(), combined_output_file))
message("Checkpoint file: ", file.path(getwd(), checkpoint_file))
click_offset <- as.integer(start_index)
message("Fixed click offset for this run: ", click_offset)

chunk_counter <- 0L
total_exported <- 0L
repeat {
  chunk_counter <- chunk_counter + 1L
  if (!is.na(max_chunks) && chunk_counter > as.integer(max_chunks)) {
    message("Stopping due to max_chunks=", max_chunks)
    break
  }

  message("\n=== Chunk ", chunk_counter, " | start_index=", start_index, " ===")
  res <- extract_chunk(click_offset = click_offset, target_rides = target_rides)
  rows_df <- res$rows_df

  if (is.null(rows_df) || nrow(rows_df) == 0L) {
    message("No rows returned for this chunk; stopping.")
    break
  }

  if (write_chunk_files) {
    chunk_file <- sprintf(
      "cabi_ride_history_chunk_%05d_%05d.csv",
      as.integer(start_index),
      as.integer(start_index + nrow(rows_df) - 1L)
    )
    write.csv(rows_df, chunk_file, row.names = FALSE, na = "")
    message("Chunk file: ", file.path(getwd(), chunk_file))
  }

  append_rows(rows_df, combined_output_file)
  total_exported <- total_exported + nrow(rows_df)
  start_index <- as.integer(start_index + nrow(rows_df))
  write_checkpoint(checkpoint_file, start_index)

  message("Rows exported in chunk: ", nrow(rows_df))
  message("Total exported this run: ", total_exported)
  message("Checkpoint updated to start_index=", start_index)

  if (!run_until_exhausted) break
  if (nrow(rows_df) < as.integer(target_rides) && res$show_more_clicks == 0L) {
    message("Chunk shorter than target and no additional Show More clicks happened; likely finished.")
    break
  }
}

message("\nExtraction complete.")
message("Total rows exported this run: ", total_exported)
message("Combined output file: ", file.path(getwd(), combined_output_file))
message("Persistent profile path: ", profile_dir)
message("Next run resumes from checkpoint start_index=", start_index)
