// The one thing about a timestamp that only the browser knows.
//
// Every time in the database is UTC, and the server renders it that way and
// says so. What it cannot know is which zone the reader is in, or what
// daylight saving was doing on the date in question — that is a database of
// its own, refreshed several times a year, and carrying it to render one line
// on the security page is not a trade worth making when every browser already
// has it.
//
// So the server writes the instant into `datetime` and the readable UTC text
// inside the element, and this swaps the text for the local rendering. A
// reader with no script keeps something true and inconvenient, which is the
// right way round: what this replaces was convenient and two hours wrong.
//
// The language comes from the document rather than the browser, because the
// interface is already in whichever one the reader picked and a German page
// with an American date in it reads like a bug. The zone comes from the
// browser, which is the whole point.

const formatter = () => {
  const language = document.documentElement.lang || undefined

  try {
    return new Intl.DateTimeFormat(language, {dateStyle: "medium", timeStyle: "short"})
  } catch (_error) {
    // An unknown language tag is not a reason to leave the wrong time on the
    // screen; the browser's own default still knows the zone.
    return new Intl.DateTimeFormat(undefined, {dateStyle: "medium", timeStyle: "short"})
  }
}

let format = null

function localise(root) {
  if (!root || typeof root.querySelectorAll !== "function") return

  const self = root.matches && root.matches("time[data-local]") ? [root] : []
  const found = self.concat(Array.from(root.querySelectorAll("time[data-local]")))

  if (found.length === 0) return

  format = format || formatter()

  for (const el of found) {
    const at = new Date(el.getAttribute("datetime"))

    // A timestamp the server could not write is left exactly as it is: the
    // UTC text is still true, and guessing here would put a wrong date on the
    // page rather than an awkward one.
    if (isNaN(at.getTime())) continue

    el.textContent = format.format(at)
    el.title = el.getAttribute("datetime")
    // Marked done, so a later pass over a patched page does not reformat what
    // is already local — the second pass would parse the rendered text, not
    // the attribute, and get it wrong.
    el.removeAttribute("data-local")
  }
}

export function installLocalTime() {
  if (typeof Intl === "undefined" || !Intl.DateTimeFormat) return

  localise(document)

  // LiveView patches the page without a navigation, so there is no one event to
  // hang this on. Two kinds of change matter and the attribute is the subtle
  // one: a patch rewrites the element back to what the server rendered, which
  // puts the UTC text and `data-local` back, so watching only for new nodes
  // would localise a page once and lose it on the next update.
  new MutationObserver(records => {
    for (const record of records) {
      if (record.type === "attributes") {
        localise(record.target)
        continue
      }

      for (const node of record.addedNodes) {
        if (node.nodeType === Node.ELEMENT_NODE) localise(node)
      }
    }
  }).observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributeFilter: ["data-local"]
  })
}
