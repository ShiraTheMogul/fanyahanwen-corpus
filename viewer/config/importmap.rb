# Pin npm packages by running ./bin/importmap

pin "application"
pin "i18n", to: "i18n.js"
pin "authority_auto_annotations", to: "authority_auto_annotations.js"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin "controllers", to: "controllers/index.js"
pin "controllers/index", to: "controllers/index.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin "era_calendar_tool", to: "era_calendar_tool.js"
pin "author_authority_link", to: "author_authority_link.js"
pin "corpus_directory_pagination", to: "corpus_directory_pagination.js"
