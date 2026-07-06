# frozen_string_literal: true

require_relative "catalog"
require_relative "cases"

$stdout.sync = true
$stderr.sync = true

case_id = ARGV.shift.to_s
entry = CorpusSearchAudit.find_case(case_id)
abort("Unknown corpus-search audit case: #{case_id.inspect}") unless entry

case_dir = Pathname(ENV.fetch("CORPUS_SEARCH_AUDIT_CASE_DIR")).expand_path
FileUtils.mkdir_p(case_dir)
ENV["CORPUS_SEARCH_AUDIT_CACHE_ROOT"] ||= case_dir.join("default_cache").to_s
I18n.locale = :en if I18n.available_locales.map(&:to_s).include?("en")

audit = CorpusSearchAudit::Audit.new(case_id: case_id, case_dir: case_dir)
result = nil
begin
  CorpusSearchAudit::Cases.run(case_id, audit)
  result = audit.finish
rescue CorpusSearchAudit::SkipCase => e
  result = audit.finish(status_override: "skipped", error: { "class" => e.class.name, "message" => e.message })
rescue Exception => e # rubocop:disable Lint/RescueException -- top-level audit containment
  detail = {
    "class" => e.class.name,
    "message" => e.message,
    "backtrace" => Array(e.backtrace).first(80)
  }
  warn("[audit][#{case_id}][fatal] #{e.class}: #{e.message}")
  result = audit.finish(status_override: "error", error: detail)
end

puts "[audit][#{case_id}] final status: #{result['status']}"
# Do not call Kernel#exit here. Rails 8.1 wraps runner scripts in an executor;
# raising SystemExit after the result is safely persisted can make the wrapper
# report an unrelated ExecutionContext error. The supervisor reads case_result.json.
