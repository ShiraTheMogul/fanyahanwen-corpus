# frozen_string_literal: true

class CorpusViewerController < ApplicationController
  include ApplicationHelper
  helper CorpusTextHelper

  def show
    root = Rails.configuration.x.corpus_root
    raise "Missing corpus_root (config/initializers/corpus.rb or ENV[CORPUS_ROOT])" if root.to_s.strip.empty?

    fs = CorpusFs.new(root: root)

    # Force the reader to be HTML even if URL ends with .txt
    request.format = :html

    @rel_path = params[:path].to_s
    @abs_path = fs.resolve(@rel_path)

    if fs.directory?(@abs_path)
      @kind = :dir
      @children = fs.list_dir(@abs_path)
      render :show, formats: [:html]
      return
    end

    if fs.file?(@abs_path)
      @kind = :file
      raw = fs.read_text(@abs_path)

      @meta, body = split_corpus_front_matter(raw)  # safe even if no metadata
	      @raw_body = body
	      @text = view_text(body)

      render :show, formats: [:html]
      return
    end

    render plain: "Not found", status: :not_found
  rescue SecurityError
    render plain: "Bad path", status: :bad_request
  end

  private

  # Minimal: treat initial # lines as metadata; everything else is body.
  def split_corpus_front_matter(raw)
    lines = raw.lines
    meta = []
    i = 0

    while i < lines.length && lines[i].start_with?("#")
      meta << lines[i]
      i += 1
    end

    # parse "# KEY: VALUE" and "# KEY" lines
    parsed = meta.filter_map do |line|
      s = line.sub(/\A#\s*/, "").strip
      next if s.empty?
      if s.include?(":")
        k, v = s.split(":", 2).map(&:strip)
        [normalize_label(k), v]
      else
        [normalize_label(s), nil]
      end
    end

    [parsed, lines[i..].join]
  end

  LABEL_MAP = {
    "TIMES" => "Time and/or Location",
    "TIME" => "Time and/or Location",
    "CATEGORY" => "Category",
    "WORK_BASE_TITLE" => "Work",
    "WORK_TITLE" => "Work",
    "PAGE_TITLE" => "Page title",
    "AUTHOR" => "Author"
  }.freeze

  def normalize_label(key)
    key = key.to_s.strip.upcase
    return LABEL_MAP[key] if LABEL_MAP.key?(key)
    key.downcase.split("_").map(&:capitalize).join(" ")
  end
end
