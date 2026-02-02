class TextbookController < ApplicationController
  def index
    @lessons = Textbook::LessonStore.all
  end

  def show
    @lesson = Textbook::LessonStore.find!(params[:slug])
  end
end
