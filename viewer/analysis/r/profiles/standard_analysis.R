#!/usr/bin/env Rscript

# Fanya Hanwen Corpus: standard corpus-search analysis profile
#
# Inputs:
#   1. document_counts.csv — one body-only row per document in scope
#   2. analysis_occurrences.csv — compact row per matched occurrence
#   3. output directory
#   4. optional comparison.csv with one dimension/left_group/right_group row
#
# The script deliberately uses base R only. This keeps the server footprint
# small and leaves an ordinary, readable script that can be cited and rerun.

args <- commandArgs(trailingOnly = TRUE)
if (!(length(args) %in% c(3, 4))) {
  stop("Usage: Rscript --vanilla analysis.R document_counts.csv analysis_occurrences.csv output_directory [comparison.csv]")
}

document_path <- normalizePath(args[[1]], mustWork = TRUE)
occurrence_path <- normalizePath(args[[2]], mustWork = TRUE)
output_dir <- normalizePath(args[[3]], mustWork = TRUE)
comparison_path <- if (length(args) == 4) normalizePath(args[[4]], mustWork = TRUE) else NULL
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

render_comparison_chart <- function(summary, svg_path, png_path) {
  labels <- summary$scope_label
  rates <- summary$occurrences_per_million
  prevalence <- summary$document_prevalence * 100

  draw <- function() {
    old <- par(no.readonly = TRUE)
    on.exit(par(old), add = TRUE)
    par(mfrow = c(1, 2), mar = c(7.2, 5.2, 3.5, 1.2) + 0.1)
    barplot(rates, names.arg = labels, las = 2, border = NA,
            main = "Normalized occurrence rate",
            ylab = "Occurrences per million searchable characters")
    barplot(prevalence, names.arg = labels, las = 2, border = NA,
            main = "Document prevalence",
            ylab = "Documents containing query (%)")
  }

  svg(svg_path, width = 11.5, height = 6.8, pointsize = 10, onefile = TRUE)
  draw()
  dev.off()
  png(png_path, width = 1840, height = 1088, res = 160)
  draw()
  dev.off()
}

poisson_log_likelihood <- function(left_count, left_exposure, right_count, right_exposure) {
  total_count <- left_count + right_count
  total_exposure <- left_exposure + right_exposure
  if (total_count <= 0 || total_exposure <= 0 || left_exposure <= 0 || right_exposure <= 0) {
    return(c(statistic = 0, p_value = 1))
  }
  expected <- c(
    total_count * left_exposure / total_exposure,
    total_count * right_exposure / total_exposure
  )
  observed <- c(left_count, right_count)
  terms <- ifelse(observed > 0 & expected > 0, observed * log(observed / expected), 0)
  statistic <- 2 * sum(terms)
  c(statistic = statistic, p_value = pchisq(statistic, df = 1, lower.tail = FALSE))
}

comparison_effects <- function(summary) {
  left <- summary[1, , drop = FALSE]
  right <- summary[2, , drop = FALSE]
  left_count <- left$occurrences
  right_count <- right$occurrences
  left_exposure <- left$searchable_characters
  right_exposure <- right$searchable_characters
  valid_exposure <- is.finite(left_exposure) && is.finite(right_exposure) &&
    left_exposure > 0 && right_exposure > 0

  if (valid_exposure) {
    corrected_left <- if (left_count > 0) left_count else 0.5
    corrected_right <- if (right_count > 0) right_count else 0.5
    left_rate <- corrected_left / left_exposure
    right_rate <- corrected_right / right_exposure
    rate_ratio <- left_rate / right_rate
    standard_error <- sqrt(1 / corrected_left + 1 / corrected_right)
    interval <- exp(log(rate_ratio) + c(-1, 1) * 1.96 * standard_error)
    likelihood <- poisson_log_likelihood(left_count, left_exposure, right_count, right_exposure)
    rate_difference <- left$occurrences_per_million - right$occurrences_per_million
  } else {
    rate_ratio <- NA_real_
    interval <- c(NA_real_, NA_real_)
    likelihood <- c(statistic = NA_real_, p_value = NA_real_)
    rate_difference <- NA_real_
  }

  prevalence_ratio <- if (right$document_prevalence > 0) {
    left$document_prevalence / right$document_prevalence
  } else {
    NA_real_
  }

  data.frame(
    measure = c(
      "rate_ratio_left_over_right",
      "rate_ratio_ci_low_95",
      "rate_ratio_ci_high_95",
      "log2_rate_ratio",
      "rate_difference_per_million",
      "document_prevalence_difference_percentage_points",
      "document_prevalence_ratio",
      "poisson_log_likelihood_g2",
      "poisson_log_likelihood_p_value"
    ),
    value = c(
      rate_ratio,
      interval[[1]],
      interval[[2]],
      if (is.finite(rate_ratio)) log(rate_ratio, base = 2) else NA_real_,
      rate_difference,
      (left$document_prevalence - right$document_prevalence) * 100,
      prevalence_ratio,
      likelihood[["statistic"]],
      likelihood[["p_value"]]
    ),
    stringsAsFactors = FALSE
  )
}



context_characters <- function(value) {
  characters <- strsplit(enc2utf8(ifelse(is.na(value), "", as.character(value))), "", fixed = TRUE)[[1]]
  if (length(characters) == 0) return(character())
  characters[!grepl("^[\\p{P}\\p{Z}\\p{C}]$", characters, perl = TRUE)]
}

split_contexts <- function(values) {
  lapply(values, context_characters)
}

matched_form_rows <- function(values, occurrence_ids, doc_ids) {
  rows <- vector("list", length(values))
  row_index <- 0

  for (index in seq_along(values)) {
    entries <- strsplit(ifelse(is.na(values[[index]]), "", as.character(values[[index]])), " | ", fixed = TRUE)[[1]]
    entries <- unique(trimws(entries))
    entries <- entries[entries != ""]
    if (length(entries) == 0) next

    parsed <- lapply(entries, function(entry) {
      pieces <- strsplit(entry, "⇒", fixed = TRUE)[[1]]
      if (length(pieces) < 2) return(NULL)
      query_form <- trimws(pieces[[1]])
      source_form <- trimws(paste(pieces[-1], collapse = "⇒"))
      if (query_form == "" || source_form == "") return(NULL)
      data.frame(
        query_form = query_form,
        source_form = source_form,
        occurrence_id = occurrence_ids[[index]],
        doc_id = doc_ids[[index]],
        stringsAsFactors = FALSE
      )
    })
    parsed <- Filter(Negate(is.null), parsed)
    if (length(parsed) == 0) next

    row_index <- row_index + 1
    rows[[row_index]] <- unique(do.call(rbind, parsed))
  }

  rows <- Filter(Negate(is.null), rows)
  if (length(rows) == 0) {
    return(data.frame(
      query_form = character(), source_form = character(), occurrence_id = numeric(),
      doc_id = character(), stringsAsFactors = FALSE
    ))
  }
  do.call(rbind, rows)
}

