# frozen_string_literal: true

Rails.application.config.to_prepare do
  require_dependency Rails.root.join("app/models/character_standards").to_s
  require_dependency Rails.root.join("app/models/character_standards_reliability").to_s
  require_dependency Rails.root.join("app/models/character_standards_kangxi").to_s
  require_dependency Rails.root.join("app/services/calendar_engine").to_s
  require_dependency Rails.root.join("app/services/calendar_engine_reliability").to_s
  require_dependency Rails.root.join("app/controllers/word_processor_controller").to_s
  require_dependency Rails.root.join("app/controllers/word_processor_controller_reliability").to_s

  unless CharacterStandards.const_defined?(:ConversionUnavailable, false)
    CharacterStandards.const_set(:ConversionUnavailable, Class.new(StandardError))
  end

  character_singleton = CharacterStandards.singleton_class
  unless character_singleton.ancestors.any? { |ancestor| ancestor.name == "CharacterStandardsReliability" }
    character_singleton.prepend(CharacterStandardsReliability)
  end
  unless character_singleton.ancestors.any? { |ancestor| ancestor.name == "CharacterStandardsKangxi" }
    character_singleton.prepend(CharacterStandardsKangxi)
  end

  unless CalendarEngine.ancestors.any? { |ancestor| ancestor.name == "CalendarEngineReliability" }
    CalendarEngine.prepend(CalendarEngineReliability)
  end

  unless WordProcessorController.ancestors.any? { |ancestor| ancestor.name == "WordProcessorControllerReliability" }
    WordProcessorController.prepend(WordProcessorControllerReliability)
  end
end
