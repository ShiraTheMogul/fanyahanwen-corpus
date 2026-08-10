import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    const toolbar = this.element.querySelector(".corpus-toolbar")
    const textFlow = this.element.querySelector(".corpus-textflow")
    if (!toolbar || !textFlow || toolbar.querySelector("[data-transcription-launcher-button]")) return

    const button = document.createElement("button")
    button.type = "button"
    button.className = "corpus-btn corpus-transcription-launch"
    button.dataset.transcriptionLauncherButton = "true"
    button.textContent = "Transcribe"
    button.title = "Open this text in transcription practice"
    button.addEventListener("click", () => this.launch(textFlow))

    const editing = toolbar.querySelector(".corpus-toolbar-editing")
    if (editing?.parentElement === toolbar) toolbar.insertBefore(button, editing)
    else toolbar.append(button)
  }

  launch(textFlow) {
    const clone = textFlow.cloneNode(true)
    clone.querySelectorAll("rt, script, style, [aria-hidden='true']").forEach((node) => node.remove())
    const text = clone.textContent.replace(/\u00a0/g, " ").trim()
    if (!text) return

    const work = Array.from(this.element.querySelectorAll(".corpus-headmeta-item"))
      .map((element) => element.textContent.trim())
      .find((value) => /^Work:/i.test(value))
    const title = work ? work.replace(/^Work:\s*/i, "") : "Corpus text"

    sessionStorage.setItem("fanya.transcription.handoff", JSON.stringify({ text, title }))
    window.location.assign("/fun/transcription?source=corpus")
  }
}
