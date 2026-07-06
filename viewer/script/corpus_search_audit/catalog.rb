# frozen_string_literal: true

module CorpusSearchAudit
  PROFILES = %w[smoke full overnight].freeze

  CASES = [
    {
      id: "environment_contract",
      group: "foundation",
      description: "Boot Rails and verify the corpus-search runtime, corpus root, database, ZIP support, and child Ruby analysis runtime.",
      profiles: PROFILES,
      type: "rails",
      slow_after: 600,
      stall_after: 900,
      timeout: 1_800
    },
    {
      id: "application_eager_load",
      group: "foundation",
      description: "Eager-load the application so autoloading and constant-name failures are reported before feature tests.",
      profiles: PROFILES,
      type: "rails",
      slow_after: 600,
      stall_after: 900,
      timeout: 1_800
    },
    {
      id: "existing_search_tests",
      group: "foundation",
      description: "Run every existing focused corpus-search test supplied with the application.",
      profiles: PROFILES,
      type: "rails_test",
      paths: ["test/services/corpus_search", "test/services/grammar/corpus_search_definition_test.rb"],
      slow_after: 600,
      stall_after: 1_200,
      timeout: 3_600
    },
    {
      id: "route_and_form_contract",
      group: "web",
      description: "Verify named routes and the rendered search form for exact, proximity, OR, filters, roles, and analysis controls.",
      profiles: PROFILES,
      type: "rails",
      slow_after: 600,
      stall_after: 900,
      timeout: 1_800
    },
    {
      id: "synthetic_manifest_roles",
      group: "synthetic",
      description: "Build a known synthetic corpus and verify manifest metadata, body-only parsing, and every searchable document role.",
      profiles: PROFILES,
      type: "rails",
      slow_after: 600,
      stall_after: 900,
      timeout: 1_800
    },
    {
      id: "synthetic_exact_matrix",
      group: "synthetic",
      description: "Exercise exact search, punctuation modes, character equivalence, offsets, pagination, context, and invalid input.",
      profiles: PROFILES,
      type: "rails",
      slow_after: 600,
      stall_after: 900,
      timeout: 1_800
    },
    {
      id: "synthetic_or_matrix",
      group: "synthetic",
      description: "Exercise Alternatives (OR), duplicate and overlapping alternatives, term limits, offsets, and body-only matching.",
      profiles: PROFILES,
      type: "rails",
      slow_after: 600,
      stall_after: 900,
      timeout: 1_800
    },
    {
      id: "synthetic_proximity_matrix",
      group: "synthetic",
      description: "Exercise entered/any order, repeated terms, two-to-ten terms, span boundaries, punctuation normalization, and misses.",
      profiles: PROFILES,
      type: "rails",
      slow_after: 600,
      stall_after: 900,
      timeout: 1_800
    },
    {
      id: "synthetic_scope_filters",
      group: "synthetic",
      description: "Exercise include/exclude folders, nation, period, region, author, year ranges, and combined corpus layers.",
      profiles: PROFILES,
      type: "rails",
      slow_after: 600,
      stall_after: 900,
      timeout: 1_800
    },
    {
      id: "synthetic_cache_index",
      group: "synthetic",
      description: "Verify cold/warm query caches, stale-file invalidation, term indexes, corrupted caches, and manifest refreshes.",
      profiles: ["full", "overnight"],
      type: "rails",
      slow_after: 600,
      stall_after: 1_200,
      timeout: 2_400
    },
    {
      id: "synthetic_fault_tolerance",
      group: "failure",
      description: "Inject missing files, invalid UTF-8, symlinks, corrupt JSON, traversal attempts, and malformed requests without aborting later checks.",
      profiles: ["full", "overnight"],
      type: "rails",
      slow_after: 600,
      stall_after: 1_200,
      timeout: 2_400
    },
    {
      id: "analysis_runtime_failure_modes",
      group: "failure",
      description: "Verify unavailable, failed, malformed, and timed-out Ruby analysis processes are contained and leave useful diagnostics.",
      profiles: ["full", "overnight"],
      type: "rails",
      slow_after: 600,
      stall_after: 900,
      timeout: 1_800
    },
    {
      id: "synthetic_export_exact",
      group: "export",
      description: "Prepare an exact-search export and inspect every CSV, JSON, checksum, ZIP member, analysis table, SVG, and PNG.",
      profiles: ["full", "overnight"],
      type: "rails",
      slow_after: 600,
      stall_after: 1_800,
      timeout: 7_200,
      analysis_timeout: 3_600
    },
    {
      id: "synthetic_export_or",
      group: "export",
      description: "Prepare an OR export and verify alternative contribution tables, charts, rows, and provenance.",
      profiles: ["full", "overnight"],
      type: "rails",
      slow_after: 600,
      stall_after: 1_800,
      timeout: 7_200,
      analysis_timeout: 3_600
    },
    {
      id: "synthetic_export_proximity",
      group: "export",
      description: "Prepare a proximity export and verify spans, observed term order, context fields, and proximity diagrams.",
      profiles: ["full", "overnight"],
      type: "rails",
      slow_after: 600,
      stall_after: 1_800,
      timeout: 7_200,
      analysis_timeout: 3_600
    },
    {
      id: "synthetic_comparison",
      group: "export",
      description: "Reuse a frozen dataset for a two-scope comparison and verify no corpus rescan, effect tables, and comparison figures.",
      profiles: ["full", "overnight"],
      type: "rails",
      slow_after: 600,
      stall_after: 1_800,
      timeout: 7_200,
      analysis_timeout: 3_600
    },
    {
      id: "synthetic_http_flow",
      group: "web",
      description: "Exercise live exact/OR/proximity pages plus prepare, queued status, job execution, frozen page, bad key, and ZIP download.",
      profiles: ["full", "overnight"],
      type: "rails",
      slow_after: 600,
      stall_after: 1_800,
      timeout: 7_200,
      analysis_timeout: 3_600
    },
    {
      id: "real_manifest_integrity",
      group: "real corpus",
      description: "Audit the real manifest for duplicate IDs, missing files, unsafe paths, role inconsistencies, encoding failures, and metadata shape.",
      profiles: ["full", "overnight"],
      type: "rails",
      slow_after: 600,
      stall_after: 1_800,
      timeout: 10_800
    },
    {
      id: "real_interactive_queries",
      group: "real corpus",
      description: "Run ordinary 三字經, 詩經, OR, proximity, punctuation, equivalence, pagination, and no-hit searches against the real corpus.",
      profiles: ["full", "overnight"],
      type: "rails",
      slow_after: 600,
      stall_after: 1_800,
      timeout: 10_800
    },
    {
      id: "real_cache_warm_cold",
      group: "real corpus",
      description: "Compare cold and warm timings/results for representative exact, OR, and proximity searches and flag regressions.",
      profiles: ["overnight"],
      type: "rails",
      slow_after: 600,
      stall_after: 2_400,
      timeout: 14_400
    },
    {
      id: "real_scoped_export_or",
      group: "real corpus",
      description: "Run a Ruby-backed OR analysis over a real, automatically selected manageable corpus branch.",
      profiles: ["overnight"],
      type: "rails",
      slow_after: 600,
      stall_after: 2_400,
      timeout: 21_600,
      analysis_timeout: 7_200
    },
    {
      id: "real_scoped_export_proximity",
      group: "real corpus",
      description: "Run a Ruby-backed proximity analysis over a real, automatically selected manageable corpus branch.",
      profiles: ["overnight"],
      type: "rails",
      slow_after: 600,
      stall_after: 2_400,
      timeout: 21_600,
      analysis_timeout: 7_200
    },
    {
      id: "real_full_export_exact",
      group: "real corpus",
      description: "Perform one full-scope prepared exact analysis, including every document denominator and all analysis artefacts.",
      profiles: ["overnight"],
      type: "rails",
      slow_after: 600,
      stall_after: 3_600,
      timeout: 43_200,
      analysis_timeout: 14_400
    },
    {
      id: "real_reused_comparison",
      group: "real corpus",
      description: "Reuse the full frozen dataset for a real two-group comparison without rescanning the corpus.",
      profiles: ["overnight"],
      type: "rails",
      slow_after: 600,
      stall_after: 2_400,
      timeout: 14_400,
      analysis_timeout: 7_200
    },
    {
      id: "external_localhost_smoke",
      group: "web",
      description: "Optionally verify a separately running localhost server through real HTTP when CORPUS_SEARCH_AUDIT_BASE_URL is set.",
      profiles: ["full", "overnight"],
      type: "rails",
      slow_after: 600,
      stall_after: 900,
      timeout: 1_800
    },
    {
      id: "cross_artifact_audit",
      group: "reporting",
      description: "Re-open every export produced during the run and cross-check manifests, hashes, ZIP members, images, and structured files.",
      profiles: ["full", "overnight"],
      type: "rails",
      slow_after: 600,
      stall_after: 1_800,
      timeout: 7_200
    }
  ].freeze

  module_function

  def cases_for(profile)
    raise ArgumentError, "Unknown profile: #{profile}" unless PROFILES.include?(profile)

    CASES.select { |entry| entry.fetch(:profiles).include?(profile) }
  end

  def find_case(id)
    CASES.find { |entry| entry.fetch(:id) == id.to_s }
  end
end
