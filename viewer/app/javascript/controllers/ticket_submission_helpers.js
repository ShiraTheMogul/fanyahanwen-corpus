const LOCAL_TICKETS_KEY = "cv_ticket_keys_v1"

export function evidenceLinksFrom(controller) {
  return linesFromTarget(controller, "evidenceLinks")
}

export function contactFrom(controller) {
  const contact = {
    name: valueFromTarget(controller, "contactName").trim(),
    email: valueFromTarget(controller, "contactEmail").trim(),
    notes: valueFromTarget(controller, "contactNotes").trim(),
  }

  return Object.values(contact).some((value) => value.length > 0) ? contact : null
}


export function materialMetadataFrom(controller) {
  const provenance = Array.from(controller.element.querySelectorAll('[data-ticket-provenance]'))
    .filter((input) => input.checked)
    .map((input) => input.value)

  return {
    material_note: valueFromTarget(controller, "materialNote").trim(),
    provenance,
    references: valueFromTarget(controller, "references").trim(),
    ai_assisted: controller.hasAiAssistedTarget ? controller.aiAssistedTarget.checked : false,
    ai_details: valueFromTarget(controller, "aiDetails").trim(),
  }
}

export function appendMaterialMetadata(formData, controller) {
  const metadata = materialMetadataFrom(controller)
  formData.append("material_note", metadata.material_note)
  formData.append("provenance", JSON.stringify(metadata.provenance))
  formData.append("references", metadata.references)
  formData.append("ai_assisted", metadata.ai_assisted ? "1" : "0")
  formData.append("ai_details", metadata.ai_details)
}

export function appendSubmissionExtras(formData, controller) {
  formData.append("evidence_links", JSON.stringify(evidenceLinksFrom(controller)))

  const contact = contactFrom(controller)
  if (contact) {
    formData.append("contact[name]", contact.name)
    formData.append("contact[email]", contact.email)
    formData.append("contact[notes]", contact.notes)
  }

  if (controller.hasUploadsTarget) {
    for (const file of Array.from(controller.uploadsTarget.files || [])) {
      formData.append("evidence_files[]", file)
    }
  }
}

export function submissionExtrasPayload(controller) {
  return {
    evidence_links: evidenceLinksFrom(controller),
    contact: contactFrom(controller),
  }
}

export function downloadTicketKey(ticketId, ticketKey) {
  if (!ticketId || !ticketKey) return

  const content = `TICKET ID: ${ticketId}\nTICKET KEY: ${ticketKey}\n`
  const blob = new Blob([content], { type: "text/plain;charset=utf-8" })
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement("a")
  anchor.href = url
  anchor.download = `ticket_${ticketId}_key.txt`
  document.body.appendChild(anchor)
  anchor.click()
  anchor.remove()
  URL.revokeObjectURL(url)
}

export function maybeStoreTicketOnDevice(controller, ticketId, ticketKey, metadata = {}) {
  if (!ticketId || !ticketKey) return
  if (!controller.hasStoreOnDeviceTarget || !controller.storeOnDeviceTarget.checked) return

  storeTicketOnDevice(ticketId, ticketKey, metadata)
}

export function storeTicketOnDevice(ticketId, ticketKey, metadata = {}) {
  let list = []
  try {
    list = JSON.parse(window.localStorage.getItem(LOCAL_TICKETS_KEY) || "[]")
    if (!Array.isArray(list)) list = []
  } catch (_error) {
    list = []
  }

  list = list.filter((ticket) => ticket.ticket_id !== ticketId && ticket.ticket_key !== ticketKey)
  list.unshift({
    ticket_id: ticketId,
    ticket_key: ticketKey,
    saved_at: new Date().toISOString(),
    ...metadata,
  })

  window.localStorage.setItem(LOCAL_TICKETS_KEY, JSON.stringify(list.slice(0, 25)))
}

function linesFromTarget(controller, name) {
  return valueFromTarget(controller, name)
    .split(/\r?\n/)
    .map((value) => value.trim())
    .filter((value) => value.length > 0)
}

function valueFromTarget(controller, name) {
  const capitalized = `${name.charAt(0).toUpperCase()}${name.slice(1)}`
  const hasTarget = `has${capitalized}Target`
  const target = `${name}Target`

  return controller[hasTarget] ? (controller[target].value || "") : ""
}
