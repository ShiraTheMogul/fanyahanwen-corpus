import application from "controllers/application"
import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"

// Auto-register all controllers in app/javascript/controllers
eagerLoadControllersFrom("controllers", application)
