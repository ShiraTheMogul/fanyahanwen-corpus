import { t } from "i18n"

function ui(key, fallback, variables = {}) {
  const value = t(key, variables)
  if (value !== key) return value
  return fallback.replace(/%\{([^}]+)\}/g, (match, name) => (Object.prototype.hasOwnProperty.call(variables, name) ? String(variables[name]) : match))
}

function ensureFindAuthorsNavigation() {
  const nav = document.querySelector(".site-nav")
  if (!nav || nav.querySelector("[data-find-authors-nav]")) return

  const link = document.createElement("a")
  link.href = "/authors"
  link.textContent = ui("find_authors.nav", "Find Authors")
  link.className = "site-nav-link"
  link.dataset.findAuthorsNav = "1"

  const tools = Array.from(nav.querySelectorAll("a.site-nav-link")).find((item) => {
    try { return new URL(item.href, window.location.origin).pathname === "/tools" } catch (_) { return false }
  })
  if (tools) nav.insertBefore(link, tools)
  else nav.appendChild(link)
}

function readerSourcePath() {
  const reader = document.querySelector(".corpus-reader[data-corpus-annotations-source-path-value]")
  if (!reader) return ""
  return reader.getAttribute("data-corpus-annotations-source-path-value") || ""
}

function authorMetaItem(authors) {
  if (!authors.length) return null
  return Array.from(document.querySelectorAll(".corpus-headmeta .corpus-headmeta-item")).find((item) => {
    const text = item.textContent || ""
    return authors.some((author) => author && text.includes(author))
  }) || null
}

function profileUrl(candidate) {
  return `/authors/${encodeURIComponent(candidate.source)}/${encodeURIComponent(candidate.id)}`
}

function linkResolvedAuthors(item, payload) {
  const authors = Array(payload.authors || []).map(String).filter(Boolean)
  if (!authors.length || !item) return

  const matches = new Map(Array(payload.matches || []).map((row) => [String(row.name || ""), row.profile || null]))
  if (!authors.some((author) => matches.get(author))) return

  const strong = item.querySelector("strong")
  if (!strong) return
  while (strong.nextSibling) strong.nextSibling.remove()
  item.appendChild(document.createTextNode(" "))

  authors.forEach((author, index) => {
    if (index > 0) item.appendChild(document.createTextNode("; "))
    const candidate = matches.get(author)
    if (!candidate || !candidate.source || !candidate.id) {
      item.appendChild(document.createTextNode(author))
      return
    }

    const link = document.createElement("a")
    link.href = profileUrl(candidate)
    link.textContent = author
    link.title = ui("find_authors.open_profile", "Open %{name}", { name: candidate.label || author })
    item.appendChild(link)
  })
}

async function linkCorpusAuthors() {
  const sourcePath = readerSourcePath()
  if (!sourcePath) return

  const url = new URL("/authors.json", window.location.origin)
  url.searchParams.set("path", sourcePath)
  try {
    const response = await fetch(url.toString(), { headers: { "Accept": "application/json" } })
    if (!response.ok) return
    const payload = await response.json()
    const authors = Array(payload.authors || []).map(String).filter(Boolean)
    if (!authors.length) return
    linkResolvedAuthors(authorMetaItem(authors), payload)
  } catch (_) {
    // Failure to resolve a profile must never obstruct reading the corpus text.
  }
}

function boot() {
  ensureFindAuthorsNavigation()
  linkCorpusAuthors()
}

document.addEventListener("turbo:load", boot)
if (document.readyState !== "loading") boot()