log_likelihood_2x2 <- function(left_count, right_count, left_total, right_total) {
  observed <- matrix(
    c(left_count, left_total - left_count, right_count, right_total - right_count),
    nrow = 2,
    byrow = TRUE
  )
  grand_total <- sum(observed)
  if (grand_total <= 0 || any(observed < 0)) return(c(g2 = NA_real_, p_value = NA_real_))
  expected <- outer(rowSums(observed), colSums(observed)) / grand_total
  valid <- observed > 0 & expected > 0
  statistic <- 2 * sum(observed[valid] * log(observed[valid] / expected[valid]))
  c(g2 = statistic, p_value = pchisq(statistic, df = 1, lower.tail = FALSE))
}

context_character_at <- function(characters, side, distance) {
  if (length(characters) < distance) return(NA_character_)
  if (side == "left") characters[[length(characters) - distance + 1]] else characters[[distance]]
}

summarize_neighbour_position <- function(context_lists, doc_ids, side, distance) {
  characters <- vapply(
    context_lists,
    context_character_at,
    character(1),
    side = side,
    distance = distance,
    USE.NAMES = FALSE
  )
  keep <- !is.na(characters) & characters != ""
  if (!any(keep)) return(data.frame())

  characters <- characters[keep]
  documents <- as.character(doc_ids[keep])
  occurrence_counts <- as.data.frame(table(characters), stringsAsFactors = FALSE)
  names(occurrence_counts) <- c("character", "occurrences")
  document_pairs <- unique(data.frame(character = characters, doc_id = documents, stringsAsFactors = FALSE))
  document_counts <- as.data.frame(table(document_pairs$character), stringsAsFactors = FALSE)
  names(document_counts) <- c("character", "documents")
  result <- merge(occurrence_counts, document_counts, by = "character", all.x = TRUE, sort = FALSE)
  result$side <- side
  result$distance <- distance
  result$position <- paste0(if (side == "left") "L" else "R", distance)
  result$share_at_position <- safe_rate(result$occurrences, sum(result$occurrences))
  result[, c("side", "distance", "position", "character", "occurrences", "documents", "share_at_position"), drop = FALSE]
}

render_neighbour_chart <- function(data, svg_path, png_path) {
  if (nrow(data) == 0) return(invisible(NULL))
  totals <- aggregate(occurrences ~ character + side, data = data, FUN = sum)
  wide <- reshape(totals, idvar = "character", timevar = "side", direction = "wide")
  for (column in c("occurrences.left", "occurrences.right")) {
    if (!(column %in% names(wide))) wide[[column]] <- 0
    wide[[column]][is.na(wide[[column]])] <- 0
  }
  wide$total <- wide$occurrences.left + wide$occurrences.right
  wide <- head(wide[order(-wide$total, wide$character), , drop = FALSE], 20)
  if (nrow(wide) == 0) return(invisible(NULL))

  values <- rbind(wide$occurrences.left, wide$occurrences.right)
  labels <- wide$character
  draw <- function() {
    old <- par(no.readonly = TRUE)
    on.exit(par(old), add = TRUE)
    par(mar = c(4.8, 5.2, 3.5, 1.2) + 0.1)
    barplot(
      values[, rev(seq_len(ncol(values))), drop = FALSE],
      names.arg = rev(labels),
      horiz = TRUE,
      las = 1,
      border = NA,
      main = "Characters near the matched passage",
      xlab = "Neighbour tokens within five characters",
      legend.text = c("Left", "Right"),
      args.legend = list(x = "bottomright", bty = "n")
    )
  }
  svg(svg_path, width = 10.5, height = 7.2, pointsize = 10, onefile = TRUE)
  draw()
  dev.off()
  png(png_path, width = 1680, height = 1152, res = 160)
  draw()
  dev.off()
}

render_ranked_chart <- function(data, label_column, value_column, title, x_label, svg_path, png_path, limit = 20) {
  if (nrow(data) == 0) return(invisible(NULL))
  ordered <- head(data[order(-data[[value_column]], data[[label_column]]), , drop = FALSE], limit)
  labels <- truncate_label(ordered[[label_column]], maximum = 44)
  values <- ordered[[value_column]]
  chart_height <- max(5.5, 2.8 + length(values) * 0.30)
  left_margin <- max(9, min(25, max(nchar(labels, type = "width"), na.rm = TRUE) * 0.56))

  draw <- function() {
    old <- par(no.readonly = TRUE)
    on.exit(par(old), add = TRUE)
    par(mar = c(4.6, left_margin, 3.5, 1.2) + 0.1)
    barplot(rev(values), names.arg = rev(labels), horiz = TRUE, las = 1, border = NA,
            main = title, xlab = x_label, cex.names = 0.82)
  }
  svg(svg_path, width = 10.5, height = chart_height, pointsize = 10, onefile = TRUE)
  draw()
  dev.off()
  png(png_path, width = 1680, height = as.integer(chart_height * 160), res = 160)
  draw()
  dev.off()
}

# Gries (2008) defines DP as half the summed absolute difference between
# observed occurrence shares and expected corpus-part size shares. DPnorm uses
# the corrected Lijffijt & Gries (2012) denominator 1 - min(s).
dispersion_values <- function(counts, exposures) {
  counts <- as.numeric(counts)
  exposures <- as.numeric(exposures)
  keep <- is.finite(counts) & is.finite(exposures) & exposures > 0
  counts <- counts[keep]
  exposures <- exposures[keep]
  if (length(counts) < 2 || sum(counts) <= 0 || sum(exposures) <= 0) {
    return(c(dp = NA_real_, dp_norm = NA_real_, evenness = NA_real_))
  }
  expected <- exposures / sum(exposures)
  observed <- counts / sum(counts)
  dp <- 0.5 * sum(abs(observed - expected))
  maximum <- 1 - min(expected)
  dp_norm <- if (maximum > 0) min(1, dp / maximum) else 0
  c(dp = dp, dp_norm = dp_norm, evenness = 1 - dp_norm)
}

poisson_rate_interval <- function(counts, exposures, multiplier = 1000000, confidence = 0.95) {
  alpha <- 1 - confidence
  lower_counts <- ifelse(counts > 0, 0.5 * qchisq(alpha / 2, 2 * counts), 0)
  upper_counts <- 0.5 * qchisq(1 - alpha / 2, 2 * (counts + 1))
  data.frame(
    lower = safe_rate(lower_counts, exposures, multiplier),
    upper = safe_rate(upper_counts, exposures, multiplier)
  )
}

