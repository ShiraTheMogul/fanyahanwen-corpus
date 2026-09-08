# frozen_string_literal: true

# A named writing standard must not silently return a partly converted string.
# Translate CharacterStandards' explicit runtime failure into a useful Writer
# response so the client can preserve the user's source input and show an error.
module WordProcessorControllerReliability
  def convert
    super
  rescue CharacterStandards::ConversionUnavailable => error
    render json: { ok: false, error: error.message }, status: :service_unavailable
  end
end
