#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

ROOT = File.expand_path("..", __dir__)
Candidate = Data.define(:path, :line, :kind, :text)


def clean_text(text)
  text.to_s.gsub(/\s+/, " ").strip
end


def likely_human_text?(text)
  cleaned = clean_text(text)
  return false if cleaned.empty?
  return false unless cleaned.match?(/[A-Za-z]{2}/)
  return false if cleaned.include?("<%") || cleaned.include?("I18n.t(")
  return false if cleaned.start_with?("/")
  return false if cleaned.match?(/\A(?:https?:\/\/|[a-z0-9_.-]+#[a-zA-Z]|[a-z_]+(?:\s+[a-z_]+)*)\z/)

  true
end

candidates = []

Dir.glob(File.join(ROOT, "app/views/**/*.erb")).sort.each do |path|
  in_erb_comment = false

  File.foreach(path, encoding: "UTF-8").with_index(1) do |line, line_number|
    in_erb_comment = true if line.include?("<%#")

    unless in_erb_comment
      # Same-line HTML text nodes. The [^<>] restriction avoids mistaking
      # Stimulus arrows such as "click->controller#action" for tag endings.
      line.scan(/>([^<>]+)<\/[A-Za-z]/) do |match|
        text = clean_text(match.first)
        candidates << Candidate.new(path, line_number, "text", text) if likely_human_text?(text)
      end

      line.scan(/\b(title|placeholder|aria-label|value)="([^"]+)"/) do |attribute, value|
        text = clean_text(value)
        candidates << Candidate.new(path, line_number, attribute, text) if likely_human_text?(text)
      end

      line.scan(/\b(?:link_to|button_to|submit_tag)\s+["']([^"']+)["']/) do |match|
        text = clean_text(match.first)
        candidates << Candidate.new(path, line_number, "helper", text) if likely_human_text?(text)
      end
    end

    in_erb_comment = false if in_erb_comment && line.include?("%>")
  end
end

Dir.glob(File.join(ROOT, "app/javascript/**/*.js")).sort.each do |path|
  File.foreach(path, encoding: "UTF-8").with_index(1) do |line, line_number|
    line.scan(/(["'`])([^"'`\n]+)\1/) do |_, value|
      text = clean_text(value)
      next unless likely_human_text?(text)
      next if text.start_with?("@", "${")
      next if text.include?("/") && !text.include?(" ")
      next if text.match?(/\A[a-z][A-Za-z0-9_]*\z/)
      next if text.match?(/\A[A-Z0-9_]+\z/)
      next if text.match?(/\A[a-z0-9_.-]+\z/)
      next if text.match?(/\A(?:[a-z0-9_.-]+\s+)+[a-z0-9_.-]+\z/)
      next if text.match?(/\A[.#\[]/)
      next unless text.match?(/\s|[.!?:…]|\A[A-Z][a-z]+\z/)

      candidates << Candidate.new(path, line_number, "javascript", text)
    end
  end
end

unique_candidates = candidates.uniq.sort_by do |candidate|
  [candidate.path, candidate.line, candidate.kind, candidate.text]
end

unique_candidates.each do |candidate|
  relative = candidate.path.delete_prefix(ROOT + File::SEPARATOR)
  puts "#{relative}:#{candidate.line}\t#{candidate.kind}\t#{candidate.text}"
end

warn "\n#{unique_candidates.length} possible hardcoded interface strings found. Review before changing them."
