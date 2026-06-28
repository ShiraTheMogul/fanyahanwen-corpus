# Pin npm packages by running ./bin/importmap

pin "application"
pin "i18n", to: "i18n.js"
pin "hanzi-writer" # @2.1.0
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin "controllers", to: "controllers/index.js"
pin "controllers/index", to: "controllers/index.js"
pin_all_from "app/javascript/controllers", under: "controllers"
