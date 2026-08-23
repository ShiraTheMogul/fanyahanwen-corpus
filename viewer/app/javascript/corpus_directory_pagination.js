function corpusPathRow() {
  const page = document.querySelector(".corpus-directory-page")
  return page?.querySelector(".crumbs + p") || null
}

function mountDirectoryPagination() {
  const pagination = document.querySelector("[data-corpus-directory-pagination]")
  if (!pagination) return

  const pathRow = corpusPathRow()
  if (!pathRow) return

  pathRow.classList.add("corpus-path-pagination-row")
  if (pagination.parentElement !== pathRow) pathRow.appendChild(pagination)
}

function mountWorkSearch() {
  const search = document.querySelector(".corpus-work-search")
  if (!search) return

  const pathRow = corpusPathRow()
  if (!pathRow) return

  if (search.previousElementSibling !== pathRow) pathRow.insertAdjacentElement("afterend", search)
}

function mountCorpusViewerLayout() {
  mountDirectoryPagination()
  mountWorkSearch()
}

document.addEventListener("turbo:load", mountCorpusViewerLayout)
if (document.readyState !== "loading") mountCorpusViewerLayout()
