import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["yaml", "previewYaml"];

  // Copy the current YAML textarea into the hidden field just before submit.
  syncPreview() {
    if (!this.hasYamlTarget || !this.hasPreviewYamlTarget) return;
    this.previewYamlTarget.value = this.yamlTarget.value;
  }
}
