library(readr)
library(tidyverse)

build_lc_frequency <- function(
    root,
    output = "LC_frequency_list.csv",
    exclude_dirs = c("suspected_baihua"),
    include_categories = NULL,
    sample_files = NULL,
    progress_every = 1000,
    encoding = "UTF-8",   # set this based on guess_encoding()
    verbose = TRUE,
    hanzi_only = TRUE      # filter to CJK ranges
) {
  # ---- Dependency checks ----------------------------------------------------
  for (pkg in c("readr", "tibble", "dplyr")) {
    if (!requireNamespace(pkg, quietly = TRUE)) {
      stop("Package '", pkg, "' is required but not installed.")
    }
  }
  
  # is_hanzi 
  # Updated for Extension J and related
  # This is designed to exclude standard punctuation and Latin characters.
  is_hanzi <- function(ch) {
    cp <- utf8ToInt(ch)
    
    (
      (0x4E00 <= cp & cp <= 0x9FFF)   ||  # Basic CJK Unified Ideographs
        (0x3400 <= cp & cp <= 0x4DBF)   ||  # Extension A
        (0x20000 <= cp & cp <= 0x2A6DF) ||  # Extension B
        (0x2A700 <= cp & cp <= 0x2B73F) ||  # Extension C
        (0x2B740 <= cp & cp <= 0x2B81D) ||  # Extension D
        (0x2B820 <= cp & cp <= 0x2CEAD) ||  # Extension E
        (0x2CEB0 <= cp & cp <= 0x2EBE0) ||  # Extension F
        (0x31350 <= cp & cp <= 0x323AF) ||  # Extension H
        (0x2EBF0 <= cp & cp <= 0x2EE5D) ||  # Extension I
        (0x323B0 <= cp & cp <= 0x33479) ||  # Extension J
        (0x2F800 <= cp & cp <= 0x2FA1F)     # Compatibility Supplement
    )
  }
  
  # Normalise root
  root <- normalizePath(root, winslash = "/", mustWork = TRUE)
  if (verbose) {
    cat("Root corpus directory:\n  ", root, "\n\n")
  }
  
  # Find text files
  # Limited to .txt.
  if (verbose) cat("Searching for text files...\n")
  
  files <- list.files(
    root,
    full.names = TRUE,
    pattern = "\\.txt$",
    recursive = TRUE
  )
  
  if (verbose) cat("Found", length(files), "total files.\n")
  
  if (length(files) == 0) {
    stop("No .txt files found under root. Check the path and/or file extensions.")
  }
  
  # Exclude suspected_baihua/
  if (!is.null(exclude_dirs) && length(exclude_dirs) > 0) {
    pattern  <- paste(exclude_dirs, collapse = "|")
    keep_idx <- !grepl(pattern, files)
    removed  <- sum(!keep_idx)
    files    <- files[keep_idx]
    if (verbose) {
      cat("  Excluding paths matching: ", pattern, "\n", sep = "")
      cat("  Removed", removed, "files. Remaining:", length(files), "\n")
    }
  }
  
  # Build relative paths & categories
  files_norm   <- normalizePath(files, winslash = "/", mustWork = TRUE)
  root_pattern <- paste0("^", root, "/?")
  
  rel_paths  <- sub(root_pattern, "", files_norm)
  categories <- sub("/.*$", "", rel_paths)  # first folder under root
  
  file_table <- tibble::tibble(
    file     = files_norm,
    rel_path = rel_paths,
    category = categories
  )
  
  if (verbose) {
    cat("\nCategory summary (top 10):\n")
    print(
      file_table |>
        dplyr::count(category, sort = TRUE) |>
        dplyr::slice_head(n = 10)
    )
  }
  
  # Optional category filter
  if (!is.null(include_categories)) {
    before <- nrow(file_table)
    file_table <- dplyr::filter(file_table, category %in% include_categories)
    after  <- nrow(file_table)
    if (verbose) {
      cat("\nFiltering to categories:",
          paste(include_categories, collapse = ", "), "\n")
      cat("  Files before:", before, " | after:", after, "\n")
    }
  }
  
  # Optional sampling
  if (!is.null(sample_files)) {
    if (sample_files < nrow(file_table)) {
      set.seed(42)
      idx <- sample(seq_len(nrow(file_table)), sample_files)
      file_table <- file_table[idx, , drop = FALSE]
      if (verbose) {
        cat("\nSampling", sample_files, "files from corpus.\n")
      }
    } else if (verbose) {
      cat("\nℹ sample_files >=", nrow(file_table),
          "so using all files instead of sampling.\n")
    }
  }
  
  n_files <- nrow(file_table)
  if (verbose) cat("\nReady to process", n_files, "files!\n\n")
  
  # Character counting loop
  if (verbose) cat("Starting character frequency accumulation...\n")
  
  char_counts <- integer(0)  # named integer vector
  
  # Sanity check encoding on first file
  if (verbose && n_files > 0) {
    cat("Sanity check on encoding using first file:\n")
    test_txt <- readr::read_file(
      file_table$file[1],
      locale = readr::locale(encoding = encoding)
    )
    cat(substr(test_txt, 1, 200), "\n\n")
  }
  
  for (i in seq_len(n_files)) {
    f <- file_table$file[i]
    
    if (verbose && (i == 1 || i %% progress_every == 0 || i == n_files)) {
      cat("  File", i, "of", n_files, ":\n    ", f, "\n")
    }
    
    txt <- readr::read_file(f, locale = readr::locale(encoding = encoding))
    
    # Split into characters (proper UTF-8, not bytewise)
    ch <- strsplit(txt, "")[[1]]
    
    # Optionally keep only CJK Han characters
    if (hanzi_only) {
      if (length(ch) == 0) next
      ch <- ch[sapply(ch, is_hanzi)]
    }
    
    if (length(ch) == 0) next
    
    tab <- table(ch)
    nm  <- names(tab)
    
    existing <- char_counts[nm]
    existing[is.na(existing)] <- 0L
    char_counts[nm] <- existing + as.integer(tab)
  }
  
  if (verbose) {
    cat("\nFinished scanning corpus.\n")
    cat("  Unique characters:", length(char_counts), "\n")
  }
  
  # Build frequency table
  freq <- tibble::tibble(
    chars = names(char_counts),
    n     = as.integer(char_counts)
  ) |>
    dplyr::arrange(dplyr::desc(n))
  
  if (verbose && nrow(freq) > 0) {
    cat("  Most frequent character:", freq$chars[1],
        "with", freq$n[1], "occurrences.\n")
  }
  
  # write_excel_csv() writes UTF-8 WITH BOM so Excel doesn't explode
  readr::write_excel_csv(freq, output)
  
  if (verbose) {
    cat("\nSaved frequency list to:\n  ",
        normalizePath(output, winslash = "/"), "\n", sep = "")
  }
  
  return(freq)
}


freq <- build_lc_frequency(
  root = "C:/Users/chipp/OneDrive/Documents/fanyahanwen-corpus/",
  output = "LC_frequency_list.csv",
  exclude_dirs = c("suspected_baihua"),
  progress_every = 1000,
  encoding = "UTF-8",   # or "BIG5"/"GB18030" etc. based on guess_encoding()
  verbose = TRUE,
  hanzi_only = TRUE
)
