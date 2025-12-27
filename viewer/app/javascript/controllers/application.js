import { Application } from "@hotwired/stimulus"

const application = Application.start()
application.debug = false

// Handy for debugging in DevTools
window.Stimulus = application

export default application
