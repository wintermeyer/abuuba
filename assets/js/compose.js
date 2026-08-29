// The compose box's two jobs that only the browser can do.
//
// The caret is one of them: the server decides which word is being typed and
// what to offer for it, but only the browser knows where the caret is. It is
// reported on the textarea's own events, which run before the change event
// reaches the form, so the position the server holds belongs to the keystroke
// that follows it rather than to the one before.
//
// The other is Ctrl+Enter. LiveView's key bindings do not carry modifiers, and
// a plain Enter cannot submit a box people write paragraphs in.
export const Compose = {
  mounted() {
    this.textarea = this.el.querySelector("textarea[name='draft[text]']")

    if (!this.textarea) return

    this.at = null

    this.reportCaret = () => {
      const at = this.textarea.selectionStart

      // Only when it actually moved. Every keystroke fires several of these
      // events, and three messages per character is a lot of traffic for one
      // number.
      if (at !== this.at) {
        this.at = at
        this.pushEventTo(this.el, "caret", {at})
      }
    }

    this.maybeSubmit = event => {
      if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
        event.preventDefault()
        this.el.requestSubmit()
      }
    }

    // The picker below shows local time and sends no zone with it, so the
    // server is told the offset once. Without it a post scheduled for six in
    // the evening in Berlin would go out at eight.
    this.pushEventTo(this.el, "timezone", {offset: new Date().getTimezoneOffset()})

    this.textarea.addEventListener("input", this.reportCaret)
    this.textarea.addEventListener("keyup", this.reportCaret)
    this.textarea.addEventListener("click", this.reportCaret)
    // Pasting a screenshot is how most people attach one, and a paste carries
    // its files nowhere the file input can see. Handing them to the input's
    // own DataTransfer is what makes LiveView pick them up as if they had been
    // chosen.
    this.pasteFiles = event => {
      const files = Array.from(event.clipboardData?.files || [])

      if (files.length === 0) return

      const input = this.el.querySelector("input[type='file'][name='media']")

      if (!input) return

      event.preventDefault()

      const carrier = new DataTransfer()

      files.forEach(file => carrier.items.add(file))
      input.files = carrier.files
      input.dispatchEvent(new Event("input", {bubbles: true}))
    }

    this.textarea.addEventListener("keydown", this.maybeSubmit)
    this.textarea.addEventListener("paste", this.pasteFiles)
  },

  destroyed() {
    if (!this.textarea) return

    this.textarea.removeEventListener("input", this.reportCaret)
    this.textarea.removeEventListener("keyup", this.reportCaret)
    this.textarea.removeEventListener("click", this.reportCaret)
    this.textarea.removeEventListener("keydown", this.maybeSubmit)
    this.textarea.removeEventListener("paste", this.pasteFiles)
  },
}

// The focal point: which part of a picture matters when it has to be cropped.
// Only the browser knows where inside the element somebody clicked, so it
// works out the position and the server stores it.
export const FocalPoint = {
  mounted() {
    this.pick = event => {
      const box = this.el.getBoundingClientRect()

      // The API counts from the middle, with the top at 1 and the bottom at -1.
      const x = ((event.clientX - box.left) / box.width) * 2 - 1
      const y = 1 - ((event.clientY - box.top) / box.height) * 2

      // `this.el` rather than a selector, so the event follows the element's
      // own phx-target to the component that drew it.
      this.pushEventTo(this.el, "media_focus", {
        media: this.el.dataset.media,
        x: Math.round(x * 100) / 100,
        y: Math.round(y * 100) / 100,
      })
    }

    this.el.addEventListener("click", this.pick)
  },

  destroyed() {
    this.el.removeEventListener("click", this.pick)
  },
}
