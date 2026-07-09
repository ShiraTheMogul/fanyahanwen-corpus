# frozen_string_literal: true

class CorpusViewerController < ApplicationController
  include ApplicationHelper
  helper CorpusTextHelper
  helper HomeHelper

  ANNOTATION_SYSTEM_FOLDERS = %w[kanbun hanmun hanvan].freeze
  ROOT_HIDDEN_ENTRIES = %w[scripts].freeze

  def show
    root = Rails.configuration.x.corpus_root
    raise "Missing corpus_root (config/initializers/corpus.rb or ENV[CORPUS_ROOT])" if root.to_s.strip.empty?

    fs = CorpusFs.new(root: root)

    # Force the reader to be HTML even if URL ends with .txt
    request.format = :html

    @rel_path = params[:path].to_s
    @abs_path = fs.resolve(@rel_path)
    @requested_annotation_system = normalized_annotation_system_param(params[:annotation_system].presence || params[:tradition])

    if fs.directory?(@abs_path)
      @kind = :dir
      @children = fs.list_dir(@abs_path)
      @children -= ROOT_HIDDEN_ENTRIES if @rel_path.blank?

      if @rel_path.blank?
        @corpus_activity = CorpusActivity::Snapshot.new
        @corpus_activity_summary = @corpus_activity.summary
      end

      render :show, formats: [:html]
      return
    end

    if fs.file?(@abs_path)
      @kind = :file
      direct_translation = translation_source_info(@rel_path)
      @direct_translation_id = direct_translation && direct_translation[:material_id]
      @current_annotation_system_folder = annotation_system_folder_for(@rel_path)
      @source_rel_path = if direct_translation
        direct_translation[:source_path]
      else
        source_rel_path_for(@rel_path, @current_annotation_system_folder)
      end
      @source_abs_path = fs.resolve(@source_rel_path)

      metadata_store = CorpusMetadataStore.new(root: root, fs: fs)
      source_raw = fs.read_text(@source_abs_path)
      @meta = metadata_store.display_entries_for_path(@source_rel_path)
      @meta = metadata_store.legacy_entries_from_text(source_raw) if @meta.blank?
      @source_body = body_from_text(source_raw)

      @available_annotation_systems = available_annotation_systems_for(fs, @source_rel_path)
      @annotation_system_bodies = load_annotation_system_bodies(fs, @available_annotation_systems)

      companion_payload = CorpusCompanionStore.new(source_path: @source_rel_path).read
      @companion_materials = Array(companion_payload["materials"])
      @available_translations = available_translations_for(fs, @companion_materials)
      @variant_materials = @companion_materials.select { |material| material["type"] == "variant_text" }
      @annotation_system_materials = @companion_materials
        .select { |material| %w[annotation_system derived_tradition].include?(material["type"]) && (material["annotation_system"].presence || material["tradition"]).present? }
        .index_by { |material| material["annotation_system"].presence || material["tradition"] }

      selected_annotation_system = selected_annotation_system_for_view
      selected_translation = selected_annotation_system.present? ? nil : selected_translation_for_view
      @display_annotation_system = selected_annotation_system
      @display_translation = selected_translation

      view_rel_path = if selected_annotation_system.present?
        @available_annotation_systems[selected_annotation_system]
      elsif selected_translation.present?
        selected_translation["target_path"]
      else
        @rel_path
      end

      @active_text_target_path = view_rel_path
      view_raw = fs.read_text(fs.resolve(view_rel_path))
      body = body_from_text(view_raw)

      @raw_body = body
      @text = view_text(body)
      @annotation_system_editor_enabled = @current_annotation_system_folder.blank? && @display_translation.blank?
      @companion_submission_enabled = @current_annotation_system_folder.blank? && @direct_translation_id.blank? && @display_translation.blank?

      render :show, formats: [:html]
      return
    end

    render plain: "Not found", status: :not_found
  rescue SecurityError
    render plain: "Bad path", status: :bad_request
  end

  private

  # Use the same body boundary as corpus search so body-offset deep links are
  # exact. New corpus files should already be body-only; DocumentReader remains
  # as a legacy fallback for old/ticket-created files that still contain leading
  # # metadata headers.
  def body_from_text(raw)
    CorpusSearch::DocumentReader.parse(raw).body
  end

  LABEL_MAP = {
    "TIMES" => "Time and/or Location",
    "TIME" => "Time and/or Location",
    "CATEGORY" => "Category",
    "CATEGORIES" => "Category",
    "SOURCE_CATEGORIES" => "Ws Categories",
    "WS_CATEGORIES" => "Ws Categories",
    "WORK_BASE_TITLE" => "Work",
    "WORK_TITLE" => "Work",
    "PAGE_TITLE" => "Page title",
    "AUTHOR" => "Author"
  }.freeze

  def normalize_label(key)
    normalized = key.to_s.strip.upcase
    return LABEL_MAP[normalized] if LABEL_MAP.key?(normalized)

    normalized.downcase.split("_").map(&:capitalize).join(" ")
  end

  def normalized_annotation_system_param(value)
    tradition = value.to_s.strip.downcase
    ANNOTATION_SYSTEM_FOLDERS.include?(tradition) ? tradition : nil
  end

  def annotation_system_folder_for(rel_path)
    dir_name = File.basename(File.dirname(rel_path.to_s))
    ANNOTATION_SYSTEM_FOLDERS.include?(dir_name) ? dir_name : nil
  end

  def source_rel_path_for(rel_path, current_annotation_system_folder)
    return rel_path.to_s if current_annotation_system_folder.blank?

    rel_path.to_s.sub(%r{/#{Regexp.escape(current_annotation_system_folder)}/([^/]+)\z}, '/\1')
  end

  def translation_source_info(rel_path)
    match = rel_path.to_s.match(%r{\A(?:(?<dir>.+)/)?translation/(?<language>[a-z]{3})/(?<material_id>[^/]+)/(?<base>[^/]+)\z})
    return nil unless match

    {
      source_path: [match[:dir], match[:base]].reject(&:blank?).join("/"),
      material_id: match[:material_id]
    }
  end

  def annotation_system_rel_path_for(source_rel_path, annotation_system)
    dir = File.dirname(source_rel_path.to_s)
    base = File.basename(source_rel_path.to_s)
    [dir, annotation_system, base].reject(&:blank?).join('/')
  end

  def available_annotation_systems_for(fs, source_rel_path)
    ANNOTATION_SYSTEM_FOLDERS.each_with_object({}) do |annotation_system, memo|
      rel = annotation_system_rel_path_for(source_rel_path, annotation_system)
      abs = fs.resolve(rel)
      memo[annotation_system] = rel if fs.file?(abs)
    end
  end

  def load_annotation_system_bodies(fs, available_annotation_systems)
    available_annotation_systems.each_with_object({}) do |(annotation_system, rel), memo|
      raw = fs.read_text(fs.resolve(rel))
      memo[annotation_system] = body_from_text(raw)
    end
  end

  def selected_annotation_system_for_view
    return @current_annotation_system_folder if @current_annotation_system_folder.present?
    return nil if @requested_annotation_system.blank?
    return nil unless @available_annotation_systems[@requested_annotation_system].present?

    @requested_annotation_system
  end

  def available_translations_for(fs, materials)
    Array(materials).filter_map do |material|
      next unless material["type"] == "translation"

      target_path = material["target_path"].to_s
      next if target_path.blank?
      next unless fs.file?(fs.resolve(target_path))

      [material["id"].to_s, material]
    rescue SecurityError
      nil
    end.to_h
  end

  def selected_translation_for_view
    material_id = @direct_translation_id.to_s.presence || params[:translation].to_s
    return nil if material_id.blank?

    @available_translations[material_id]
  end
end
