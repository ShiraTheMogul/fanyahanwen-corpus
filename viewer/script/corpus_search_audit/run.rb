#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "etc"
require "fileutils"
require "rubygems/package"
require "json"
require "optparse"
require "pathname"
require "rbconfig"
require "time"
require "zlib"
require "cgi"
require_relative "catalog"

module CorpusSearchAudit
  class Supervisor
    POLL_SECONDS = 2
    PROGRESS_PRINT_SECONDS = 30
    TERM_GRACE_SECONDS = 20
    KILL_GRACE_SECONDS = 10
    FAILURE_STATUSES = %w[failed error timed_out stalled unkillable interrupted].freeze

    def initialize(argv)
      @rails_root = Pathname(__dir__).join("../..").expand_path
      @options = {
        profile: "overnight",
        rails_env: "test",
        only: [],
        skip: [],
        slow_after: nil,
        stall_after: nil,
        timeout: nil,
        resume: nil,
        output: nil,
        base_url: ENV["CORPUS_SEARCH_AUDIT_BASE_URL"],
        ruby_path: ENV["CORPUS_SEARCH_RUBY"],
        real_cache_root: ENV["CORPUS_SEARCH_AUDIT_REAL_CACHE_ROOT"],
        list: false,
        supervisor_self_test: true
      }
      parse!(argv)
      @started_at = Time.now.utc
      @interrupted = false
      @received_signal = nil
      @active_pid = nil
      @active_case = nil
      @self_test = nil
    end

    def run
      if @options[:list]
        print_catalogue
        return 0
      end

      validate_profile!
      prepare_run_root!
      install_signal_handlers
      write_run_configuration
      @self_test = supervisor_self_test if @options[:supervisor_self_test]

      cases = selected_cases
      puts "Corpus-search audit: #{@options[:profile]} profile"
      puts "Run directory: #{@run_root}"
      puts "Cases selected: #{cases.length}"
      puts "Slow warning: #{human_duration(default_slow_after)}; stalled-work termination: per-case; hard timeout: per-case"
      puts

      results = []
      cases.each_with_index do |entry, index|
        break if @interrupted

        @active_case = entry.fetch(:id)
        puts "[#{index + 1}/#{cases.length}] #{@active_case}: #{entry.fetch(:description)}"
        result = run_or_resume_case(entry)
        results << result
        puts "  -> #{result['status']} in #{format('%.1f', result.fetch('duration_seconds', 0).to_f)}s"
        puts
      end

      report = write_reports(results, cases)
      puts "Audit report: #{report}"
      puts "Fix list: #{@run_root.join('FIXES_REQUIRED.md')}"
      puts "Machine-readable results: #{@run_root.join('report.json')}"
      puts "Compact diagnostics bundle: #{@run_root.join('corpus_search_audit_diagnostics.tar.gz')}"

      return 130 if @interrupted
      return 2 if @self_test && @self_test["status"] != "passed"

      results.any? { |row| FAILURE_STATUSES.include?(row["status"]) } ? 1 : 0
    ensure
      terminate_group(@active_pid, reason: "supervisor exiting") if @active_pid && process_group_alive?(@active_pid)
    end

    private

    def parse!(argv)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ruby script/corpus_search_audit/run.rb [options]"
        opts.on("--profile PROFILE", PROFILES, "smoke, full, or overnight (default: overnight)") { |value| @options[:profile] = value }
        opts.on("--output DIR", "New run directory (default: tmp/corpus_search_audit/<timestamp>)") { |value| @options[:output] = value }
        opts.on("--resume DIR", "Resume a prior run; passed/skipped cases are kept and failed cases rerun") { |value| @options[:resume] = value }
        opts.on("--only x,y,z", Array, "Run only the named case IDs") { |value| @options[:only] = value }
        opts.on("--skip x,y,z", Array, "Skip the named case IDs") { |value| @options[:skip] = value }
        opts.on("--slow-after SECONDS", Integer, "Override the ten-minute slow warning") { |value| @options[:slow_after] = value }
        opts.on("--stall-after SECONDS", Integer, "Override all inactivity/stall limits") { |value| @options[:stall_after] = value }
        opts.on("--timeout SECONDS", Integer, "Override all hard case limits") { |value| @options[:timeout] = value }
        opts.on("--rails-env ENV", "Rails environment for child cases (default: test)") { |value| @options[:rails_env] = value }
        opts.on("--base-url URL", "Also test a separately running localhost server") { |value| @options[:base_url] = value }
        opts.on("--ruby PATH", "Ruby executable used for child analysis profiles") { |value| @options[:ruby_path] = value }
        opts.on("--real-cache-root DIR", "Shared real-corpus cache directory, preferably on a native Linux filesystem") { |value| @options[:real_cache_root] = value }
        opts.on("--no-supervisor-self-test", "Skip the process-group kill self-test") { @options[:supervisor_self_test] = false }
        opts.on("--list", "List all available cases") { @options[:list] = true }
        opts.on("-h", "--help", "Show this help") do
          puts opts
          exit 0
        end
      end
      parser.parse!(argv)
    end

    def validate_profile!
      raise OptionParser::InvalidArgument, "unknown profile #{@options[:profile]}" unless PROFILES.include?(@options[:profile])
    end

    def prepare_run_root!
      @run_root = if @options[:resume]
        Pathname(@options[:resume]).expand_path
      elsif @options[:output]
        Pathname(@options[:output]).expand_path
      else
        @rails_root.join("tmp", "corpus_search_audit", @started_at.strftime("%Y%m%dT%H%M%SZ"))
      end
      FileUtils.mkdir_p(@run_root.join("cases"))
      FileUtils.mkdir_p(@run_root.join("shared"))
    end

    def selected_cases
      cases = CorpusSearchAudit.cases_for(@options[:profile])
      only = @options[:only].map(&:to_s)
      skip = @options[:skip].map(&:to_s)
      cases = cases.select { |entry| only.include?(entry.fetch(:id)) } if only.any?
      cases.reject { |entry| skip.include?(entry.fetch(:id)) }
    end

    def run_or_resume_case(entry)
      case_dir = @run_root.join("cases", entry.fetch(:id))
      normalized_path = case_dir.join("result.json")
      if @options[:resume] && normalized_path.file?
        previous = parse_json(normalized_path)
        if previous && %w[passed skipped].include?(previous["status"])
          puts "  Reusing previous #{previous['status']} result."
          return previous.merge("resumed" => true)
        end
        FileUtils.rm_rf(case_dir)
      end
      FileUtils.mkdir_p(case_dir)
      run_case(entry, case_dir)
    end

    def run_case(entry, case_dir)
      stdout_path = case_dir.join("stdout.log")
      stderr_path = case_dir.join("stderr.log")
      events_path = case_dir.join("supervisor_events.jsonl")
      command = command_for(entry)
      environment = child_environment(entry, case_dir)
      started_at = Time.now.utc
      monotonic_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      slow_after = @options[:slow_after] || entry.fetch(:slow_after, default_slow_after)
      stall_after = @options[:stall_after] || entry.fetch(:stall_after, 1_800)
      hard_timeout = @options[:timeout] || entry.fetch(:timeout, 7_200)

      event(events_path, "started", command: command, slow_after: slow_after, stall_after: stall_after, hard_timeout: hard_timeout)
      stdout_io = File.open(stdout_path, "ab")
      stderr_io = File.open(stderr_path, "ab")
      pid = Process.spawn(environment, *command, chdir: @rails_root.to_s, out: stdout_io, err: stderr_io, pgroup: true)
      @active_pid = pid
      previous_activity = group_activity(pid, case_dir)
      last_progress = monotonic_start
      last_print = monotonic_start
      slow_warned = false
      termination_reason = nil
      exit_status = nil
      peak_rss = 0
      peak_processes = 0
      samples = []

      loop do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        elapsed = now - monotonic_start
        waited = wait_nonblock(pid)
        if waited
          exit_status = waited
          break
        end

        if @interrupted
          termination_reason = "interrupted"
          event(events_path, "interrupted", signal: @received_signal, elapsed_seconds: elapsed.round(2))
          puts "  Received #{@received_signal || 'signal'}; terminating this case and preserving the partial report."
          break
        end

        activity = group_activity(pid, case_dir)
        peak_rss = [peak_rss, activity[:rss_bytes]].max
        peak_processes = [peak_processes, activity[:process_count]].max
        samples << activity.merge(at_seconds: elapsed.round(2)) if samples.empty? || elapsed - samples.last.fetch(:at_seconds).to_f >= 60

        if activity[:token] != previous_activity[:token]
          previous_activity = activity
          last_progress = now
        end

        unless slow_warned
          if elapsed >= slow_after
            slow_warned = true
            event(events_path, "slow_warning", elapsed_seconds: elapsed.round(2), activity: activity.reject { |key, _value| key == :token })
            puts "  WARNING: #{@active_case} has exceeded #{human_duration(slow_after)}; it will continue while making progress."
          end
        end

        if elapsed >= hard_timeout
          termination_reason = "timed_out"
          event(events_path, "hard_timeout", elapsed_seconds: elapsed.round(2), activity: activity.reject { |key, _value| key == :token })
          break
        elsif now - last_progress >= stall_after
          termination_reason = "stalled"
          event(events_path, "stall_timeout", inactive_seconds: (now - last_progress).round(2), activity: activity.reject { |key, _value| key == :token })
          break
        end

        if now - last_print >= PROGRESS_PRINT_SECONDS
          heartbeat = read_heartbeat(case_dir)
          puts "  running #{human_duration(elapsed)} | processes #{activity[:process_count]} | RSS #{human_bytes(activity[:rss_bytes])} | #{heartbeat || 'no heartbeat yet'}"
          last_print = now
        end
        sleep POLL_SECONDS
      end

      if termination_reason
        kill_result = terminate_group(pid, reason: termination_reason, events_path: events_path)
        termination_reason = "unkillable" unless kill_result
        exit_status ||= wait_nonblock(pid)
      elsif process_group_alive?(pid)
        event(events_path, "leaked_children", message: "Leader exited but process group remains")
        terminate_group(pid, reason: "leaked child processes", events_path: events_path)
      end

      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - monotonic_start
      stdout_io.close
      stderr_io.close
      @active_pid = nil

      result = load_child_result(entry, case_dir, exit_status, started_at, duration)
      result["status"] = termination_reason if termination_reason
      result["supervisor"] = {
        "command" => command,
        "pid" => pid,
        "exit_status" => exit_status&.exitstatus,
        "termsig" => exit_status&.termsig,
        "slow_warning" => slow_warned,
        "slow_after_seconds" => slow_after,
        "stall_after_seconds" => stall_after,
        "hard_timeout_seconds" => hard_timeout,
        "termination_reason" => termination_reason,
        "peak_rss_bytes" => peak_rss,
        "peak_processes" => peak_processes,
        "stdout_log" => stdout_path.to_s,
        "stderr_log" => stderr_path.to_s,
        "events_log" => events_path.to_s,
        "resource_samples" => samples.last(240)
      }.compact
      result["warnings"] ||= []
      if slow_warned
        result["warnings"] << {
          "message" => "Case exceeded the #{slow_after}-second slow-search threshold but continued while progress was observable.",
          "data" => { "duration_seconds" => duration.round(2) }
        }
      end
      if termination_reason
        result["error"] ||= {}
        result["error"]["supervisor"] = "Case terminated as #{termination_reason}; inspect stdout.log, stderr.log, heartbeat.json, and supervisor_events.jsonl."
      end
      result["duration_seconds"] = duration.round(4)
      result["started_at"] ||= started_at.iso8601
      result["ended_at"] = Time.now.utc.iso8601
      result["description"] = entry.fetch(:description)
      result["group"] = entry.fetch(:group)
      File.write(case_dir.join("result.json"), JSON.pretty_generate(result))
      result
    rescue Exception => e # rubocop:disable Lint/RescueException -- supervisor must continue to later cases
      @active_pid = nil
      stdout_io&.close unless stdout_io&.closed?
      stderr_io&.close unless stderr_io&.closed?
      result = {
        "case_id" => entry.fetch(:id),
        "group" => entry.fetch(:group),
        "description" => entry.fetch(:description),
        "status" => "error",
        "started_at" => started_at&.iso8601,
        "ended_at" => Time.now.utc.iso8601,
        "duration_seconds" => monotonic_start ? (Process.clock_gettime(Process::CLOCK_MONOTONIC) - monotonic_start).round(4) : 0,
        "error" => { "class" => e.class.name, "message" => e.message, "backtrace" => Array(e.backtrace).first(80) },
        "assertions" => [],
        "warnings" => []
      }
      FileUtils.mkdir_p(case_dir)
      File.write(case_dir.join("result.json"), JSON.pretty_generate(result))
      result
    end

    def command_for(entry)
      rails = @rails_root.join("bin/rails").to_s
      if entry.fetch(:type) == "rails_test"
        [RbConfig.ruby, rails, "test", *entry.fetch(:paths)]
      else
        [
          RbConfig.ruby,
          rails,
          "runner",
          @rails_root.join("script/corpus_search_audit/case_runner.rb").to_s,
          entry.fetch(:id)
        ]
      end
    end

    def child_environment(entry, case_dir)
      corpus_root = ENV["CORPUS_ROOT"].to_s
      corpus_root = @rails_root.join("..", "corpus").expand_path.to_s if corpus_root.empty?
      environment = {
        "RAILS_ENV" => @options[:rails_env],
        "CORPUS_ROOT" => corpus_root,
        "CORPUS_SEARCH_AUDIT_RUN_ROOT" => @run_root.to_s,
        "CORPUS_SEARCH_AUDIT_PROFILE" => @options[:profile],
        "CORPUS_SEARCH_AUDIT_CASE_DIR" => case_dir.to_s,
        "CORPUS_SEARCH_AUDIT_CACHE_ROOT" => case_dir.join("default_cache").to_s,
        "CORPUS_SEARCH_PROGRESS_EVERY" => ENV.fetch("CORPUS_SEARCH_PROGRESS_EVERY", "500"),
        "CORPUS_SEARCH_DIR_PROGRESS_EVERY" => ENV.fetch("CORPUS_SEARCH_DIR_PROGRESS_EVERY", "500"),
        "CORPUS_SEARCH_ANALYSIS_TIMEOUT" => (entry[:analysis_timeout] || ENV["CORPUS_SEARCH_ANALYSIS_TIMEOUT"] || 3_600).to_s,
        "CORPUS_SEARCH_ANALYSIS_MEMORY_MB" => ENV.fetch("CORPUS_SEARCH_ANALYSIS_MEMORY_MB", "2048"),
        "LANG" => ENV.fetch("LANG", "C.UTF-8"),
        "LC_ALL" => ENV.fetch("LC_ALL", ENV.fetch("LANG", "C.UTF-8"))
      }
      environment["CORPUS_SEARCH_RUBY"] = @options[:ruby_path] if @options[:ruby_path].to_s != ""
      environment["CORPUS_SEARCH_AUDIT_REAL_CACHE_ROOT"] = @options[:real_cache_root] if @options[:real_cache_root].to_s != ""
      environment["CORPUS_SEARCH_AUDIT_BASE_URL"] = @options[:base_url] if @options[:base_url].to_s != ""
      environment
    end

    def load_child_result(entry, case_dir, exit_status, started_at, duration)
      path = case_dir.join("case_result.json")
      if path.file?
        parsed = parse_json(path)
        return parsed if parsed
      end

      if entry.fetch(:type) == "rails_test"
        success = exit_status&.success?
        return {
          "case_id" => entry.fetch(:id),
          "status" => success ? "passed" : "failed",
          "started_at" => started_at.iso8601,
          "duration_seconds" => duration.round(4),
          "assertion_counts" => { success ? "pass" : "fail" => 1 },
          "assertions" => [{
            "status" => success ? "pass" : "fail",
            "name" => "existing Rails corpus-search tests",
            "expected" => "exit status 0",
            "actual" => exit_status&.exitstatus
          }],
          "warnings" => [],
          "metrics" => {},
          "artifacts" => []
        }
      end

      {
        "case_id" => entry.fetch(:id),
        "status" => exit_status&.success? ? "error" : "failed",
        "started_at" => started_at.iso8601,
        "duration_seconds" => duration.round(4),
        "assertions" => [],
        "warnings" => [],
        "metrics" => {},
        "artifacts" => [],
        "error" => {
          "message" => "Child did not write case_result.json",
          "exit_status" => exit_status&.exitstatus,
          "termsig" => exit_status&.termsig
        }
      }
    end

    def group_activity(pgid, case_dir)
      pids = process_group_pids(pgid)
      cpu_ticks = 0
      io_bytes = 0
      rss_bytes = 0
      states = Hash.new(0)
      pids.each do |pid|
        stat = proc_stat(pid)
        next unless stat

        cpu_ticks += stat[:cpu_ticks]
        states[stat[:state]] += 1
        io_bytes += proc_io_bytes(pid)
        rss_bytes += proc_rss_bytes(pid)
      end
      log_bytes = %w[stdout.log stderr.log].sum do |name|
        path = case_dir.join(name)
        path.file? ? path.size : 0
      end
      heartbeat = case_dir.join("heartbeat.json")
      heartbeat_marker = heartbeat.file? ? [heartbeat.size, heartbeat.mtime.to_f] : [0, 0]
      result = case_dir.join("case_result.json")
      result_marker = result.file? ? [result.size, result.mtime.to_f] : [0, 0]
      {
        process_count: pids.length,
        pids: pids,
        cpu_ticks: cpu_ticks,
        io_bytes: io_bytes,
        rss_bytes: rss_bytes,
        states: states,
        log_bytes: log_bytes,
        heartbeat: heartbeat_marker,
        result: result_marker,
        token: [cpu_ticks, io_bytes, log_bytes, heartbeat_marker, result_marker]
      }
    rescue StandardError
      {
        process_count: 0,
        pids: [],
        cpu_ticks: 0,
        io_bytes: 0,
        rss_bytes: 0,
        states: {},
        log_bytes: 0,
        heartbeat: [0, 0],
        result: [0, 0],
        token: [0, 0, 0, [0, 0], [0, 0]]
      }
    end

    def process_group_pids(pgid)
      Dir.glob("/proc/[0-9]*/stat").filter_map do |path|
        stat = parse_proc_stat_file(path)
        stat[:pid] if stat && stat[:pgrp] == pgid.to_i
      end
    rescue StandardError
      []
    end

    def proc_stat(pid)
      parse_proc_stat_file("/proc/#{pid}/stat")
    end

    def parse_proc_stat_file(path)
      content = File.read(path)
      close = content.rindex(")")
      return nil unless close

      pid = content[0...content.index(" ")].to_i
      rest = content[(close + 2)..].to_s.split
      {
        pid: pid,
        state: rest[0],
        pgrp: rest[2].to_i,
        cpu_ticks: rest[11].to_i + rest[12].to_i
      }
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def proc_io_bytes(pid)
      File.readlines("/proc/#{pid}/io").sum do |line|
        key, value = line.split(":", 2)
        %w[read_bytes write_bytes].include?(key) ? value.to_i : 0
      end
    rescue Errno::ENOENT, Errno::EACCES
      0
    end

    def proc_rss_bytes(pid)
      line = File.foreach("/proc/#{pid}/status").find { |row| row.start_with?("VmRSS:") }
      line.to_s.split[1].to_i * 1_024
    rescue Errno::ENOENT, Errno::EACCES
      0
    end

    def wait_nonblock(pid)
      waited_pid, status = Process.waitpid2(pid, Process::WNOHANG)
      waited_pid ? status : nil
    rescue Errno::ECHILD
      nil
    end

    def process_group_alive?(pgid)
      return false unless pgid

      stats = process_group_stats(pgid)
      return stats.any? { |stat| stat[:state] != "Z" } if File.directory?("/proc")

      Process.kill(0, -pgid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def process_group_stats(pgid)
      Dir.glob("/proc/[0-9]*/stat").filter_map do |path|
        stat = parse_proc_stat_file(path)
        stat if stat && stat[:pgrp] == pgid.to_i
      end
    rescue StandardError
      []
    end

    def terminate_group(pgid, reason:, events_path: nil)
      return true unless pgid

      event(events_path, "terminate", reason: reason, signal: "TERM") if events_path
      Process.kill("TERM", -pgid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TERM_GRACE_SECONDS
      while process_group_alive?(pgid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.25
      end
      return true unless process_group_alive?(pgid)

      event(events_path, "terminate", reason: reason, signal: "KILL") if events_path
      Process.kill("KILL", -pgid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + KILL_GRACE_SECONDS
      while process_group_alive?(pgid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.25
      end
      !process_group_alive?(pgid)
    rescue Errno::ESRCH
      true
    rescue StandardError => e
      event(events_path, "termination_error", reason: reason, error: "#{e.class}: #{e.message}") if events_path
      false
    end

    def supervisor_self_test
      directory = @run_root.join("supervisor_self_test")
      FileUtils.mkdir_p(directory)

      # Check 1: a parent and its child are both removed by process-group
      # termination. This is the mechanism used for a hung Rails/R export.
      hanging_script = <<~'RUBY'
        child = Process.spawn(RbConfig.ruby, "-e", "sleep 60")
        File.write(ARGV.fetch(0), child.to_s)
        sleep 60
      RUBY
      child_marker = directory.join("child_pid.txt")
      hanging_pid = Process.spawn(
        RbConfig.ruby, "-rrbconfig", "-e", hanging_script, child_marker.to_s,
        out: directory.join("hang_stdout.log").to_s,
        err: directory.join("hang_stderr.log").to_s,
        pgroup: true
      )
      sleep 0.5
      child_pid = child_marker.file? ? child_marker.read.to_i : nil
      killed = terminate_group(hanging_pid, reason: "supervisor self-test")
      sleep 0.25
      leader_alive = process_alive?(hanging_pid)
      child_alive = child_pid && process_alive?(child_pid)

      # Check 2: a failed child is observed, then an unrelated later child is
      # still launched successfully. This protects the overnight audit's
      # central promise: one broken case must not stop the remaining cases.
      failing_pid = Process.spawn(RbConfig.ruby, "-e", "exit 7", pgroup: true)
      _failed_wait_pid, failed_status = Process.wait2(failing_pid)
      continuation_marker = directory.join("continued_after_failure.txt")
      continuing_pid = Process.spawn(
        RbConfig.ruby, "-e", "File.write(ARGV.fetch(0), 'continued')", continuation_marker.to_s,
        pgroup: true
      )
      _continued_wait_pid, continued_status = Process.wait2(continuing_pid)
      continued = failed_status.exitstatus == 7 && continued_status.success? && continuation_marker.read == "continued"

      passed = killed && !leader_alive && !child_alive && continued
      payload = {
        "status" => passed ? "passed" : "failed",
        "process_group_termination" => {
          "leader_pid" => hanging_pid,
          "child_pid" => child_pid,
          "kill_returned" => killed,
          "leader_alive" => leader_alive,
          "child_alive" => child_alive
        },
        "continue_after_failure" => {
          "failed_exit_status" => failed_status.exitstatus,
          "later_case_exit_status" => continued_status.exitstatus,
          "marker_written" => continuation_marker.file?,
          "passed" => continued
        },
        "checked_at" => Time.now.utc.iso8601
      }
      File.write(directory.join("result.json"), JSON.pretty_generate(payload))
      puts "Supervisor self-test (kill tree + continue after failure): #{payload['status']}"
      payload
    rescue StandardError => e
      payload = { "status" => "failed", "error" => "#{e.class}: #{e.message}", "checked_at" => Time.now.utc.iso8601 }
      File.write(directory.join("result.json"), JSON.pretty_generate(payload)) rescue nil
      puts "WARNING: supervisor self-test failed: #{e.class}: #{e.message}"
      payload
    ensure
      Process.waitpid(hanging_pid, Process::WNOHANG) rescue nil if defined?(hanging_pid) && hanging_pid
      terminate_group(hanging_pid, reason: "self-test cleanup") rescue nil if defined?(hanging_pid) && hanging_pid && process_group_alive?(hanging_pid)
      terminate_group(failing_pid, reason: "self-test cleanup") rescue nil if defined?(failing_pid) && failing_pid && process_group_alive?(failing_pid)
      terminate_group(continuing_pid, reason: "self-test cleanup") rescue nil if defined?(continuing_pid) && continuing_pid && process_group_alive?(continuing_pid)
    end

    def process_alive?(pid)
      stat = proc_stat(pid)
      return stat[:state] != "Z" if stat

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def install_signal_handlers
      %w[INT TERM].each do |signal|
        Signal.trap(signal) do
          # Ruby signal traps run in a restricted context. Do not allocate, log,
          # wait, or kill child processes here. The supervisor loop observes
          # these two scalar assignments within POLL_SECONDS and performs the
          # orderly TERM -> KILL sequence in normal Ruby execution context.
          @received_signal = signal
          @interrupted = true
        end
      end
    end

    def write_run_configuration
      corpus_root = ENV["CORPUS_ROOT"].to_s
      corpus_root = @rails_root.join("..", "corpus").expand_path.to_s if corpus_root.empty?
      payload = {
        "version" => 1,
        "started_at" => @started_at.iso8601,
        "profile" => @options[:profile],
        "rails_root" => @rails_root.to_s,
        "corpus_root" => corpus_root,
        "ruby" => RUBY_DESCRIPTION,
        "host" => Etc.uname.to_h,
        "options" => @options
      }
      File.write(@run_root.join("run_config.json"), JSON.pretty_generate(payload))
      File.write(@run_root.join("RUNNING.txt"), <<~TEXT)
        Fanya Hanwen Corpus overnight search audit
        Started: #{@started_at.iso8601}
        Profile: #{@options[:profile]}
        Rails root: #{@rails_root}
        Corpus root: #{corpus_root}

        The supervisor records one directory per case under cases/. A case that fails,
        times out, or is killed does not prevent the next case from starting.
      TEXT
    end

    def write_reports(results, selected)
      ended_at = Time.now.utc
      counts = results.group_by { |row| row["status"] }.transform_values(&:length)
      payload = {
        "version" => 1,
        "profile" => @options[:profile],
        "started_at" => @started_at.iso8601,
        "ended_at" => ended_at.iso8601,
        "duration_seconds" => (ended_at - @started_at).round(4),
        "interrupted" => @interrupted,
        "supervisor_self_test" => @self_test,
        "status_counts" => counts,
        "selected_case_count" => selected.length,
        "completed_case_count" => results.length,
        "selected_case_ids" => selected.map { |entry| entry.fetch(:id) },
        "not_run_case_ids" => selected.map { |entry| entry.fetch(:id) } - results.map { |row| row["case_id"] },
        "results" => results
      }
      File.write(@run_root.join("report.json"), JSON.pretty_generate(payload))
      write_case_csv(results)
      write_failure_csv(results)
      markdown = build_markdown_report(payload)
      report_path = @run_root.join("REPORT.md")
      File.write(report_path, markdown)
      File.write(@run_root.join("FIXES_REQUIRED.md"), build_fix_report(payload))
      File.write(@run_root.join("report.html"), build_html_report(payload))
      FileUtils.rm_f(@run_root.join("RUNNING.txt"))
      File.write(@run_root.join("COMPLETED.txt"), <<~TEXT)
        Fanya Hanwen Corpus search audit finished
        Finished: #{ended_at.iso8601}
        Profile: #{@options[:profile]}
        Interrupted: #{@interrupted}
        Cases completed: #{results.length} / #{selected.length}
        Supervisor self-test: #{@self_test && @self_test["status"]}
      TEXT
      write_diagnostics_bundle
      report_path
    end

    def write_diagnostics_bundle
      bundle_path = @run_root.join("corpus_search_audit_diagnostics.tar.gz")
      top_level = %w[
        COMPLETED.txt FIXES_REQUIRED.md REPORT.md cases.csv failures.csv report.html
        report.json run_config.json diagnostics_manifest.json
      ]
      selected = top_level.map { |name| @run_root.join(name) }
      selected.concat(Dir.glob(@run_root.join("supervisor_self_test", "**", "*").to_s).map { |path| Pathname(path) })
      selected.concat(Dir.glob(@run_root.join("cases", "*").to_s).flat_map do |case_path|
        directory = Pathname(case_path)
        %w[result.json case_result.json stdout.log stderr.log heartbeat.json supervisor_events.jsonl].map { |name| directory.join(name) }
      end)
      selected.concat(Dir.glob(@run_root.join("cases", "*", "r_failure_inputs", "**", "*").to_s).map { |path| Pathname(path) }.select do |path|
        %w[run_metadata.json warnings.txt stdout.txt stderr.txt analysis_report.json].include?(path.basename.to_s)
      end)
      selected << @run_root.join("shared", "exports.json")
      selected = selected.select(&:file?).uniq.sort_by(&:to_s)

      manifest = {
        "version" => 1,
        "created_at" => Time.now.utc.iso8601,
        "run_root" => @run_root.to_s,
        "included_files" => selected.map { |path| path.relative_path_from(@run_root).to_s },
        "excluded_by_design" => [
          "corpus copies", "query caches", "prepared-search datasets",
          "large CSV exports", "R figures and ZIP downloads"
        ],
        "note" => "The excluded artefacts remain in the run directory; this bundle is the compact repair report."
      }
      manifest_path = @run_root.join("diagnostics_manifest.json")
      File.write(manifest_path, JSON.pretty_generate(manifest))
      selected << manifest_path unless selected.include?(manifest_path)

      temporary = bundle_path.sub_ext(".tmp")
      Zlib::GzipWriter.open(temporary.to_s) do |gzip|
        Gem::Package::TarWriter.new(gzip) do |tar|
          selected.each do |path|
            relative = path.relative_path_from(@run_root).to_s
            stat = path.stat
            tar.add_file_simple(relative, stat.mode, stat.size) do |io|
              File.open(path, "rb") { |source| IO.copy_stream(source, io) }
            end
          end
        end
      end
      FileUtils.mv(temporary, bundle_path)
      bundle_path
    rescue StandardError => e
      File.write(@run_root.join("DIAGNOSTICS_BUNDLE_ERROR.txt"), "#{e.class}: #{e.message}\n#{Array(e.backtrace).first(30).join("\n")}\n")
      nil
    ensure
      FileUtils.rm_f(temporary) if defined?(temporary) && temporary
    end

    def write_case_csv(results)
      CSV.open(@run_root.join("cases.csv"), "w", write_headers: true, headers: %w[case_id group status duration_seconds slow_warning peak_rss_bytes exit_status termsig stdout_log stderr_log]) do |csv|
        results.each do |row|
          supervisor = row.fetch("supervisor", {})
          csv << [
            row["case_id"], row["group"], row["status"], row["duration_seconds"], supervisor["slow_warning"],
            supervisor["peak_rss_bytes"], supervisor["exit_status"], supervisor["termsig"], supervisor["stdout_log"], supervisor["stderr_log"]
          ]
        end
      end
    end

    def write_failure_csv(results)
      CSV.open(@run_root.join("failures.csv"), "w", write_headers: true, headers: %w[case_id case_status assertion_status assertion expected actual detail]) do |csv|
        results.each do |row|
          Array(row["assertions"]).select { |assertion| %w[fail error].include?(assertion["status"]) }.each do |assertion|
            csv << [row["case_id"], row["status"], assertion["status"], assertion["name"], assertion["expected"], assertion["actual"], assertion["detail"]]
          end
          next unless FAILURE_STATUSES.include?(row["status"]) && Array(row["assertions"]).none? { |a| %w[fail error].include?(a["status"]) }

          csv << [row["case_id"], row["status"], "case", "case-level failure", nil, row["error"], nil]
        end
      end
    end

    def build_markdown_report(payload)
      lines = []
      lines << "# Fanya Hanwen Corpus search audit"
      lines << ""
      lines << "- Profile: `#{payload['profile']}`"
      lines << "- Started: #{payload['started_at']}"
      lines << "- Finished: #{payload['ended_at']}"
      lines << "- Duration: #{human_duration(payload['duration_seconds'])}"
      lines << "- Cases completed: #{payload['completed_case_count']} / #{payload['selected_case_count']}"
      lines << "- Supervisor process-group self-test: `#{payload.dig('supervisor_self_test', 'status') || 'not run'}`"
      lines << "- Cases not run: #{payload.fetch('not_run_case_ids', []).empty? ? 'none' : payload.fetch('not_run_case_ids').map { |id| "`#{id}`" }.join(', ')}"
      lines << ""
      lines << "## Summary"
      lines << ""
      payload["status_counts"].sort.each { |status, count| lines << "- #{status}: #{count}" }
      lines << ""
      lines << "## Cases"
      lines << ""
      lines << "| Case | Group | Status | Duration | Slow | Peak RSS |"
      lines << "|---|---|---:|---:|---:|---:|"
      payload["results"].each do |row|
        supervisor = row.fetch("supervisor", {})
        lines << "| `#{row['case_id']}` | #{row['group']} | **#{row['status']}** | #{human_duration(row['duration_seconds'])} | #{supervisor['slow_warning'] ? 'yes' : 'no'} | #{human_bytes(supervisor['peak_rss_bytes'].to_i)} |"
      end
      lines << ""
      lines << "## Failures and errors"
      lines << ""
      failures = failure_items(payload["results"])
      if failures.empty?
        lines << "No failed assertions or case-level errors were recorded."
      else
        failures.each do |item|
          lines << "### `#{item[:case_id]}` — #{item[:title]}"
          lines << ""
          lines << "- Status: `#{item[:status]}`"
          lines << "- Expected: #{markdown_code(item[:expected])}" if item[:expected]
          lines << "- Actual: #{markdown_code(item[:actual])}" if item[:actual]
          lines << ""
          lines << "```text\n#{item[:detail]}\n```" if item[:detail].to_s != ""
          lines << "- stdout: `#{item[:stdout]}`" if item[:stdout]
          lines << "- stderr: `#{item[:stderr]}`" if item[:stderr]
          lines << ""
        end
      end
      lines << "## Warnings and performance observations"
      lines << ""
      warning_count = 0
      payload["results"].each do |row|
        Array(row["warnings"]).each do |warning|
          warning_count += 1
          lines << "- `#{row['case_id']}`: #{warning.is_a?(Hash) ? warning['message'] : warning}"
        end
      end
      lines << "No warnings were recorded." if warning_count.zero?
      lines << ""
      lines << "## Report files"
      lines << ""
      lines << "- `FIXES_REQUIRED.md`: failures, timeouts, hangs, and warnings grouped for repair work."
      lines << "- `failures.csv`: one row per failed assertion or case-level failure."
      lines << "- `cases.csv`: durations, slow flags, memory peaks, and log paths."
      lines << "- `report.json`: complete machine-readable result."
      lines << "- `cases/<case>/`: stdout, stderr, heartbeat, supervisor events, assertions, and artefacts for that case."
      lines.join("\n") + "\n"
    end

    def build_fix_report(payload)
      lines = ["# Search audit: fixes and investigations", ""]
      if payload.dig("supervisor_self_test", "status") != "passed"
        lines << "## Audit supervisor"
        lines << ""
        lines << "- The supervisor self-test did not pass. Do not trust hang recovery until `supervisor_self_test/result.json` is inspected."
        lines << ""
      end
      unless payload.fetch("not_run_case_ids", []).empty?
        lines << "## Cases not run"
        lines << ""
        payload.fetch("not_run_case_ids").each { |id| lines << "- `#{id}`" }
        lines << ""
      end
      failures = failure_items(payload["results"])
      if failures.empty?
        lines << "No functional failure was recorded."
      else
        failures.group_by { |item| item[:case_id] }.each do |case_id, items|
          lines << "## `#{case_id}`"
          lines << ""
          items.each do |item|
            lines << "- **#{item[:title]}** (`#{item[:status]}`)"
            lines << "  - Expected: #{item[:expected]}" if item[:expected]
            lines << "  - Actual: #{item[:actual]}" if item[:actual]
            lines << "  - Detail: #{item[:detail].to_s.lines.first.to_s.strip}" if item[:detail].to_s != ""
          end
          result = payload["results"].find { |row| row["case_id"] == case_id }
          supervisor = result.fetch("supervisor", {})
          lines << "  - stdout: `#{supervisor['stdout_log']}`" if supervisor["stdout_log"]
          lines << "  - stderr: `#{supervisor['stderr_log']}`" if supervisor["stderr_log"]
          lines << ""
        end
      end

      warnings = payload["results"].flat_map do |row|
        Array(row["warnings"]).map { |warning| [row["case_id"], warning.is_a?(Hash) ? warning["message"] : warning.to_s, warning.is_a?(Hash) ? warning["data"] : nil] }
      end
      lines << "## Warnings and possible optimisations"
      lines << ""
      if warnings.empty?
        lines << "No warning or slow-search observation was recorded."
      else
        warnings.each do |case_id, message, data|
          lines << "- `#{case_id}`: #{message}#{data ? " — #{data.inspect}" : ""}"
        end
      end
      lines.join("\n") + "\n"
    end

    def build_html_report(payload)
      rows = payload["results"].map do |row|
        supervisor = row.fetch("supervisor", {})
        <<~HTML
          <tr><td><code>#{h(row['case_id'])}</code></td><td>#{h(row['group'])}</td><td class="#{h(row['status'])}">#{h(row['status'])}</td><td>#{h(human_duration(row['duration_seconds']))}</td><td>#{supervisor['slow_warning'] ? 'yes' : 'no'}</td><td>#{h(human_bytes(supervisor['peak_rss_bytes'].to_i))}</td></tr>
        HTML
      end.join
      failures = failure_items(payload["results"]).map do |item|
        "<section><h3><code>#{h(item[:case_id])}</code>: #{h(item[:title])}</h3><pre>#{h(item[:detail].to_s)}</pre></section>"
      end.join
      <<~HTML
        <!doctype html><html><head><meta charset="utf-8"><title>Corpus search audit</title>
        <style>body{font-family:system-ui,sans-serif;max-width:1200px;margin:2rem auto;padding:0 1rem}table{border-collapse:collapse;width:100%}th,td{border:1px solid #bbb;padding:.45rem;text-align:left}.passed{color:#176b2c}.failed,.error,.timed_out,.stalled,.unkillable,.interrupted{color:#a01818;font-weight:700}.skipped{color:#666}pre{white-space:pre-wrap;background:#f4f4f4;padding:1rem;overflow:auto}</style></head>
        <body><h1>Fanya Hanwen Corpus search audit</h1><p>Profile: <code>#{h(payload['profile'])}</code><br>Started: #{h(payload['started_at'])}<br>Finished: #{h(payload['ended_at'])}</p>
        <h2>Cases</h2><table><thead><tr><th>Case</th><th>Group</th><th>Status</th><th>Duration</th><th>Slow</th><th>Peak RSS</th></tr></thead><tbody>#{rows}</tbody></table>
        <h2>Failures and errors</h2>#{failures.empty? ? '<p>None recorded.</p>' : failures}</body></html>
      HTML
    end

    def failure_items(results)
      results.flat_map do |row|
        items = Array(row["assertions"]).select { |assertion| %w[fail error].include?(assertion["status"]) }.map do |assertion|
          {
            case_id: row["case_id"], status: assertion["status"], title: assertion["name"],
            expected: assertion["expected"], actual: assertion["actual"], detail: assertion["detail"],
            stdout: row.dig("supervisor", "stdout_log"), stderr: row.dig("supervisor", "stderr_log")
          }
        end
        if FAILURE_STATUSES.include?(row["status"]) && items.empty?
          items << {
            case_id: row["case_id"], status: row["status"], title: "case-level failure",
            expected: "case completes", actual: row["status"], detail: row["error"].inspect,
            stdout: row.dig("supervisor", "stdout_log"), stderr: row.dig("supervisor", "stderr_log")
          }
        end
        items
      end
    end

    def read_heartbeat(case_dir)
      path = case_dir.join("heartbeat.json")
      return nil unless path.file?

      payload = parse_json(path)
      return nil unless payload

      current = payload["current"] ? " #{payload['current']}/#{payload['total']}" : ""
      "#{payload['step']}#{current} at #{payload['at']}"
    end

    def event(path, type, payload = {})
      return unless path

      File.open(path, "ab") do |file|
        file.puts JSON.generate({ "type" => type, "at" => Time.now.utc.iso8601 }.merge(payload))
      end
    rescue StandardError
      nil
    end

    def parse_json(path)
      JSON.parse(Pathname(path).read)
    rescue JSON::ParserError, Errno::ENOENT
      nil
    end

    def default_slow_after
      @options[:slow_after] || 600
    end

    def human_duration(seconds)
      total = seconds.to_f.round
      hours, remainder = total.divmod(3_600)
      minutes, secs = remainder.divmod(60)
      return "#{hours}h #{minutes}m #{secs}s" if hours.positive?
      return "#{minutes}m #{secs}s" if minutes.positive?

      "#{secs}s"
    end

    def human_bytes(bytes)
      value = bytes.to_f
      units = %w[B KiB MiB GiB TiB]
      unit = units.shift
      while value >= 1_024 && units.any?
        value /= 1_024
        unit = units.shift
      end
      format(value >= 10 || unit == "B" ? "%.0f %s" : "%.1f %s", value, unit)
    end

    def markdown_code(value)
      text = value.is_a?(String) ? value : value.inspect
      text.length > 300 ? "`#{text[0, 300]}…`" : "`#{text}`"
    end

    def h(value)
      CGI.escapeHTML(value.to_s)
    end

    def print_catalogue
      PROFILES.each do |profile|
        puts "#{profile}:"
        CorpusSearchAudit.cases_for(profile).each { |entry| puts "  #{entry[:id]} — #{entry[:description]}" }
        puts
      end
    end
  end
end

exit CorpusSearchAudit::Supervisor.new(ARGV).run
