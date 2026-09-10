import application from "controllers/application"
import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"
import WordProcessorController from "controllers/word_processor_controller"
import CorpusAnnotationsController from "controllers/corpus_annotations_controller"
import CorpusReaderController from "controllers/corpus_reader_controller"
import { installWordProcessorReliability } from "controllers/word_processor_reliability"
import { installWordProcessorSemanticAnnotations } from "controllers/word_processor_semantic_annotations"
import { installWordProcessorScriptStandards } from "controllers/word_processor_script_standards"
import { installWordProcessorTypographyReliability } from "controllers/word_processor_typography_reliability"
import { installCorpusAnnotationsReliability } from "controllers/corpus_annotations_reliability"
import { installCorpusReaderTypographyReliability } from "controllers/corpus_reader_typography_reliability"

// Apply shared Writer/Text Viewer reliability layers before Stimulus registers
// the controllers. ES modules are singletons, so eager loading receives these
// same patched class objects.
installWordProcessorReliability(WordProcessorController)
installWordProcessorSemanticAnnotations(WordProcessorController)
installWordProcessorScriptStandards(WordProcessorController)
installWordProcessorTypographyReliability(WordProcessorController)
installCorpusAnnotationsReliability(CorpusAnnotationsController)
installCorpusReaderTypographyReliability(CorpusReaderController)

// Auto-register all controllers in app/javascript/controllers
eagerLoadControllersFrom("controllers", application)
