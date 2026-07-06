# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "timeout"
require "time"
require "tmpdir"

module CorpusSearch
  # Runs only application-owned Ruby analysis profiles in a separate process.
  #
  # This is a service boundary: Rails prepares trusted CSV inputs, then a child
  # Ruby process performs the expensive analysis. A timeout or memory failure in
  # that child is recorded without terminating the web request process.
  class AnalysisRunner
    PROFILE_PATHS = {
      "standard_analysis" => Rails.root.join("analysis", "ruby", "profiles", "standard_analysis.rb")
    }.freeze

    Result = Data.define(
      :status, :profile, :exit_status, :duration_seconds, :ruby_version,
      :output_dir, :stdout_path, :stderr_path, :metadata_path
    ) do
      def success? = status == "complete"
      def available? = status != "unavailable"
      def runtime_version = ruby_version
    end

    DEFAULT_TIMEOUT_SECONDS = 600
    DEFAULT_MEMORY_MB = 1_024

    @runtime_mutex = Mutex.new
    @runtime_cache = {}

    class << self
      def runtime_version(executable)
        key = executable.to_s
        @runtime_mutex.synchronize { return @runtime_cache[key] if @runtime_cache.key?(key) }

        stdout, stderr, status = Open3.capture3(key, "-v")
        value = status.success? ? [stdout, stderr].join(" ").strip.gsub(/\s+/, " ") : nil
        @runtime_mutex.synchronize { @runtime_cache[key] = value }
        value
      rescue SystemCallError
        @runtime_mutex.synchronize { @runtime_cache[key] = nil }
        nil
      end

      def reset_runtime_cache!
        @runtime_mutex.synchronize { @runtime_cache.clear }
      end
    end

    def initialize(executable: ENV.fetch("CORPUS_SEARCH_RUBY", RbConfig.ruby),
                   timeout_seconds: integer_env("CORPUS_SEARCH_ANALYSIS_TIMEOUT", DEFAULT_TIMEOUT_SECONDS),
                   memory_mb: integer_env("CORPUS_SEARCH_ANALYSIS_MEMORY_MB", DEFAULT_MEMORY_MB))
      @executable = executable.to_s
      @timeout_seconds = [timeout_seconds.to_i, 1].max
      @memory_mb = [memory_mb.to_i, 0].max
    end

    def run(profile:, document_counts_path:, occurrences_path:, output_dir:, comparison_path: nil)
      profile_name = profile.to_s
      script_path = PROFILE_PATHS.fetch(profile_name) { raise ArgumentError, "Unknown analysis profile: #{profile_name}" }
      raise Errno::ENOENT, script_path.to_s unless script_path.file?

      document_counts = checked_input(document_counts_path)
      occurrences = checked_input(occurrences_path)
      comparison = comparison_path ? checked_input(comparison_path) : nil
      output = Pathname(output_dir).expand_path
      FileUtils.mkdir_p(output)
      copied_script = output.join("analysis.rb")
      FileUtils.cp(script_path, copied_script)

      stdout_path = output.join("stdout.txt")
      stderr_path = output.join("stderr.txt")
      metadata_path = output.join("run_metadata.json")
      warning_path = output.join("warnings.txt")
      FileUtils.touch([stdout_path, stderr_path])
      started_at = Time.now.utc
      monotonic_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      version = self.class.runtime_version(@executable)
      command = [@executable, copied_script.to_s, document_counts.to_s, occurrences.to_s, output.to_s]
      command << comparison.to_s if comparison

      unless version
        warning_path.write("Ruby was not available at the configured path. Set CORPUS_SEARCH_RUBY to the Ruby executable.\n")
        metadata = metadata_payload(
          status: "unavailable", profile: profile_name, started_at: started_at,
          duration_seconds: elapsed(monotonic_start), exit_status: nil,
          ruby_version: nil, command: command,
          inputs: [document_counts, occurrences, comparison].compact
        )
        metadata_path.write(JSON.pretty_generate(metadata))
        return result_from(metadata, output, stdout_path, stderr_path, metadata_path)
      end

      exit_status, timed_out = spawn_and_wait(command, output, stdout_path, stderr_path)
      status = if timed_out
        "timed_out"
      elsif exit_status&.success? && valid_report?(output.join("analysis_report.json"), profile_name)
        "complete"
      else
        "failed"
      end

      unless status == "complete" || warning_path.file?
        warning_path.write("Ruby analysis #{status}. See stderr.txt and run_metadata.json.\n")
      end

      metadata = metadata_payload(
        status: status, profile: profile_name, started_at: started_at,
        duration_seconds: elapsed(monotonic_start), exit_status: exit_status&.exitstatus,
        ruby_version: version, command: command,
        inputs: [document_counts, occurrences, comparison].compact
      )
      metadata_path.write(JSON.pretty_generate(metadata))
      result_from(metadata, output, stdout_path, stderr_path, metadata_path)
    rescue StandardError => error
      failure_result(error, profile: profile, output_dir: output_dir)
    end

    private

    def checked_input(path)
      input = Pathname(path).expand_path
      raise Errno::ENOENT, input.to_s unless input.file?

      input
    end

    def valid_report?(path, expected_profile)
      return false unless path.file?

      payload = JSON.parse(path.read(encoding: "UTF-8"))
      payload.is_a?(Hash) && payload["profile"].to_s == expected_profile && payload["overall"].is_a?(Hash)
    rescue JSON::ParserError, ArgumentError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
      false
    end

    def spawn_and_wait(command, output_dir, stdout_path, stderr_path)
      spawn_options = {
        chdir: output_dir.to_s,
        out: stdout_path.to_s,
        err: stderr_path.to_s,
        pgroup: true
      }
      spawn_options[:rlimit_cpu] = @timeout_seconds + 5 if Process.const_defined?(:RLIMIT_CPU)
      spawn_options[:rlimit_as] = @memory_mb * 1_024 * 1_024 if @memory_mb.positive? && Process.const_defined?(:RLIMIT_AS)

      pid = spawn_process(command, spawn_options)
      timed_out = false
      status = nil
      begin
        Timeout.timeout(@timeout_seconds) do
          _waited_pid, status = Process.wait2(pid)
        end
      rescue Timeout::Error
        timed_out = true
        terminate_process_group(pid)
        begin
          _waited_pid, status = Process.wait2(pid)
        rescue Errno::ECHILD
          status = nil
        end
      end
      [status, timed_out]
    end

    def spawn_process(command, options)
      Process.spawn(runtime_environment, *command, options)
    rescue ArgumentError
      # Some platforms do not support one or both rlimit spawn options. The
      # child remains bounded by the wall-clock timeout and its process group.
      Process.spawn(runtime_environment, *command, options.reject { |key, _value| %i[rlimit_cpu rlimit_as].include?(key) })
    end

    def terminate_process_group(pid)
      Process.kill("TERM", -pid)
      sleep 0.25
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH
      nil
    end

    def runtime_environment
      {
        "HOME" => Dir.tmpdir,
        "LANG" => ENV.fetch("LANG", "C.UTF-8"),
        "LC_ALL" => ENV.fetch("LC_ALL", ENV.fetch("LANG", "C.UTF-8"))
      }
    end

    def metadata_payload(status:, profile:, started_at:, duration_seconds:, exit_status:, ruby_version:, command:, inputs:)
      {
        "version" => 4,
        "status" => status,
        "profile" => profile,
        "started_at" => started_at.iso8601,
        "duration_seconds" => duration_seconds.round(4),
        "exit_status" => exit_status,
        "ruby_version" => ruby_version,
        "command" => command.map(&:to_s),
        "inputs" => inputs.map { |path| { "path" => path.to_s, "bytes" => path.file? ? path.size : nil } },
        "limits" => { "timeout_seconds" => @timeout_seconds, "memory_mb" => @memory_mb }
      }
    end

    def result_from(metadata, output, stdout_path, stderr_path, metadata_path)
      Result.new(
        status: metadata.fetch("status"),
        profile: metadata.fetch("profile"),
        exit_status: metadata["exit_status"],
        duration_seconds: metadata.fetch("duration_seconds"),
        ruby_version: metadata["ruby_version"],
        output_dir: output,
        stdout_path: stdout_path,
        stderr_path: stderr_path,
        metadata_path: metadata_path
      )
    end

    def failure_result(error, profile:, output_dir:)
      output = Pathname(output_dir).expand_path
      FileUtils.mkdir_p(output)
      metadata_path = output.join("run_metadata.json")
      output.join("warnings.txt").write("#{error.class}: #{error.message}\n")
      FileUtils.touch([output.join("stdout.txt"), output.join("stderr.txt")])
      metadata = metadata_payload(
        status: "failed", profile: profile.to_s, started_at: Time.now.utc,
        duration_seconds: 0.0, exit_status: nil, ruby_version: nil,
        command: [], inputs: []
      ).merge("error" => { "class" => error.class.name, "message" => error.message })
      metadata_path.write(JSON.pretty_generate(metadata))
      result_from(metadata, output, output.join("stdout.txt"), output.join("stderr.txt"), metadata_path)
    end

    def elapsed(start)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    end

    def self.integer_env(name, fallback)
      Integer(ENV.fetch(name, fallback))
    rescue ArgumentError, TypeError
      fallback
    end

    def integer_env(name, fallback)
      self.class.integer_env(name, fallback)
    end
  end
end
