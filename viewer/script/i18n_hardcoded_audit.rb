#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

require "ripper"

ROOT = File.expand_path("..", __dir__)
Candidate = Data.define(:path, :line, :kind, :text)
IGNORE_START = /i18n-audit-ignore-start/
IGNORE_END = /i18n-audit-ignore-end/


def clean_text(text)
  text.to_s.gsub(/\s+/, " ").strip
end


def likely_human_text?(text)
  cleaned = clean_text(text)
  return false if cleaned.empty?
  return false unless cleaned.match?(/\p{L}.*\p{L}/u)
  return false if cleaned.include?("<%") || cleaned.include?("I18n.t(")
  return false if cleaned.start_with?("/", "#", ".", "[")
  return false if cleaned.match?(/\Ahttps?:\/\//)
  return false if cleaned.match?(/\A[a-z0-9_.:@\/-]+\z/i)
  return false if cleaned.match?(/\A[A-Z0-9_]+\z/)
  return false if cleaned.match?(/\A(?:GET|POST|PATCH|PUT|DELETE)\s+\//)
  return false if cleaned.match?(/\A[a-z][A-Za-z0-9_]*(?:#[a-zA-Z][A-Za-z0-9_]*)?\z/)
  return false if cleaned.match?(/\A(?:[a-z0-9_.-]+\s+)+[a-z0-9_.-]+\z/)

  true
end


def line_number(content, offset)
  content[0...offset].count("\n") + 1
end


def strip_ignored_blocks(content)
  ignoring = false
  content.lines.map do |line|
    ignoring = true if line.match?(IGNORE_START)
    output = ignoring ? ("\n" * line.count("\n")) : line
    ignoring = false if line.match?(IGNORE_END)
    output
  end.join
end


def blank_erb(content)
  content.gsub(/<%#.*?%>/m) { |match| match.gsub(/[^\n]/, " ") }
         .gsub(/<%.*?%>/m) { |match| match.gsub(/[^\n]/, " ") }
end

candidates = []

Dir.glob(File.join(ROOT, "app/views/**/*.erb")).sort.each do |path|
  original = File.read(path, encoding: "UTF-8")
  original = strip_ignored_blocks(original)
  html = blank_erb(original)

  html.to_enum(:scan, />([^<>]+)</m).each do
    match = Regexp.last_match
    text = clean_text(match[1])
    next unless likely_human_text?(text)

    candidates << Candidate.new(path, line_number(html, match.begin(1)), "text", text)
  end

  html.to_enum(:scan, /\b(title|placeholder|aria-label|alt|value)="([^"]+)"/m).each do
    match = Regexp.last_match
    text = clean_text(match[2])
    next unless likely_human_text?(text)

    candidates << Candidate.new(path, line_number(html, match.begin(2)), match[1], text)
  end

  original.to_enum(:scan, /\b(?:link_to|button_to|submit_tag)\s+["']([^"']+)["']/m).each do
    match = Regexp.last_match
    text = clean_text(match[1])
    next unless likely_human_text?(text)

    candidates << Candidate.new(path, line_number(original, match.begin(1)), "helper", text)
  end
end

Dir.glob(File.join(ROOT, "app/javascript/**/*.js")).sort.each do |path|
  File.foreach(path, encoding: "UTF-8").with_index(1) do |line, line_number_value|
    line.scan(/(["'`])([^"'`\n]+)\1/) do |_, value|
      text = clean_text(value)
      next unless likely_human_text?(text)
      next if text.start_with?("@", "${")
      next if text.include?("/") && !text.include?(" ")
      next if text.match?(/\A[a-z][A-Za-z0-9_]*\z/)
      next if text.match?(/\A[A-Z0-9_]+\z/)
      next if text.match?(/\A[a-z0-9_.-]+\z/)
      next unless text.match?(/\s|[.!?:…]|\A\p{Lu}\p{Ll}+\z/u)

      candidates << Candidate.new(path, line_number_value, "javascript", text)
    end
  end
end

ruby_globs = %w[
  app/controllers/**/*.rb
  app/helpers/**/*.rb
  app/jobs/**/*.rb
  app/mailers/**/*.rb
  app/models/**/*.rb
  app/presenters/**/*.rb
  app/services/**/*.rb
  app/lib/**/*.rb
].freeze

ruby_globs.flat_map { |glob| Dir.glob(File.join(ROOT, glob)) }.uniq.sort.each do |path|
  source = File.read(path, encoding: "UTF-8")
  Ripper.lex(source).each do |(position, event, token, _state)|
    next unless event == :on_tstring_content

    text = clean_text(token)
    next unless likely_human_text?(text)
    next if text.include?("/") && !text.include?(" ")
    next if text.match?(/\A[a-z0-9_.:-]+\z/i)

    candidates << Candidate.new(path, position.first, "ruby", text)
  end
end

unique_candidates = candidates.uniq.sort_by do |candidate|
  [candidate.path, candidate.line, candidate.kind, candidate.text]
end

unique_candidates.each do |candidate|
  relative = candidate.path.delete_prefix(ROOT + File::SEPARATOR)
  puts "#{relative}:#{candidate.line}\t#{candidate.kind}\t#{candidate.text}"
end

counts = unique_candidates.group_by(&:kind).transform_values(&:length).sort.to_h
warn "\n#{unique_candidates.length} possible hardcoded interface strings found. Review before changing them."
warn counts.map { |kind, count| "  #{kind}: #{count}" }.join("\n")
