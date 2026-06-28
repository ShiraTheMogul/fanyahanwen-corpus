function payload() {
  const node = document.getElementById("interface-translations")
  if (!node) return { locale: "en", translations: {} }

  try {
    return JSON.parse(node.textContent || "{}")
  } catch (_error) {
    return { locale: "en", translations: {} }
  }
}

function lookup(tree, dottedKey) {
  return dottedKey.split(".").reduce((branch, part) => {
    if (!branch || typeof branch !== "object") return undefined
    return branch[part]
  }, tree)
}

function interpolate(value, variables) {
  return value.replace(/%\{([^}]+)\}/g, (match, name) => {
    return Object.prototype.hasOwnProperty.call(variables, name) ? String(variables[name]) : match
  })
}

export function t(key, variables = {}) {
  const value = lookup(payload().translations || {}, key)
  if (typeof value !== "string") return key
  return interpolate(value, variables)
}

export function currentLocale() {
  return payload().locale || "en"
}
