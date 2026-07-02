#!/usr/bin/env Rscript

# Fanya Hanwen Corpus: standard corpus-search analysis profile
#
# Inputs:
#   1. document_counts.csv — one body-only row per document in scope
#   2. analysis_occurrences.csv — compact row per matched occurrence
#   3. output directory
#
# The script deliberately uses base R only. This keeps the server footprint
# small and leaves an ordinary, readable script that can be cited and rerun.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3) {
  stop("Usage: Rscript --vanilla analysis.R document_counts.csv analysis_occurrences.csv output_directory")
}

document_path <- normalizePath(args[[1]], mustWork = TRUE)
occurrence_path <- normalizePath(args[[2]], mustWork = TRUE)
output_dir <- normalizePath(args[[3]], mustWork = TRUE)
figure_dir <- file.path(output_dir, "figures")
dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)

started <- proc.time()[["elapsed"]]
warnings_seen <- character()

write_utf8_csv <- function(data, path) {
  connection <- file(path, open = "wt", encoding = "UTF-8")
  tryCatch(
    write.csv(data, connection, row.names = FALSE, na = ""),
    finally = close(connection)
  )
}

as_number <- function(value) {
  result <- suppressWarnings(as.numeric(value))
  result[is.na(result)] <- 0
  result
}

clean_group <- function(value) {
  result <- trimws(as.character(value))
  result[is.na(result) | result == ""] <- "(Unknown / unclassified)"
  result
}

safe_rate <- function(numerator, denominator, multiplier = 1) {
  ifelse(denominator > 0, numerator / denominator * multiplier, 0)
}

folder_group <- function(path) {
  parts <- strsplit(as.character(path), "/", fixed = TRUE)[[1]]
  parts <- parts[parts != ""]
  ignored <- c(
    "clean", "raw", "variants", "variant", "translations", "translation",
    "annotations", "annotation", "kanbun", "hanmun", "hanvan"
  )
  parts <- parts[!(tolower(parts) %in% ignored)]
  if (length(parts) == 0) return("(Unknown / unclassified)")
  paste(head(parts, 3), collapse = " / ")
}

aggregate_dimension <- function(data, column, dimension, chronological = FALSE) {
  labels <- clean_group(data[[column]])
  indices <- split(seq_len(nrow(data)), labels, drop = TRUE)

  rows <- lapply(names(indices), function(label) {
    subset <- data[indices[[label]], , drop = FALSE]
    documents <- nrow(subset)
    matching_documents <- sum(subset$matching_document > 0)
    occurrences <- sum(subset$occurrences)
    searchable_characters <- sum(subset$searchable_characters)
    matching_counts <- subset$occurrences[subset$occurrences > 0]
    dated_years <- subset$year_start[is.finite(subset$year_start) & subset$year_start != 0]

    data.frame(
      dimension = dimension,
      group = label,
      documents = documents,
      matching_documents = matching_documents,
      occurrences = occurrences,
      searchable_characters = searchable_characters,
      document_prevalence = safe_rate(matching_documents, documents),
      occurrences_per_million = safe_rate(occurrences, searchable_characters, 1000000),
      mean_occurrences_per_matching_document = if (length(matching_counts) > 0) mean(matching_counts) else 0,
      median_occurrences_per_matching_document = if (length(matching_counts) > 0) median(matching_counts) else 0,
      occurrence_share = 0,
      sort_year = if (length(dated_years) > 0) median(dated_years) else NA_real_,
      stringsAsFactors = FALSE
    )
  })

  result <- if (length(rows) > 0) do.call(rbind, rows) else data.frame()
  if (nrow(result) == 0) return(result)

  total_occurrences <- sum(result$occurrences)
  result$occurrence_share <- safe_rate(result$occurrences, total_occurrences)

  if (chronological) {
    result <- result[order(is.na(result$sort_year), result$sort_year, result$group), , drop = FALSE]
  } else {
    result <- result[order(-result$occurrences, -result$searchable_characters, result$group), , drop = FALSE]
  }
  rownames(result) <- NULL
  result
}

metric_definitions <- list(
  occurrences = list(label = "Occurrences", column = "occurrences", multiplier = 1),
  matching_documents = list(label = "Matching documents", column = "matching_documents", multiplier = 1),
  document_prevalence = list(label = "Documents containing the query (%)", column = "document_prevalence", multiplier = 100),
  occurrences_per_million = list(label = "Occurrences per million searchable characters", column = "occurrences_per_million", multiplier = 1)
)

