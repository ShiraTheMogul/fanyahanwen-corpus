class TextbookEditorController < ApplicationController
  def index
    @lessons = Textbook::LessonStore.all
  end

  def new
    @slug = ""
    @raw_yaml = Textbook::LessonStore.template_yaml
    @lesson = Textbook::LessonStore.safe_parse_yaml(@raw_yaml)
  end

  def edit
    @slug = params[:slug].to_s
    @raw_yaml = Textbook::LessonStore.raw_yaml(@slug)
    @lesson = Textbook::LessonStore.safe_parse_yaml(@raw_yaml)
  end

  def create
    data = lesson_params
    slug = data[:slug].to_s.strip
    raw_yaml = data[:yaml].to_s

    Textbook::LessonStore.write_raw!(slug, raw_yaml)
    redirect_to edit_textbook_lesson_path(slug: slug), notice: "Saved."
  end

  def update
    slug = params[:slug].to_s
    raw_yaml = params.dig(:lesson, :yaml).to_s
    Textbook::LessonStore.write_raw!(slug, raw_yaml)
    redirect_to edit_textbook_lesson_path(slug: slug), notice: "Saved."
  end

  def preview
    raw_yaml = params.dig(:lesson, :yaml).to_s
    lesson = Textbook::LessonStore.parse_yaml_string!(raw_yaml)
    render template: "textbook/show", locals: { lesson: lesson }, layout: "application"
  end

  private

  def lesson_params
    params.require(:lesson).permit(:title, :slug, :summary, :yaml)
  end
end