historical_century_start <- function(year) {
  ifelse(year > 0, floor((year - 1) / 100) * 100 + 1, -ceiling(abs(year) / 100) * 100)
}

historical_century_label <- function(start) {
  end <- start + 99
  ifelse(
    start > 0,
    paste0(start, "–", end, " CE"),
    paste0(abs(start), "–", abs(end), " BCE")
  )
}

render_time_chart <- function(data, svg_path, png_path) {
  if (nrow(data) == 0) return(invisible(NULL))
  data <- data[order(data$century_start), , drop = FALSE]
  draw <- function() {
    old <- par(no.readonly = TRUE)
    on.exit(par(old), add = TRUE)
    par(mar = c(8.5, 5.4, 3.5, 1.2) + 0.1)
    x <- seq_len(nrow(data))
    ymax <- max(data$rate_ci_high, data$occurrences_per_million, na.rm = TRUE)
    if (!is.finite(ymax) || ymax <= 0) ymax <- 1
    plot(x, data$occurrences_per_million, type = "b", pch = 16, xaxt = "n",
         ylim = c(0, ymax * 1.05), xlab = "Century", ylab = "Occurrences per million searchable characters",
         main = "Observed frequency by dated century")
    arrows(x, data$rate_ci_low, x, data$rate_ci_high, angle = 90, code = 3, length = 0.035)
    axis(1, at = x, labels = data$century_label, las = 2, cex.axis = 0.72)
  }
  width <- max(10.5, min(24, 6 + nrow(data) * 0.45))
  svg(svg_path, width = width, height = 7.2, pointsize = 10, onefile = TRUE)
  draw()
  dev.off()
  png(png_path, width = as.integer(width * 160), height = 1152, res = 160)
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
  documents <- read.csv(
    document_path,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    fileEncoding = "UTF-8",
    colClasses = "character"
  )
  occurrences <- read.csv(
    occurrence_path,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    fileEncoding = "UTF-8",
    colClasses = "character"
  )

  required_documents <- c(
    "doc_id", "body_fingerprint", "path", "folder_path", "document_role", "title", "author",
    "year_start", "year_end", "nation", "period", "region",
    "searchable_characters", "occurrences", "matching_document"
  )
  missing_documents <- setdiff(required_documents, names(documents))
  if (length(missing_documents) > 0) {
    stop(paste("Missing document columns:", paste(missing_documents, collapse = ", ")))
  }

  required_occurrences <- c(
    "occurrence_id", "mode", "path", "doc_id", "search_start_offset", "search_end_offset",
    "matched_forms", "left_neighbours", "right_neighbours"
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

  comparison_payload <- NULL
  comparison_summary <- NULL
  comparison_effect_table <- NULL
  if (!is.null(comparison_path)) {
    comparison_config <- read.csv(comparison_path, stringsAsFactors = FALSE, check.names = FALSE, fileEncoding = "UTF-8")
    required_comparison <- c("dimension", "left_group", "right_group")
    missing_comparison <- setdiff(required_comparison, names(comparison_config))
    if (length(missing_comparison) > 0 || nrow(comparison_config) != 1) {
      stop("Comparison file must contain exactly one row with dimension, left_group, and right_group")
    }

    comparison_dimension <- trimws(as.character(comparison_config$dimension[[1]]))
    left_group <- trimws(as.character(comparison_config$left_group[[1]]))
    right_group <- trimws(as.character(comparison_config$right_group[[1]]))
    if (!(comparison_dimension %in% names(dimension_tables))) {
      stop(paste("Unsupported comparison dimension:", comparison_dimension))
    }
    comparison_table <- dimension_tables[[comparison_dimension]]
    left_row <- comparison_table[comparison_table$group == left_group, , drop = FALSE]
    right_row <- comparison_table[comparison_table$group == right_group, , drop = FALSE]
    if (nrow(left_row) != 1 || nrow(right_row) != 1) {
      stop("One or both selected comparison groups are absent from the analysis dataset")
    }

    comparison_summary <- rbind(left_row, right_row)
    comparison_summary$scope <- c("left", "right")
    comparison_summary$scope_label <- c(left_group, right_group)
    comparison_summary <- comparison_summary[, c(
      "scope", "scope_label", "dimension", "group", "documents", "matching_documents",
      "occurrences", "searchable_characters", "document_prevalence",
      "occurrences_per_million", "mean_occurrences_per_matching_document",
      "median_occurrences_per_matching_document", "occurrence_share", "sort_year"
    ), drop = FALSE]
    comparison_effect_table <- comparison_effects(comparison_summary)
    write_utf8_csv(comparison_summary, file.path(output_dir, "comparison_summary.csv"))
    write_utf8_csv(comparison_effect_table, file.path(output_dir, "comparison_effects.csv"))

    comparison_payload <- list(
      dimension = comparison_dimension,
      left_group = left_group,
      right_group = right_group
    )
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


  # Phase 9: advanced, body-only corpus diagnostics.
  # These calculations use only the compact occurrence contexts and document
  # denominators exported by Rails; metadata labels never enter the text stream.

  neighbour_positions <- list()
  neighbour_index <- 0
  neighbour_contexts <- list(left = list(), right = list())
  if (nrow(occurrences) > 0) {
    neighbour_contexts <- list(
      left = split_contexts(occurrences$left_neighbours),
      right = split_contexts(occurrences$right_neighbours)
    )
    for (side in c("left", "right")) {
      for (distance in seq_len(5)) {
        position_table <- summarize_neighbour_position(
          neighbour_contexts[[side]],
          occurrences$doc_id,
          side,
          distance
        )
        if (nrow(position_table) > 0) {
          neighbour_index <- neighbour_index + 1
          neighbour_positions[[neighbour_index]] <- position_table
        }
      }
    }
  }
  neighbour_table <- if (length(neighbour_positions) > 0) {
    do.call(rbind, neighbour_positions)
  } else {
    data.frame(
      side = character(), distance = numeric(), position = character(), character = character(),
      occurrences = numeric(), documents = numeric(), share_at_position = numeric(),
      stringsAsFactors = FALSE
    )
  }
  write_utf8_csv(neighbour_table, file.path(output_dir, "neighbour_characters.csv"))

  neighbour_window <- data.frame(
    character = character(), left_occurrences = numeric(), right_occurrences = numeric(),
    total_occurrences = numeric(), share_of_neighbour_tokens = numeric(), direction_balance = numeric(),
    stringsAsFactors = FALSE
  )
  if (nrow(neighbour_table) > 0) {
    side_totals <- aggregate(occurrences ~ character + side, data = neighbour_table, FUN = sum)
    left_totals <- side_totals[side_totals$side == "left", c("character", "occurrences"), drop = FALSE]
    right_totals <- side_totals[side_totals$side == "right", c("character", "occurrences"), drop = FALSE]
    names(left_totals)[2] <- "left_occurrences"
    names(right_totals)[2] <- "right_occurrences"
    neighbour_window <- merge(left_totals, right_totals, by = "character", all = TRUE)
    neighbour_window$left_occurrences[is.na(neighbour_window$left_occurrences)] <- 0
    neighbour_window$right_occurrences[is.na(neighbour_window$right_occurrences)] <- 0
    neighbour_window$total_occurrences <- neighbour_window$left_occurrences + neighbour_window$right_occurrences
    neighbour_window$share_of_neighbour_tokens <- safe_rate(
      neighbour_window$total_occurrences,
      sum(neighbour_window$total_occurrences)
    )
    neighbour_window$direction_balance <- ifelse(
      neighbour_window$total_occurrences > 0,
      (neighbour_window$right_occurrences - neighbour_window$left_occurrences) /
        neighbour_window$total_occurrences,
      0
    )
    neighbour_window <- neighbour_window[order(-neighbour_window$total_occurrences, neighbour_window$character), , drop = FALSE]
    write_utf8_csv(neighbour_window, file.path(output_dir, "neighbour_window_summary.csv"))

    svg_relative <- file.path("figures", "neighbour_characters.svg")
    png_relative <- file.path("figures", "neighbour_characters.png")
    render_neighbour_chart(
      neighbour_table,
      file.path(output_dir, svg_relative),
      file.path(output_dir, png_relative)
    )
    chart_index <- chart_index + 1
    chart_rows[[chart_index]] <- data.frame(
      key = "neighbour_characters",
      kind = "neighbour",
      dimension = "context",
      metric = "neighbour_tokens",
      title = "Characters near the matched passage",
      svg = svg_relative,
      png = png_relative,
      table = "neighbour_window_summary.csv",
      shown_groups = min(20, nrow(neighbour_window)),
      omitted_groups = max(0, nrow(neighbour_window) - 20),
      stringsAsFactors = FALSE
    )
  }

  form_rows <- matched_form_rows(occurrences$matched_forms, occurrences$occurrence_id, occurrences$doc_id)
  character_form_summary <- data.frame(
    query_form = character(), source_form = character(), occurrences = numeric(),
    documents = numeric(), occurrence_share = numeric(), stringsAsFactors = FALSE
  )
  if (nrow(form_rows) > 0) {
    occurrence_counts <- aggregate(occurrence_id ~ query_form + source_form, data = form_rows, FUN = function(values) length(unique(values)))
    names(occurrence_counts)[3] <- "occurrences"
    document_counts <- aggregate(doc_id ~ query_form + source_form, data = form_rows, FUN = function(values) length(unique(values)))
    names(document_counts)[3] <- "documents"
    character_form_summary <- merge(occurrence_counts, document_counts, by = c("query_form", "source_form"), all.x = TRUE)
    character_form_summary$occurrence_share <- safe_rate(character_form_summary$occurrences, sum(character_form_summary$occurrences))
    character_form_summary$chart_label <- ifelse(
      character_form_summary$query_form == character_form_summary$source_form,
      character_form_summary$source_form,
      paste0(character_form_summary$query_form, " → ", character_form_summary$source_form)
    )
    character_form_summary <- character_form_summary[
      order(-character_form_summary$occurrences, character_form_summary$query_form, character_form_summary$source_form),
      , drop = FALSE
    ]
  }
  write_utf8_csv(character_form_summary, file.path(output_dir, "character_form_summary.csv"))
  if (nrow(character_form_summary) > 0) {
    svg_relative <- file.path("figures", "character_forms.svg")
    png_relative <- file.path("figures", "character_forms.png")
    render_ranked_chart(
      character_form_summary, "chart_label", "occurrences",
      "Forms actually matched in the source", "Matched term occurrences",
      file.path(output_dir, svg_relative), file.path(output_dir, png_relative)
    )
    chart_index <- chart_index + 1
    chart_rows[[chart_index]] <- data.frame(
      key = "character_forms", kind = "ranked", dimension = "source_form", metric = "occurrences",
      title = "Forms actually matched in the source", svg = svg_relative, png = png_relative,
      table = "character_form_summary.csv", shown_groups = min(20, nrow(character_form_summary)),
      omitted_groups = max(0, nrow(character_form_summary) - 20), stringsAsFactors = FALSE
    )
  }

  sampling_seed <- 202609L
  matching_document_population <- documents[documents$matching_document > 0, , drop = FALSE]
  matching_document_population <- matching_document_population[order(matching_document_population$doc_id), , drop = FALSE]
  set.seed(sampling_seed)
  document_sample_indices <- if (nrow(matching_document_population) > 0) {
    sort(sample(seq_len(nrow(matching_document_population)), min(100L, nrow(matching_document_population)), replace = FALSE))
  } else integer()
  sample_documents <- matching_document_population[document_sample_indices, c(
    "doc_id", "title", "author", "period", "nation", "document_role", "path",
    "searchable_characters", "occurrences"
  ), drop = FALSE]
  write_utf8_csv(sample_documents, file.path(output_dir, "sample_documents.csv"))

  occurrence_population <- occurrences[order(occurrences$occurrence_id), , drop = FALSE]
  set.seed(sampling_seed + 1L)
  occurrence_sample_indices <- if (nrow(occurrence_population) > 0) {
    sort(sample(seq_len(nrow(occurrence_population)), min(100L, nrow(occurrence_population)), replace = FALSE))
  } else integer()
  sample_occurrences <- occurrence_population[occurrence_sample_indices, , drop = FALSE]
  write_utf8_csv(sample_occurrences, file.path(output_dir, "sample_occurrences.csv"))
  write_utf8_csv(
    data.frame(
      unit = c("matching_documents", "occurrences"),
      seed = c(sampling_seed, sampling_seed + 1L),
      population = c(nrow(matching_document_population), nrow(occurrence_population)),
      sample_size = c(nrow(sample_documents), nrow(sample_occurrences)),
      stringsAsFactors = FALSE
    ),
    file.path(output_dir, "sampling_manifest.csv")
  )

  comparison_neighbour_keyness <- data.frame(
    character = character(), left_scope = character(), right_scope = character(),
    left_occurrences = numeric(), right_occurrences = numeric(), left_rate_per_10000 = numeric(),
    right_rate_per_10000 = numeric(), log2_rate_ratio = numeric(), favoured_scope = character(),
    log_likelihood_g2 = numeric(), p_value = numeric(), stringsAsFactors = FALSE
  )
  if (!is.null(comparison_payload) && nrow(occurrences) > 0) {
    comparison_groups <- switch(
      comparison_payload$dimension,
      period = clean_group(documents$period),
      nation = clean_group(documents$nation),
      region = clean_group(documents$region),
      folder = clean_group(documents$folder),
      document_role = clean_group(documents$document_role_group),
      NULL
    )
    if (!is.null(comparison_groups)) {
      group_by_doc <- setNames(comparison_groups, documents$doc_id)
      occurrence_groups <- unname(group_by_doc[as.character(occurrences$doc_id)])
      context_for <- function(indices) {
        if (length(indices) == 0) return(character())
        unlist(lapply(indices, function(index) {
          c(neighbour_contexts$left[[index]], neighbour_contexts$right[[index]])
        }), use.names = FALSE)
      }
      left_characters <- context_for(which(occurrence_groups == comparison_payload$left_group))
      right_characters <- context_for(which(occurrence_groups == comparison_payload$right_group))
      left_total <- length(left_characters)
      right_total <- length(right_characters)
      all_characters <- sort(unique(c(left_characters, right_characters)))
      if (length(all_characters) > 0 && left_total > 0 && right_total > 0) {
        left_counts <- table(factor(left_characters, levels = all_characters))
        right_counts <- table(factor(right_characters, levels = all_characters))
        rows <- lapply(seq_along(all_characters), function(index) {
          left_count <- as.numeric(left_counts[[index]])
          right_count <- as.numeric(right_counts[[index]])
          likelihood <- log_likelihood_2x2(left_count, right_count, left_total, right_total)
          left_rate <- safe_rate(left_count, left_total, 10000)
          right_rate <- safe_rate(right_count, right_total, 10000)
          corrected_left <- (left_count + 0.5) / (left_total + 1)
          corrected_right <- (right_count + 0.5) / (right_total + 1)
          log_ratio <- log(corrected_left / corrected_right, base = 2)
          data.frame(
            character = all_characters[[index]],
            left_scope = comparison_payload$left_group,
            right_scope = comparison_payload$right_group,
            left_occurrences = left_count,
            right_occurrences = right_count,
            left_rate_per_10000 = left_rate,
            right_rate_per_10000 = right_rate,
            log2_rate_ratio = log_ratio,
            favoured_scope = if (log_ratio >= 0) comparison_payload$left_group else comparison_payload$right_group,
            log_likelihood_g2 = likelihood[["g2"]],
            p_value = likelihood[["p_value"]],
            stringsAsFactors = FALSE
          )
        })
        comparison_neighbour_keyness <- do.call(rbind, rows)
        comparison_neighbour_keyness <- comparison_neighbour_keyness[
          order(-comparison_neighbour_keyness$log_likelihood_g2, -abs(comparison_neighbour_keyness$log2_rate_ratio), comparison_neighbour_keyness$character),
          , drop = FALSE
        ]
        comparison_neighbour_keyness$chart_label <- paste0(
          comparison_neighbour_keyness$character, " (", comparison_neighbour_keyness$favoured_scope, ")"
        )
      }
    }
  }
  write_utf8_csv(comparison_neighbour_keyness, file.path(output_dir, "comparison_neighbour_keyness.csv"))
  if (nrow(comparison_neighbour_keyness) > 0) {
    svg_relative <- file.path("figures", "comparison_neighbour_keyness.svg")
    png_relative <- file.path("figures", "comparison_neighbour_keyness.png")
    render_ranked_chart(
      comparison_neighbour_keyness, "chart_label", "log_likelihood_g2",
      "Distinctive neighbouring characters in the compared scopes", "Log-likelihood G²",
      file.path(output_dir, svg_relative), file.path(output_dir, png_relative)
    )
    chart_index <- chart_index + 1
    chart_rows[[chart_index]] <- data.frame(
      key = "comparison_neighbour_keyness", kind = "ranked", dimension = "comparison_context",
      metric = "log_likelihood_g2", title = "Distinctive neighbouring characters in the compared scopes",
      svg = svg_relative, png = png_relative, table = "comparison_neighbour_keyness.csv",
      shown_groups = min(20, nrow(comparison_neighbour_keyness)),
      omitted_groups = max(0, nrow(comparison_neighbour_keyness) - 20), stringsAsFactors = FALSE
    )
  }

  alternative_summary <- data.frame(
    alternative = character(), occurrences = numeric(), documents = numeric(),
    share_of_matched_occurrences = numeric(), stringsAsFactors = FALSE
  )
  if (nrow(occurrences) > 0 && any(trimws(as.character(occurrences$mode)) == "alternatives")) {
    alternative_rows <- occurrences[trimws(as.character(occurrences$mode)) == "alternatives", , drop = FALSE]
    split_terms <- strsplit(as.character(alternative_rows$matched_alternatives), " | ", fixed = TRUE)
    expanded <- lapply(seq_along(split_terms), function(index) {
      terms <- unique(trimws(split_terms[[index]]))
      terms <- terms[!is.na(terms) & terms != ""]
      if (length(terms) == 0) return(NULL)
      data.frame(
        alternative = terms,
        occurrence_id = alternative_rows$occurrence_id[[index]],
        doc_id = alternative_rows$doc_id[[index]],
        stringsAsFactors = FALSE
      )
    })
    expanded <- Filter(Negate(is.null), expanded)
    if (length(expanded) > 0) {
      expanded <- do.call(rbind, expanded)
      occurrence_counts <- as.data.frame(table(expanded$alternative), stringsAsFactors = FALSE)
      names(occurrence_counts) <- c("alternative", "occurrences")
      document_pairs <- unique(expanded[, c("alternative", "doc_id"), drop = FALSE])
      document_counts <- as.data.frame(table(document_pairs$alternative), stringsAsFactors = FALSE)
      names(document_counts) <- c("alternative", "documents")
      alternative_summary <- merge(occurrence_counts, document_counts, by = "alternative", all.x = TRUE)
      alternative_summary$share_of_matched_occurrences <- safe_rate(
        alternative_summary$occurrences,
        nrow(alternative_rows)
      )
      alternative_summary <- alternative_summary[order(-alternative_summary$occurrences, alternative_summary$alternative), , drop = FALSE]
      write_utf8_csv(alternative_summary, file.path(output_dir, "alternative_summary.csv"))

      svg_relative <- file.path("figures", "alternative_terms.svg")
      png_relative <- file.path("figures", "alternative_terms.png")
      render_ranked_chart(
        alternative_summary,
        "alternative",
        "occurrences",
        "Matched alternatives",
        "Matched occurrences",
        file.path(output_dir, svg_relative),
        file.path(output_dir, png_relative)
      )
      chart_index <- chart_index + 1
      chart_rows[[chart_index]] <- data.frame(
        key = "alternative_terms",
        kind = "ranked",
        dimension = "alternative",
        metric = "occurrences",
        title = "Matched alternatives",
        svg = svg_relative,
        png = png_relative,
        table = "alternative_summary.csv",
        shown_groups = min(20, nrow(alternative_summary)),
        omitted_groups = max(0, nrow(alternative_summary) - 20),
        stringsAsFactors = FALSE
      )
    }
  }

  term_order_summary <- data.frame(
    term_order = character(), occurrences = numeric(), documents = numeric(),
    occurrence_share = numeric(), stringsAsFactors = FALSE
  )
  if (nrow(occurrences) > 0 && any(trimws(as.character(occurrences$mode)) == "proximity")) {
    order_rows <- occurrences[
      trimws(as.character(occurrences$mode)) == "proximity" &
        !is.na(occurrences$matched_term_order) & trimws(occurrences$matched_term_order) != "",
      , drop = FALSE
    ]
    if (nrow(order_rows) > 0) {
      occurrence_counts <- as.data.frame(table(order_rows$matched_term_order), stringsAsFactors = FALSE)
      names(occurrence_counts) <- c("term_order", "occurrences")
      document_pairs <- unique(order_rows[, c("matched_term_order", "doc_id"), drop = FALSE])
      document_counts <- as.data.frame(table(document_pairs$matched_term_order), stringsAsFactors = FALSE)
      names(document_counts) <- c("term_order", "documents")
      term_order_summary <- merge(occurrence_counts, document_counts, by = "term_order", all.x = TRUE)
      term_order_summary$occurrence_share <- safe_rate(term_order_summary$occurrences, sum(term_order_summary$occurrences))
      term_order_summary <- term_order_summary[order(-term_order_summary$occurrences, term_order_summary$term_order), , drop = FALSE]
      write_utf8_csv(term_order_summary, file.path(output_dir, "term_order_summary.csv"))

      svg_relative <- file.path("figures", "term_orders.svg")
      png_relative <- file.path("figures", "term_orders.png")
      render_ranked_chart(
        term_order_summary,
        "term_order",
        "occurrences",
        "Observed term orders",
        "Matched occurrences",
        file.path(output_dir, svg_relative),
        file.path(output_dir, png_relative)
      )
      chart_index <- chart_index + 1
      chart_rows[[chart_index]] <- data.frame(
        key = "term_orders",
        kind = "ranked",
        dimension = "proximity_order",
        metric = "occurrences",
        title = "Observed term orders",
        svg = svg_relative,
        png = png_relative,
        table = "term_order_summary.csv",
        shown_groups = min(20, nrow(term_order_summary)),
        omitted_groups = max(0, nrow(term_order_summary) - 20),
        stringsAsFactors = FALSE
      )
    }
  }

  document_dispersion <- dispersion_values(documents$occurrences, documents$searchable_characters)
  dispersion_summary <- data.frame(
    measure = c(
      "dp",
      "dp_norm",
      "evenness_one_minus_dp_norm",
      "document_range",
      "matching_documents",
      "documents_in_scope"
    ),
    value = c(
      document_dispersion[["dp"]],
      document_dispersion[["dp_norm"]],
      document_dispersion[["evenness"]],
      safe_rate(matching_documents, total_documents),
      matching_documents,
      total_documents
    ),
    stringsAsFactors = FALSE
  )
  write_utf8_csv(dispersion_summary, file.path(output_dir, "dispersion_summary.csv"))

  dimension_dispersion_rows <- lapply(names(dimension_tables), function(dimension) {
    table <- dimension_tables[[dimension]]
    values <- dispersion_values(table$occurrences, table$searchable_characters)
    data.frame(
      dimension = dimension,
      groups = nrow(table),
      dp = values[["dp"]],
      dp_norm = values[["dp_norm"]],
      evenness_one_minus_dp_norm = values[["evenness"]],
      stringsAsFactors = FALSE
    )
  })
  dimension_dispersion <- do.call(rbind, dimension_dispersion_rows)
  write_utf8_csv(dimension_dispersion, file.path(output_dir, "dimension_dispersion.csv"))

  body_fingerprints <- trimws(as.character(documents$body_fingerprint))
  body_fingerprints[is.na(body_fingerprints)] <- ""
  fingerprint_counts <- table(body_fingerprints[body_fingerprints != ""])
  duplicate_fingerprints <- names(fingerprint_counts[fingerprint_counts > 1])
  duplicate_members <- documents[body_fingerprints %in% duplicate_fingerprints, c(
    "body_fingerprint", "doc_id", "title", "author", "period", "nation",
    "document_role", "path", "searchable_characters", "occurrences", "matching_document"
  ), drop = FALSE]
  duplicate_groups <- data.frame(
    body_fingerprint = character(), documents = numeric(), matching_documents = numeric(),
    occurrences = numeric(), searchable_characters = numeric(), example_title = character(),
    example_path = character(), stringsAsFactors = FALSE
  )
  if (length(duplicate_fingerprints) > 0) {
    duplicate_group_rows <- lapply(duplicate_fingerprints, function(fingerprint) {
      subset <- duplicate_members[duplicate_members$body_fingerprint == fingerprint, , drop = FALSE]
      data.frame(
        body_fingerprint = fingerprint,
        documents = nrow(subset),
        matching_documents = sum(subset$matching_document > 0),
        occurrences = sum(subset$occurrences),
        searchable_characters = sum(subset$searchable_characters),
        example_title = subset$title[[1]],
        example_path = subset$path[[1]],
        stringsAsFactors = FALSE
      )
    })
    duplicate_groups <- do.call(rbind, duplicate_group_rows)
    duplicate_groups <- duplicate_groups[order(-duplicate_groups$documents, -duplicate_groups$occurrences, duplicate_groups$example_path), , drop = FALSE]
  }
  write_utf8_csv(duplicate_groups, file.path(output_dir, "duplicate_body_groups.csv"))
  write_utf8_csv(duplicate_members, file.path(output_dir, "duplicate_body_members.csv"))

  unique_body_key <- ifelse(body_fingerprints == "", paste0("doc:", documents$doc_id), paste0("body:", body_fingerprints))
  unique_indices <- split(seq_len(nrow(documents)), unique_body_key, drop = TRUE)
  unique_rows <- lapply(unique_indices, function(indices) {
    subset <- documents[indices, , drop = FALSE]
    data.frame(
      searchable_characters = max(subset$searchable_characters),
      occurrences = max(subset$occurrences),
      matching_document = max(subset$matching_document),
      stringsAsFactors = FALSE
    )
  })
  unique_bodies <- if (length(unique_rows) > 0) {
    do.call(rbind, unique_rows)
  } else {
    data.frame(
      searchable_characters = numeric(), occurrences = numeric(),
      matching_document = numeric(), stringsAsFactors = FALSE
    )
  }
  deduplicated_summary <- data.frame(
    basis = c("documents_as_stored", "unique_exact_bodies"),
    documents = c(nrow(documents), nrow(unique_bodies)),
    matching_documents = c(sum(documents$matching_document > 0), sum(unique_bodies$matching_document > 0)),
    occurrences = c(sum(documents$occurrences), sum(unique_bodies$occurrences)),
    searchable_characters = c(sum(documents$searchable_characters), sum(unique_bodies$searchable_characters)),
    stringsAsFactors = FALSE
  )
  deduplicated_summary$document_prevalence <- safe_rate(
    deduplicated_summary$matching_documents,
    deduplicated_summary$documents
  )
  deduplicated_summary$occurrences_per_million <- safe_rate(
    deduplicated_summary$occurrences,
    deduplicated_summary$searchable_characters,
    1000000
  )
  write_utf8_csv(deduplicated_summary, file.path(output_dir, "exact_body_sensitivity.csv"))

  duplicate_summary <- data.frame(
    metric = c(
      "duplicate_body_groups",
      "documents_in_duplicate_groups",
      "occurrences_in_duplicate_groups",
      "share_of_documents_in_duplicate_groups",
      "share_of_occurrences_in_duplicate_groups",
      "unique_exact_bodies"
    ),
    value = c(
      nrow(duplicate_groups),
      nrow(duplicate_members),
      sum(duplicate_members$occurrences),
      safe_rate(nrow(duplicate_members), nrow(documents)),
      safe_rate(sum(duplicate_members$occurrences), total_occurrences),
      nrow(unique_bodies)
    ),
    stringsAsFactors = FALSE
  )
  write_utf8_csv(duplicate_summary, file.path(output_dir, "duplicate_body_summary.csv"))

  dated_documents <- documents[
    documents$searchable_characters > 0 &
      ((is.finite(documents$year_start) & documents$year_start != 0) |
       (is.finite(documents$year_end) & documents$year_end != 0)),
    , drop = FALSE
  ]
  time_bins <- data.frame(
    century_start = numeric(), century_end = numeric(), century_label = character(),
    documents = numeric(), matching_documents = numeric(), occurrences = numeric(),
    searchable_characters = numeric(), document_prevalence = numeric(),
    occurrences_per_million = numeric(), rate_ci_low = numeric(), rate_ci_high = numeric(),
    stringsAsFactors = FALSE
  )
  time_model_table <- data.frame(
    model_family = character(), documents = numeric(), distinct_year_midpoints = numeric(),
    occurrences = numeric(), searchable_characters = numeric(), median_year = numeric(),
    log_rate_change_per_century = numeric(), standard_error = numeric(),
    rate_ratio_per_century = numeric(), rate_ratio_ci_low_95 = numeric(),
    rate_ratio_ci_high_95 = numeric(), p_value = numeric(),
    poisson_overdispersion_ratio = numeric(), stringsAsFactors = FALSE
  )
  if (nrow(dated_documents) > 0) {
    valid_start <- is.finite(dated_documents$year_start) & dated_documents$year_start != 0
    valid_end <- is.finite(dated_documents$year_end) & dated_documents$year_end != 0
    dated_documents$year_midpoint <- ifelse(
      valid_start & valid_end,
      (dated_documents$year_start + dated_documents$year_end) / 2,
      ifelse(valid_start, dated_documents$year_start, dated_documents$year_end)
    )
    dated_documents$century_start <- historical_century_start(dated_documents$year_midpoint)
    century_indices <- split(seq_len(nrow(dated_documents)), dated_documents$century_start, drop = TRUE)
    time_rows <- lapply(names(century_indices), function(start_value) {
      subset <- dated_documents[century_indices[[start_value]], , drop = FALSE]
      start <- as.numeric(start_value)
      data.frame(
        century_start = start,
        century_end = start + 99,
        century_label = historical_century_label(start),
        documents = nrow(subset),
        matching_documents = sum(subset$matching_document > 0),
        occurrences = sum(subset$occurrences),
        searchable_characters = sum(subset$searchable_characters),
        document_prevalence = safe_rate(sum(subset$matching_document > 0), nrow(subset)),
        occurrences_per_million = safe_rate(sum(subset$occurrences), sum(subset$searchable_characters), 1000000),
        stringsAsFactors = FALSE
      )
    })
    time_bins <- do.call(rbind, time_rows)
    intervals <- poisson_rate_interval(time_bins$occurrences, time_bins$searchable_characters)
    time_bins$rate_ci_low <- intervals$lower
    time_bins$rate_ci_high <- intervals$upper
    time_bins <- time_bins[order(time_bins$century_start), , drop = FALSE]
    if (nrow(time_bins) > 0) {
      svg_relative <- file.path("figures", "time_trend.svg")
      png_relative <- file.path("figures", "time_trend.png")
      render_time_chart(time_bins, file.path(output_dir, svg_relative), file.path(output_dir, png_relative))
      chart_index <- chart_index + 1
      chart_rows[[chart_index]] <- data.frame(
        key = "time_trend",
        kind = "time",
        dimension = "time",
        metric = "occurrences_per_million",
        title = "Observed frequency by dated century",
        svg = svg_relative,
        png = png_relative,
        table = "time_bins.csv",
        shown_groups = nrow(time_bins),
        omitted_groups = 0,
        stringsAsFactors = FALSE
      )
    }

    model_ready <- nrow(dated_documents) >= 20 &&
      length(unique(dated_documents$year_midpoint)) >= 5 &&
      sum(dated_documents$occurrences) >= 5
    if (model_ready) {
      dated_documents$centuries_from_median <- (
        dated_documents$year_midpoint - median(dated_documents$year_midpoint)
      ) / 100
      poisson_model <- tryCatch(
        glm(
          occurrences ~ centuries_from_median,
          offset = log(searchable_characters),
          family = poisson(),
          data = dated_documents
        ),
        error = function(error) NULL
      )
      if (!is.null(poisson_model) && poisson_model$df.residual > 0) {
        overdispersion <- sum(residuals(poisson_model, type = "pearson")^2) / poisson_model$df.residual
        model_family <- if (is.finite(overdispersion) && overdispersion > 1.5) "quasipoisson" else "poisson"
        final_model <- if (model_family == "quasipoisson") {
          glm(
            occurrences ~ centuries_from_median,
            offset = log(searchable_characters),
            family = quasipoisson(),
            data = dated_documents
          )
        } else {
          poisson_model
        }
        coefficient_table <- summary(final_model)$coefficients
        if ("centuries_from_median" %in% rownames(coefficient_table)) {
          estimate <- coefficient_table["centuries_from_median", "Estimate"]
          standard_error <- coefficient_table["centuries_from_median", "Std. Error"]
          p_column <- grep("Pr\\(", colnames(coefficient_table), value = TRUE)[1]
          p_value <- if (!is.na(p_column)) coefficient_table["centuries_from_median", p_column] else NA_real_
          rate_ratio <- exp(estimate)
          interval <- exp(estimate + c(-1, 1) * 1.96 * standard_error)
          time_model_table <- data.frame(
            model_family = model_family,
            documents = nrow(dated_documents),
            distinct_year_midpoints = length(unique(dated_documents$year_midpoint)),
            occurrences = sum(dated_documents$occurrences),
            searchable_characters = sum(dated_documents$searchable_characters),
            median_year = median(dated_documents$year_midpoint),
            log_rate_change_per_century = estimate,
            standard_error = standard_error,
            rate_ratio_per_century = rate_ratio,
            rate_ratio_ci_low_95 = interval[[1]],
            rate_ratio_ci_high_95 = interval[[2]],
            p_value = p_value,
            poisson_overdispersion_ratio = overdispersion,
            stringsAsFactors = FALSE
          )
        }
      }
    }
  }
  write_utf8_csv(time_bins, file.path(output_dir, "time_bins.csv"))
  write_utf8_csv(time_model_table, file.path(output_dir, "time_trend_model.csv"))

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

  if (!is.null(comparison_summary)) {
    svg_relative <- file.path("figures", "scope_comparison.svg")
    png_relative <- file.path("figures", "scope_comparison.png")
    render_comparison_chart(
      comparison_summary,
      file.path(output_dir, svg_relative),
      file.path(output_dir, png_relative)
    )
    chart_index <- chart_index + 1
    chart_rows[[chart_index]] <- data.frame(
      key = "scope_comparison",
      kind = "comparison",
      dimension = comparison_payload$dimension,
      metric = "scope_comparison",
      title = paste(comparison_payload$left_group, "compared with", comparison_payload$right_group),
      svg = svg_relative,
      png = png_relative,
      table = "comparison_summary.csv",
      shown_groups = 2,
      omitted_groups = 0,
      stringsAsFactors = FALSE
    )
  }

  charts <- if (length(chart_rows) > 0) do.call(rbind, chart_rows) else data.frame()
  write_utf8_csv(charts, file.path(output_dir, "chart_manifest.csv"))

  undated_documents <- sum(
    (is.na(documents$year_start) | documents$year_start == 0) &
      (is.na(documents$year_end) | documents$year_end == 0)
  )
  warnings_seen <- c(
    warnings_seen,
    if (undated_documents > 0) paste(undated_documents, "document(s) lack a parseable start year; period charts retain their named period but date ordering may be incomplete.") else character(),
    if (sum(documents$searchable_characters <= 0) > 0) paste(sum(documents$searchable_characters <= 0), "document(s) contain no searchable body characters under this punctuation policy.") else character(),
    if (nrow(charts) > 0 && any(charts$omitted_groups > 0)) "Some figures show only the highest-valued groups; the complete groups remain in the corresponding CSV table." else character(),
    if (!is.null(comparison_summary) && any(comparison_summary$occurrences == 0)) "The comparison rate-ratio confidence interval uses a 0.5 continuity correction because one selected scope has zero occurrences." else character(),
    if (!is.null(comparison_summary) && any(comparison_summary$searchable_characters <= 0)) "At least one comparison scope has no searchable body characters; exposure-based comparison statistics are unavailable." else character(),
    if (nrow(duplicate_groups) > 0) paste(nrow(duplicate_groups), "exact body-fingerprint group(s) contain repeated texts. Default counts retain every stored document; exact_body_sensitivity.csv shows a one-body-one-unit sensitivity check.") else character(),
    if (nrow(time_bins) > 0) paste(nrow(dated_documents), "dated document(s) contributed to century bins; undated documents remain in the overall analysis but not the time chart or trend model.") else character(),
    if (nrow(time_model_table) > 0) "The time-trend model is descriptive. It models document counts with searchable body characters as exposure and does not establish historical causation." else character(),
    if (nrow(time_model_table) > 0 && time_model_table$model_family[[1]] == "quasipoisson") "The dated-document Poisson model was overdispersed, so quasi-Poisson standard errors were used for the century trend." else character(),
    if (is.finite(document_dispersion[["dp_norm"]])) "DPnorm is calculated across documents from occurrence shares and searchable-character exposure shares; values nearer 1 indicate stronger concentration." else character(),
    paste("Fixed-seed samples use seeds", sampling_seed, "for matching documents and", sampling_seed + 1L, "for occurrences; IDs permit joins back to the complete exported tables."),
    if (nrow(comparison_neighbour_keyness) > 0) "Neighbour-keyness compares the five-character windows around matches in the two selected scopes. It describes contextual distinctiveness, not general corpus-wide word keyness." else character()
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
    concentration = "concentration_summary.csv",
    neighbour_characters = "neighbour_characters.csv",
    neighbour_window = "neighbour_window_summary.csv",
    character_forms = "character_form_summary.csv",
    sample_documents = "sample_documents.csv",
    sample_occurrences = "sample_occurrences.csv",
    sampling_manifest = "sampling_manifest.csv",
    comparison_neighbour_keyness = "comparison_neighbour_keyness.csv",
    dispersion = "dispersion_summary.csv",
    dimension_dispersion = "dimension_dispersion.csv",
    duplicate_body_summary = "duplicate_body_summary.csv",
    duplicate_body_groups = "duplicate_body_groups.csv",
    duplicate_body_members = "duplicate_body_members.csv",
    exact_body_sensitivity = "exact_body_sensitivity.csv",
    time_bins = "time_bins.csv",
    time_trend_model = "time_trend_model.csv"
  )
  if (nrow(alternative_summary) > 0) {
    tables <- c(tables, alternative_summary = "alternative_summary.csv")
  }
  if (nrow(term_order_summary) > 0) {
    tables <- c(tables, term_order_summary = "term_order_summary.csv")
  }
  if (file.exists(file.path(output_dir, "proximity_spans.csv"))) {
    tables <- c(tables, proximity_spans = "proximity_spans.csv", proximity_summary = "proximity_summary.csv")
  }
  if (!is.null(comparison_summary)) {
    tables <- c(tables, comparison_summary = "comparison_summary.csv", comparison_effects = "comparison_effects.csv")
  }

  comparison_json <- if (is.null(comparison_payload)) {
    "null"
  } else {
    paste0(
      "{",
      '"dimension":', json_scalar(comparison_payload$dimension), ",",
      '"left_group":', json_scalar(comparison_payload$left_group), ",",
      '"right_group":', json_scalar(comparison_payload$right_group), ",",
      '"summary_table":"comparison_summary.csv",',
      '"effects_table":"comparison_effects.csv",',
      '"chart_key":"scope_comparison"',
      "}"
    )
  }

  report <- paste0(
    "{",
    '"version":4,',
    '"profile":"standard_analysis",',
    '"generated_at":', json_scalar(format(Sys.time(), tz = "UTC", usetz = TRUE)), ",",
    '"overall":', json_object(as.list(overall_values)), ",",
    '"comparison":', comparison_json, ",",
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
