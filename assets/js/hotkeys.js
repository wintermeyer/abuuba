// Keyboard shortcuts.
//
// The bindings come from the server so that the help page and the behaviour
// cannot disagree: a shortcuts page listing a key that does nothing is worse
// than no page at all.
//
// Nothing fires while a text box has focus. Somebody writing a post is typing
// letters, not issuing commands, and a "b" that boosts something mid-sentence
// is the kind of bug people never report because they assume they did it.

const TYPING = ["INPUT", "TEXTAREA", "SELECT"];

// How long a two-key sequence like "g h" stays open. Long enough to be typed
// deliberately, short enough that a stray "g" does not swallow the next key.
const SEQUENCE_MS = 1000;

export function installHotkeys(bindings, handlers) {
  let pending = "";
  let timer = null;

  const reset = () => {
    pending = "";
    if (timer) clearTimeout(timer);
    timer = null;
  };

  document.addEventListener("keydown", (event) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;

    const target = event.target;
    if (TYPING.includes(target.tagName) || target.isContentEditable) return;

    const sequence = pending ? `${pending} ${event.key}` : event.key;
    const action = bindings[sequence];

    if (action) {
      reset();
      event.preventDefault();
      (handlers[action] || handlers.default || (() => {}))(action, event);
      return;
    }

    // Might still be the first half of a two-key sequence.
    const isPrefix = Object.keys(bindings).some((keys) => keys.startsWith(`${event.key} `));

    if (isPrefix && !pending) {
      pending = event.key;
      timer = setTimeout(reset, SEQUENCE_MS);
    } else {
      reset();
    }
  });
}

// Announces something to a screen reader without moving focus.
//
// Focus is what a sighted keyboard user follows and moving it steals their
// place; the live region is how somebody who cannot see the screen is told
// that a post was sent or a timeline grew.
export function announce(message) {
  const region = document.getElementById("live-region");
  if (!region) return;

  // Cleared first, because writing the same text twice in a row is not a
  // change and a screen reader will say nothing at all.
  region.textContent = "";
  setTimeout(() => (region.textContent = message), 50);
}
