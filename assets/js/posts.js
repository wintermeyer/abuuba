// Walking a timeline or a thread from the keyboard.
//
// The bindings themselves are declared on the server (see AbuubaWeb.Hotkeys) and
// arrive here as actions. What this file knows is what a post is on the page:
// an element carrying `data-post`. Nothing here decides which keys do what, so
// the shortcuts page and the behaviour cannot disagree.
//
// Focus is what moves, not a class of our own. A focused element is what a
// screen reader announces, what the browser scrolls to, and what Enter already
// means something to, so borrowing it costs nothing and gets all three right.
const POSTS = "[data-post]"

function posts() {
  return Array.from(document.querySelectorAll(POSTS))
}

function current() {
  return document.activeElement?.closest(POSTS)
}

function move(step) {
  const all = posts()

  if (all.length === 0) return

  const here = current()
  const index = here ? all.indexOf(here) : -1
  // Wrapping is deliberately absent: running off the end of a timeline should
  // stop, not silently take somebody back to the top of what they just read.
  const next = Math.min(Math.max(index + step, 0), all.length - 1)

  all[next].focus({preventScroll: false})
}

// The buttons already exist and already do the right thing, including asking
// the server. Pressing one is less code than a second path to the same event,
// and it cannot drift from what a click does.
function press(selector) {
  const post = current()

  if (!post) return

  post.querySelector(selector)?.click()
}

export function installPostKeys() {
  window.addEventListener("abuuba:hotkey", event => {
    switch (event.detail.action) {
      case "next":
        return move(1)
      case "previous":
        return move(-1)
      case "open": {
        const link = current()?.querySelector("[data-post-link]")

        if (link) window.location.href = link.href

        return
      }
      case "favourite":
        return press("button[phx-click='favourite']")
      case "boost":
        return press("button[phx-click='boost']")
      case "reply":
        return press("button[phx-click='reply']")
      case "compose": {
        document.getElementById("compose-text")?.focus()

        return
      }
      default:
        return
    }
  })
}
