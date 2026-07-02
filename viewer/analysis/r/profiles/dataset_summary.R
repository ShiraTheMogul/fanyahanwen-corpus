#!/usr/bin/env Rscript

# Application-owned Phase 6 validation profile.
#
# Inputs:
#   1. document_counts.csv created by AnalysisDatasetWriter
#   2. output directory
#

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2) {
  stop("Usage: Rscript --vanilla analysis.R document_counts.csv output_directory")
}

input_path <- normalizePath(args[[1]], mustWork = TRUE)
output_dir <- normalizePath(args[[2]], mustWork = TRUE)
started <- proc.time()[["elapsed"]]
warnings_seen <- character()

withCallingHandlers({
  data <- read.csv(input_path, stringsAsFactors = FALSE, check.names = FALSE)

  required <- c(
    "doc_id", "document_role", "searchable_characters", "occurrences",
    "matching_document"
  )
  missing <- setdiff(required, names(data))
  if (length(missing) > 0) {
    stop(paste("Missing required columns:", paste(missing, collapse = ", ")))
  }

  numeric_columns <- c("searchable_characters", "occurrences", "matching_document")
  for (column in numeric_columns) {
    data[[column]] <- as.numeric(data[[column]])
    data[[column]][is.na(data[[column]])] <- 0
  }

  total_documents <- nrow(data)
  matching_documents <- sum(data$matching_document > 0)
  total_occurrences <- sum(data$occurrences)
  searchable_characters <- sum(data$searchable_characters)

  overall <- data.frame(
    metric = c(
      "documents", "matching_documents", "occurrences",
      "searchable_characters", "document_prevalence",
      "occurrences_per_million"
    ),
    value = c(
      total_documents,
      matching_documents,
      total_occurrences,
      searchable_characters,
      if (total_documents > 0) matching_documents / total_documents else 0,
      if (searchable_characters > 0) total_occurrences / searchable_characters * 1000000 else 0
    ),
    stringsAsFactors = FALSE
  )
  write.csv(overall, file.path(output_dir, "summary.csv"), row.names = FALSE, na = "")

  roles <- sort(unique(data$document_role))
  role_rows <- lapply(roles, function(role) {
    subset <- data[data$document_role == role, , drop = FALSE]
    documents <- nrow(subset)
    matching <- sum(subset$matching_document > 0)
    occurrences <- sum(subset$occurrences)
    characters <- sum(subset$searchable_characters)

    data.frame(
      document_role = role,
      documents = documents,
      matching_documents = matching,
      occurrences = occurrences,
      searchable_characters = characters,
      document_prevalence = if (documents > 0) matching / documents else 0,
      occurrences_per_million = if (characters > 0) occurrences / characters * 1000000 else 0,
      stringsAsFactors = FALSE
    )
  })
  role_summary <- if (length(role_rows) > 0) do.call(rbind, role_rows) else data.frame()
  write.csv(role_summary, file.path(output_dir, "role_summary.csv"), row.names = FALSE, na = "")
}, warning = function(warning) {
  warnings_seen <<- c(warnings_seen, conditionMessage(warning))
  invokeRestart("muffleWarning")
})

writeLines(capture.output(sessionInfo()), file.path(output_dir, "sessionInfo.txt"), useBytes = TRUE)
writeLines(unique(warnings_seen), file.path(output_dir, "warnings.txt"), useBytes = TRUE)
write.csv(
  data.frame(elapsed_seconds = proc.time()[["elapsed"]] - started),
  file.path(output_dir, "timing.csv"),
  row.names = FALSE
)