dimension_definitions <- list(
  period = list(label = "Period", limit = 40, chronological = TRUE),
  nation = list(label = "Nation", limit = 30, chronological = FALSE),
  region = list(label = "Region", limit = 30, chronological = FALSE),
  author = list(label = "Author", limit = 30, chronological = FALSE),
  folder = list(label = "Folder branch", limit = 40, chronological = FALSE),
  document_role = list(label = "Text or corpus layer", limit = 20, chronological = FALSE)
)

truncate_label <- function(value, maximum = 52) {
  value <- as.character(value)
  ifelse(nchar(value, type = "chars") > maximum,
         paste0(substr(value, 1, maximum - 1), "…"),
         value)
}

select_chart_rows <- function(data, metric, limit, chronological) {
  if (nrow(data) <= limit) return(data)

  column <- metric_definitions[[metric]]$column
  selected <- order(-data[[column]], -data$searchable_characters, data$group)[seq_len(limit)]
  result <- data[selected, , drop = FALSE]
  if (chronological) {
    result <- result[order(is.na(result$sort_year), result$sort_year, result$group), , drop = FALSE]
  } else {
    result <- result[order(-result[[column]], result$group), , drop = FALSE]
  }
  result
}

render_bar_chart <- function(data, dimension, metric, svg_path, png_path) {
  definition <- metric_definitions[[metric]]
  values <- data[[definition$column]] * definition$multiplier
  labels <- truncate_label(data$group)
  chart_height <- max(5.5, min(18, 2.8 + length(values) * 0.30))
  left_margin <- max(9, min(26, max(nchar(labels, type = "width"), na.rm = TRUE) * 0.56))
  title <- paste(definition$label, "by", dimension_definitions[[dimension]]$label)

  draw <- function() {
    old <- par(no.readonly = TRUE)
    on.exit(par(old), add = TRUE)
    par(mar = c(4.6, left_margin, 3.5, 1.2) + 0.1)
    barplot(
      rev(values),
      names.arg = rev(labels),
      horiz = TRUE,
      las = 1,
      border = NA,
      main = title,
      xlab = definition$label,
      cex.names = 0.78
    )
  }

  svg(svg_path, width = 10.5, height = chart_height, pointsize = 10, onefile = TRUE)
  draw()
  dev.off()

  png(png_path, width = 1680, height = as.integer(chart_height * 160), res = 160)
  draw()
  dev.off()

  title
}

render_distribution_chart <- function(values, labels, title, x_label, svg_path, png_path) {
  draw <- function() {
    old <- par(no.readonly = TRUE)
    on.exit(par(old), add = TRUE)
    par(mar = c(5.4, 5.2, 3.5, 1.2) + 0.1)
    barplot(values, names.arg = labels, las = 2, border = NA, main = title, ylab = "Documents", xlab = x_label)
  }

  svg(svg_path, width = 9.5, height = 6.2, pointsize = 10, onefile = TRUE)
  draw()
  dev.off()
  png(png_path, width = 1520, height = 992, res = 160)
  draw()
  dev.off()
}

render_histogram <- function(values, title, x_label, svg_path, png_path) {
  breaks <- if (length(unique(values)) <= 1) {
    c(values[[1]] - 0.5, values[[1]] + 0.5)
  } else {
    "FD"
  }

  draw <- function() {
    old <- par(no.readonly = TRUE)
    on.exit(par(old), add = TRUE)
    par(mar = c(4.8, 5.2, 3.5, 1.2) + 0.1)
    hist(values, breaks = breaks, main = title, xlab = x_label, ylab = "Occurrences", border = NA)
  }

  svg(svg_path, width = 9.5, height = 6.2, pointsize = 10, onefile = TRUE)
  draw()
  dev.off()
  png(png_path, width = 1520, height = 992, res = 160)
  draw()
  dev.off()
}

json_escape_one <- function(value) {
  backslash <- intToUtf8(92)
  characters <- strsplit(enc2utf8(as.character(value)), "", fixed = TRUE)[[1]]
  encoded <- vapply(characters, function(character) {
    if (character == backslash) return(paste0(backslash, backslash))
    if (character == '"') return(paste0(backslash, '"'))
    if (character == "\r") return(paste0(backslash, "r"))
    if (character == "\n") return(paste0(backslash, "n"))
    if (character == "\t") return(paste0(backslash, "t"))
    character
  }, character(1))
  paste0(encoded, collapse = "")
}

json_escape <- function(value) {
  vapply(as.character(value), json_escape_one, character(1), USE.NAMES = FALSE)
}

