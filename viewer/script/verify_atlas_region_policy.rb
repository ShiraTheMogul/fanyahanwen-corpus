#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

require "json"
require "pathname"

module AtlasRegionPolicyVerifier
  module_function

  JAPAN_CHILD_PERIODS = [
    "奈良時代", "平安時代", "鎌倉時代", "室町時代", "安土桃山時代",
    "江戶時代", "明治時代", "大正時代", "昭和時代", "平成時代", "令和時代"
  ].freeze
  JAPAN_ROOT_PERIODS = ["倭", "日本", "大日本帝國"].freeze

  def verify!(root = Rails.root)
    root = Pathname.new(root)
    atlas = root.join("content", "atlas")
    periodisation_path = atlas.join("periodisation.json")
    data = read_json(periodisation_path)

    excluded = Array(data["excluded_corpus_roots"])
    %w[他漢文 西域漢文].each do |root_name|
      raise "Atlas periodisation must exclude #{root_name}" unless excluded.include?(root_name)
    end

    macro_regions = Array(data["macro_regions"])
    offenders = macro_regions.select do |row|
      (Array(row["corpus_roots"]) & %w[他漢文 西域漢文]).any? || row["id"].to_s == "西域"
    end
    if offenders.any?
      raise "Excluded Atlas regions remain: #{offenders.map { |row| row['id'] }.join(', ')}"
    end

    japan = macro_regions.find { |row| row["id"].to_s == "日本" }
    raise "Missing 日本 Atlas macro-region" unless japan
    unless Array(japan["period_ids"]) == JAPAN_ROOT_PERIODS
      raise "日本 root periods must be #{JAPAN_ROOT_PERIODS.join(' → ')}"
    end

    group_path = atlas.join("periods", "日本", "日本", "metadata.json")
    group = read_json(group_path)
    raise "日本 period divider must be a period_group" unless group["kind"] == "period_group"
    raise "日本 period divider cannot have a parent" unless group["parent_id"].nil?
    raise "日本 period divider has the wrong corpus path" unless Array(group["corpus_paths"]).include?("日本漢文/clean/日本")

    JAPAN_CHILD_PERIODS.each do |period|
      old_path = atlas.join("periods", "日本", period)
      raise "Old flattened Japan period remains: #{old_path}" if old_path.exist?

      metadata = read_json(atlas.join("periods", "日本", "日本", period, "metadata.json"))
      raise "#{period} is not parented by 日本" unless metadata["parent_id"] == "日本"
    end

    wa = read_json(atlas.join("periods", "日本", "倭", "metadata.json"))
    raise "倭 must remain a period divider" unless wa["kind"] == "period_group"

    japan_entry_path = atlas.join("entries", "日本", "metadata.json")
    if japan_entry_path.file?
      japan_entry = read_json(japan_entry_path)
      unless Array(japan_entry.dig("atlas", "period_ids")) == ["日本"]
        raise "The 日本 polity entry must point to the 日本 period divider"
      end
    end

    excluded_entries = atlas.join("entries").glob("*/metadata.json").filter_map do |path|
      payload = read_json(path)
      path.dirname.basename.to_s if payload.dig("corpus", "root").to_s == "他漢文"
    end
    raise "他漢文 polity sources remain: #{excluded_entries.join(', ')}" if excluded_entries.any?

    puts "Atlas region policy verification passed."
    puts "Excluded corpus roots: #{excluded.join(', ')}"
    puts "Japan root dividers: #{JAPAN_ROOT_PERIODS.join(' · ')}"
    puts "Nested Japan periods: #{JAPAN_CHILD_PERIODS.length}"
    true
  end

  def read_json(path)
    raise "Missing JSON file: #{path}" unless path.file?
    raw = path.binread.force_encoding(Encoding::UTF_8)
    raise "Invalid UTF-8: #{path}" unless raw.valid_encoding?
    JSON.parse(raw)
  rescue JSON::ParserError => error
    raise "Invalid JSON in #{path}: #{error.message}"
  end
end

if $PROGRAM_NAME == __FILE__
  root = Pathname.new(__dir__).join("..").expand_path
  AtlasRegionPolicyVerifier.verify!(root)
end
