# frozen_string_literal: true

# Compatibility constant for deployments which may still reference the former
# controller-prepend implementation. Automatic historical annotations now live
# directly in CorpusAnnotationsController#show, so this module intentionally
# does not override controller actions.
module HistoricalAutoAnnotations
end
