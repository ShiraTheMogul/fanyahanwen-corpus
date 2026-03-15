# frozen_string_literal: true

class CorpusViewerController < ApplicationController
  include ApplicationHelper
  helper CorpusTextHelper

  TRADITION_FOLDERS = %w[kanbun hanmun hanvan].freeze

  def show
    root = Rails.configuration.x.corpus_root
    raise "Missing corpus_root (config/initializers/corpus.rb or ENV[CORPUS_ROOT])" if root.to_s.strip.empty?

    fs = CorpusFs.new(root: root)

    # Force the reader to be HTML even if URL ends with .txt
    request.format = :html

    @rel_path = params[:path].to_s
    @abs_path = fs.resolve(@rel_path)
    @requested_tradition = normalized_tradition_param(params[:tradition])

    if fs.directory?(@abs_path)
      @kind = :dir
      @children = fs.list_dir(@abs_path)
      render :show, formats: [:html]
      return
    end

    if fs.file?(@abs_path)
      @kind = :file
      @current_tradition_folder = tradition_folder_for(@rel_path)
      @source_rel_path = source_rel_path_for(@rel_path, @current_tradition_folder)
      @source_abs_path = fs.resolve(@source_rel_path)

      source_raw = fs.read_text(@source_abs_path)
      @meta, @source_body = split_corpus_front_matter(source_raw)

      @available_traditions = available_traditions_for(fs, @source_rel_path)
      @derived_bodies = load_derived_bodies(fs, @available_traditions)

      selected_tradition = selected_tradition_for_view
      @display_tradition = selected_tradition
      view_rel_path = selected_tradition.present? ? @available_traditions[selected_tradition] : @rel_path
      @active_text_target_path = view_rel_path
      view_raw = fs.read_text(fs.resolve(view_rel_path))
      _view_meta, body = split_corpus_front_matter(view_raw)

      @raw_body = body
      @text = view_text(body)
      @kanbun_editor_enabled = @current_tradition_folder.blank?

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

  def normalized_tradition_param(value)
    tradition = value.to_s.strip.downcase
    TRADITION_FOLDERS.include?(tradition) ? tradition : nil
  end

  def tradition_folder_for(rel_path)
    dir_name = File.basename(File.dirname(rel_path.to_s))
    TRADITION_FOLDERS.include?(dir_name) ? dir_name : nil
  end

  def source_rel_path_for(rel_path, current_tradition_folder)
    return rel_path.to_s if current_tradition_folder.blank?

    rel_path.to_s.sub(%r{/#{Regexp.escape(current_tradition_folder)}/([^/]+)\z}, '/\1')
  end

  def derived_rel_path_for(source_rel_path, tradition)
    dir = File.dirname(source_rel_path.to_s)
    base = File.basename(source_rel_path.to_s)
    [dir, tradition, base].reject(&:blank?).join('/')
  end

  def available_traditions_for(fs, source_rel_path)
    TRADITION_FOLDERS.each_with_object({}) do |tradition, memo|
      rel = derived_rel_path_for(source_rel_path, tradition)
      abs = fs.resolve(rel)
      memo[tradition] = rel if fs.file?(abs)
    end
  end

  def load_derived_bodies(fs, available_traditions)
    available_traditions.each_with_object({}) do |(tradition, rel), memo|
      raw = fs.read_text(fs.resolve(rel))
      _meta, body = split_corpus_front_matter(raw)
      memo[tradition] = body
    end
  end

  def selected_tradition_for_view
    return @current_tradition_folder if @current_tradition_folder.present?
    return nil if @requested_tradition.blank?
    return nil unless @available_traditions[@requested_tradition].present?

    @requested_tradition
  end
end
