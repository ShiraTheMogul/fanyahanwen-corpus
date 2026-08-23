// Completes the lifecycle cleanup performed by authority_auto_annotations.js.
// The main module stores its click handler on the reader element; removing it
// here prevents a live Turbo page from retaining a stale handler before cache.
function cleanupAuthorityClickHandlers() {
  document.querySelectorAll(".corpus-reader[data-corpus-annotations-path-value]").forEach((reader) => {
    const handler = reader._authorityAutoClickHandler
    if (handler) reader.removeEventListener("click", handler)
    reader._authorityAutoClickHandler = null
    delete reader.dataset.authorityAutoClickBound
  })
}

document.addEventListener("turbo:before-cache", cleanupAuthorityClickHandlers)