json_scalar <- function(value) {
  if (length(value) == 0 || is.na(value)) return("null")
  if (is.logical(value)) return(if (value) "true" else "false")
  if (is.numeric(value)) {
    if (!is.finite(value)) return("null")
    return(format(value, scientific = FALSE, trim = TRUE, digits = 15))
  }
  paste0('"', json_escape(value), '"')
}

json_object <- function(values) {
  entries <- vapply(names(values), function(name) {
    paste0('"', json_escape(name), '":', json_scalar(values[[name]]))
  }, character(1))
  paste0("{", paste(entries, collapse = ","), "}")
}

json_rows <- function(data) {
  if (nrow(data) == 0) return("[]")
  rows <- vapply(seq_len(nrow(data)), function(index) {
    json_object(as.list(data[index, , drop = FALSE]))
  }, character(1))
  paste0("[", paste(rows, collapse = ","), "]")
}

withCallingHandlers({
  documents <- read.csv(document_path, stringsAsFactors = FALSE, check.names = FALSE, fileEncoding = "UTF-8")
  occurrences <- read.csv(occurrence_path, stringsAsFactors = FALSE, check.names = FALSE, fileEncoding = "UTF-8")

  required_documents <- c(
    "doc_id", "path", "folder_path", "document_role", "title", "author",
    "year_start", "year_end", "nation", "period", "region",
    "searchable_characters", "occurrences", "matching_document"
  )
  missing_documents <- setdiff(required_documents, names(documents))
  if (length(missing_documents) > 0) {
    stop(paste("Missing document columns:", paste(missing_documents, collapse = ", ")))
  }

  required_occurrences <- c(
    "occurrence_id", "mode", "path", "doc_id", "search_start_offset", "search_end_offset"
  )
  missing_occurrences <- setdiff(required_occurrences, names(occurrences))
  if (length(missing_occurrences) > 0) {
    stop(paste("Missing occurrence columns:", paste(missing_occurrences, collapse = ", ")))
  }

  for (column in c("searchable_characters", "occurrences", "matching_document", "year_start", "year_end")) {
    documents[[column]] <- suppressWarnings(as.numeric(documents[[column]]))
  }
  documents$searchable_characters[is.na(documents$searchable_characters)] <- 0
  documents$occurrences[is.na(documents$occurrences)] <- 0
  documents$matching_document[is.na(documents$matching_document)] <- 0

  for (column in c("occurrence_id", "search_start_offset", "search_end_offset")) {
    occurrences[[column]] <- suppressWarnings(as.numeric(occurrences[[column]]))
  }

  documents$folder <- vapply(documents$folder_path, folder_group, character(1))
  documents$document_role <- clean_group(documents$document_role)
  role_labels <- c(
    canonical = "Received text",
    textual_variant = "Variants",
    raw = "Raw scrapes",
    derived_reading = "Kanbun / Hanmun / Hanvan",
    translation = "Translation",
    annotation = "Annotation"
  )
  documents$document_role_group <- unname(role_labels[documents$document_role])
  missing_role_labels <- is.na(documents$document_role_group) | documents$document_role_group == ""
  documents$document_role_group[missing_role_labels] <- documents$document_role[missing_role_labels]

  total_documents <- nrow(documents)
  matching_documents <- sum(documents$matching_document > 0)
  total_occurrences <- sum(documents$occurrences)
  searchable_characters <- sum(documents$searchable_characters)
  matching_counts <- documents$occurrences[documents$occurrences > 0]

  overall_values <- c(
    documents = total_documents,
    matching_documents = matching_documents,
    occurrences = total_occurrences,
    searchable_characters = searchable_characters,
    document_prevalence = safe_rate(matching_documents, total_documents),
    occurrences_per_million = safe_rate(total_occurrences, searchable_characters, 1000000),
    mean_occurrences_per_matching_document = if (length(matching_counts) > 0) mean(matching_counts) else 0,
    median_occurrences_per_matching_document = if (length(matching_counts) > 0) median(matching_counts) else 0,
    zero_length_documents = sum(documents$searchable_characters <= 0)
  )

  overall <- data.frame(metric = names(overall_values), value = as.numeric(overall_values), stringsAsFactors = FALSE)
  write_utf8_csv(overall, file.path(output_dir, "summary.csv"))

  dimension_tables <- list(
    period = aggregate_dimension(documents, "period", "period", chronological = TRUE),
    nation = aggregate_dimension(documents, "nation", "nation"),
    region = aggregate_dimension(documents, "region", "region"),
    author = aggregate_dimension(documents, "author", "author"),
    folder = aggregate_dimension(documents, "folder", "folder"),
    document_role = aggregate_dimension(documents, "document_role_group", "document_role")
  )

  for (dimension in names(dimension_tables)) {
    write_utf8_csv(dimension_tables[[dimension]], file.path(output_dir, paste0(dimension, "_summary.csv")))
  }

  chart_rows <- list()
  chart_index <- 0

  for (dimension in names(dimension_tables)) {
    table <- dimension_tables[[dimension]]
    if (nrow(table) == 0) next
    definition <- dimension_definitions[[dimension]]

    for (metric in names(metric_definitions)) {
      selected <- select_chart_rows(table, metric, definition$limit, definition$chronological)
      key <- paste(dimension, metric, sep = "_")
      svg_relative <- file.path("figures", paste0(key, ".svg"))
      png_relative <- file.path("figures", paste0(key, ".png"))
      title <- render_bar_chart(
        selected,
        dimension,
        metric,
        file.path(output_dir, svg_relative),
        file.path(output_dir, png_relative)
      )

      chart_index <- chart_index + 1
      chart_rows[[chart_index]] <- data.frame(
        key = key,
        kind = "group_bar",
        dimension = dimension,
        metric = metric,
        title = title,
        svg = svg_relative,
        png = png_relative,
        table = paste0(dimension, "_summary.csv"),
        shown_groups = nrow(selected),
        omitted_groups = max(0, nrow(table) - nrow(selected)),
        stringsAsFactors = FALSE
      )
    }
  }

  matching_documents_table <- documents[documents$occurrences > 0, , drop = FALSE]
  bucket_breaks <- c(0, 1, 2, 5, 10, 20, 50, 100, Inf)
  bucket_labels <- c("1", "2", "3–5", "6–10", "11–20", "21–50", "51–100", "101+")
  buckets <- cut(
    matching_documents_table$occurrences,
    breaks = bucket_breaks,
    labels = bucket_labels,
    include.lowest = FALSE,
    right = TRUE
  )
  distribution <- as.data.frame(table(buckets), stringsAsFactors = FALSE)
  names(distribution) <- c("occurrences_per_document", "documents")
  distribution$documents <- as.numeric(distribution$documents)
  distribution$share_of_matching_documents <- safe_rate(distribution$documents, sum(distribution$documents))
  write_utf8_csv(distribution, file.path(output_dir, "matches_per_document.csv"))

  if (nrow(distribution) > 0) {
    svg_relative <- file.path("figures", "matches_per_document.svg")
    png_relative <- file.path("figures", "matches_per_document.png")
    render_distribution_chart(
      distribution$documents,
      distribution$occurrences_per_document,
      "Distribution of matches across documents",
      "Occurrences in one matching document",
      file.path(output_dir, svg_relative),
      file.path(output_dir, png_relative)
    )
    chart_index <- chart_index + 1
    chart_rows[[chart_index]] <- data.frame(
      key = "matches_per_document",
      kind = "distribution",
      dimension = "document",
      metric = "matches_per_document",
      title = "Distribution of matches across documents",
      svg = svg_relative,
      png = png_relative,
      table = "matches_per_document.csv",
      shown_groups = nrow(distribution),
      omitted_groups = 0,
      stringsAsFactors = FALSE
    )
  }

  top_documents <- documents[documents$occurrences > 0, c(
    "doc_id", "title", "author", "period", "nation", "document_role", "path",
    "searchable_characters", "occurrences"
  ), drop = FALSE]
  if (nrow(top_documents) > 0) {
    top_documents$occurrences_per_million <- safe_rate(
      top_documents$occurrences,
      top_documents$searchable_characters,
      1000000
    )
    top_documents$occurrence_share <- safe_rate(top_documents$occurrences, total_occurrences)
    top_documents <- top_documents[order(-top_documents$occurrences, top_documents$path), , drop = FALSE]
  }
  write_utf8_csv(head(top_documents, 100), file.path(output_dir, "top_documents.csv"))

  concentration <- data.frame(
    measure = c("top_1_share", "top_5_share", "top_10_share"),
    value = c(
      if (nrow(top_documents) > 0) sum(head(top_documents$occurrences, 1)) / max(total_occurrences, 1) else 0,
      if (nrow(top_documents) > 0) sum(head(top_documents$occurrences, 5)) / max(total_occurrences, 1) else 0,
      if (nrow(top_documents) > 0) sum(head(top_documents$occurrences, 10)) / max(total_occurrences, 1) else 0
    ),
    stringsAsFactors = FALSE
  )
  write_utf8_csv(concentration, file.path(output_dir, "concentration_summary.csv"))

  proximity_modes <- unique(trimws(as.character(occurrences$mode)))
  proximity_available <- nrow(occurrences) > 0 && any(proximity_modes == "proximity")
  if (proximity_available) {
    proximity <- occurrences[occurrences$mode == "proximity", c(
      "occurrence_id", "doc_id", "path", "search_start_offset", "search_end_offset"
    ), drop = FALSE]
    proximity$span <- pmax(0, proximity$search_end_offset - proximity$search_start_offset)
    proximity <- proximity[is.finite(proximity$span), , drop = FALSE]
    write_utf8_csv(proximity, file.path(output_dir, "proximity_spans.csv"))

    if (nrow(proximity) > 0) {
      quantiles <- as.numeric(quantile(proximity$span, probs = c(0, 0.25, 0.5, 0.75, 1), names = FALSE, type = 7))
      proximity_summary <- data.frame(
        metric = c("occurrences", "minimum", "first_quartile", "median", "third_quartile", "maximum", "mean"),
        value = c(nrow(proximity), quantiles, mean(proximity$span)),
        stringsAsFactors = FALSE
      )
      write_utf8_csv(proximity_summary, file.path(output_dir, "proximity_summary.csv"))

      svg_relative <- file.path("figures", "proximity_span_histogram.svg")
      png_relative <- file.path("figures", "proximity_span_histogram.png")
      render_histogram(
        proximity$span,
        "Proximity-match span distribution",
        "Searchable characters from first to last matched term",
        file.path(output_dir, svg_relative),
        file.path(output_dir, png_relative)
      )
      chart_index <- chart_index + 1
      chart_rows[[chart_index]] <- data.frame(
        key = "proximity_span_histogram",
        kind = "histogram",
        dimension = "proximity",
        metric = "span_distribution",
        title = "Proximity-match span distribution",
        svg = svg_relative,
        png = png_relative,
        table = "proximity_spans.csv",
        shown_groups = nrow(proximity),
        omitted_groups = 0,
        stringsAsFactors = FALSE
      )
    }
  }

  charts <- if (length(chart_rows) > 0) do.call(rbind, chart_rows) else data.frame()
  write_utf8_csv(charts, file.path(output_dir, "chart_manifest.csv"))

  undated_documents <- sum(is.na(documents$year_start) | documents$year_start == 0)
  warnings_seen <- c(
    warnings_seen,
    if (undated_documents > 0) paste(undated_documents, "document(s) lack a parseable start year; period charts retain their named period but date ordering may be incomplete.") else character(),
    if (sum(documents$searchable_characters <= 0) > 0) paste(sum(documents$searchable_characters <= 0), "document(s) contain no searchable body characters under this punctuation policy.") else character(),
    if (nrow(charts) > 0 && any(charts$omitted_groups > 0)) "Some figures show only the highest-valued groups; the complete groups remain in the corresponding CSV table." else character()
  )

  tables <- c(
    summary = "summary.csv",
    period = "period_summary.csv",
    nation = "nation_summary.csv",
    region = "region_summary.csv",
    author = "author_summary.csv",
    folder = "folder_summary.csv",
    document_role = "document_role_summary.csv",
    matches_per_document = "matches_per_document.csv",
    top_documents = "top_documents.csv",
    concentration = "concentration_summary.csv"
  )
  if (file.exists(file.path(output_dir, "proximity_spans.csv"))) {
    tables <- c(tables, proximity_spans = "proximity_spans.csv", proximity_summary = "proximity_summary.csv")
  }

  report <- paste0(
    "{",
    '"version":1,',
    '"profile":"standard_analysis",',
    '"generated_at":', json_scalar(format(Sys.time(), tz = "UTC", usetz = TRUE)), ",",
    '"overall":', json_object(as.list(overall_values)), ",",
    '"charts":', json_rows(charts), ",",
    '"tables":', json_object(as.list(tables)),
    "}"
  )
  writeLines(report, file.path(output_dir, "analysis_report.json"), useBytes = TRUE)
}, warning = function(warning) {
  warnings_seen <<- c(warnings_seen, conditionMessage(warning))
  invokeRestart("muffleWarning")
})

writeLines(capture.output(sessionInfo()), file.path(output_dir, "sessionInfo.txt"), useBytes = TRUE)
writeLines(unique(warnings_seen), file.path(output_dir, "warnings.txt"), useBytes = TRUE)
write_utf8_csv(
  data.frame(elapsed_seconds = proc.time()[["elapsed"]] - started),
  file.path(output_dir, "timing.csv")
)
