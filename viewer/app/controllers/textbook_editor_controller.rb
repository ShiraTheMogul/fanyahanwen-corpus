# frozen_string_literal: true

class TextbookEditorController < ApplicationController
  before_action :require_editor_enabled!

  # Draft preview does not change server state (it does not write files),
  # so it's safe to skip CSRF verification for this one action.
  #
  # This also avoids "InvalidAuthenticityToken" when opening preview in a new tab
  # in some browser setups.
  skip_before_action :verify_authenticity_token, only: [:preview]

  def index
    @lessons = Textbook::LessonStore.all.sort_by { |h| h["slug"].to_s }
  end

  def new
    @slug = params[:slug].presence || "new_lesson"
    @lesson = { "title" => "", "slug" => @slug, "summary" => "", "blocks" => [] }
    @raw_yaml = default_raw_yaml(@slug)
  end

  def create
    slug = params[:slug].presence || safe_slug_from_yaml(params[:raw_yaml]) || "new_lesson"
    Textbook::LessonStore.write_raw!(slug, params[:raw_yaml].to_s)
    redirect_to edit_textbook_lesson_path(slug), notice: "Saved."
  end

  def edit
    @slug = params[:slug].to_s
    @lesson = Textbook::LessonStore.find!(@slug)
    @raw_yaml = Textbook::LessonStore.load_raw!(@slug)
  end

  def update
    @slug = params[:slug].to_s
    Textbook::LessonStore.write_raw!(@slug, params[:raw_yaml].to_s)
    redirect_to edit_textbook_lesson_path(@slug), notice: "Saved."
  end

  # POST /textbook/editor/preview
  # Render a lesson preview from submitted YAML WITHOUT saving it.
  def preview
    raw = params[:raw_yaml].to_s
    lesson = parse_raw_yaml!(raw)
    lesson["slug"] ||= params[:slug].presence || "draft"
    @lesson = lesson
    render "textbook/show", status: :ok
  rescue Psych::SyntaxError => e
    @slug = params[:slug].presence || "new_lesson"
    @lesson = { "title" => "", "slug" => @slug, "summary" => "", "blocks" => [] }
    @raw_yaml = raw
    flash.now[:alert] = "YAML parse error: #{e.message.lines.first}".strip
    render :new, status: :unprocessable_entity
  rescue => e
    @slug = params[:slug].presence || "new_lesson"
    @lesson = { "title" => "", "slug" => @slug, "summary" => "", "blocks" => [] }
    @raw_yaml = raw
    flash.now[:alert] = "Preview error: #{e.class}: #{e.message}"
    render :new, status: :unprocessable_entity
  end

  private

  def require_editor_enabled!
    return unless Rails.env.production?
    return if ENV["ENABLE_TEXTBOOK_EDITOR"].to_s == "1"

    render plain: "Not found", status: :not_found
  end

  def default_raw_yaml(slug)
    <<~YAML
      schema_version: 1
      title: New lesson
      slug: #{slug}
      summary: ""
      blocks:
        - type: context
          title: Context
          body: "Write your lead-in here."
    YAML
  end

  def safe_slug_from_yaml(raw)
    lesson = parse_raw_yaml!(raw.to_s)
    lesson["slug"].to_s.presence
  rescue
    nil
  end

  def parse_raw_yaml!(raw)
    parsed = Psych.safe_load(raw, permitted_classes: [], permitted_symbols: [], aliases: false)
    raise ArgumentError, "Lesson YAML must be a mapping (key/value object)" unless parsed.is_a?(Hash)
    parsed["blocks"] ||= []
    parsed["blocks"] = Array(parsed["blocks"])
    parsed
  end
end
