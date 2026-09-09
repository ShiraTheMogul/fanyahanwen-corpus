# frozen_string_literal: true

Rails.application.config.to_prepare do
  require_dependency Rails.root.join("app/controllers/dictionary_catalogue_controller").to_s
  require_dependency Rails.root.join("app/controllers/concerns/dictionary_catalogue_kangxi").to_s

  unless DictionaryCatalogueController.ancestors.any? { |ancestor| ancestor.name == "DictionaryCatalogueKangxi" }
    DictionaryCatalogueController.prepend(DictionaryCatalogueKangxi)
  end
end
