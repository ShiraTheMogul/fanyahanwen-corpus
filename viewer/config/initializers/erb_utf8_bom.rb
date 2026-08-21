# frozen_string_literal: true

# Repository text files that contain Han script are stored as UTF-8 with a BOM.
# ERB templates are compiled into a larger HTML response, so their file-level
# UTF-8 signature must not become U+FEFF document content.
module FanyaHanwenErbUtf8Bom
  UTF8_BOM = "\uFEFF"

  def call(template, source)
    super(template, source.delete_prefix(UTF8_BOM))
  end
end

ActiveSupport.on_load(:action_view) do
  handler = ActionView::Template::Handlers::ERB
  handler.prepend(FanyaHanwenErbUtf8Bom) unless handler.ancestors.include?(FanyaHanwenErbUtf8Bom)
end
