defmodule Abuuba.Cldr do
  @moduledoc """
  Locale-aware formatting of dates, times and numbers.

  Gettext translates the words; this decides everything around them. A German
  reader expects 5.12.2026 and 1.234,5, an English one 12/5/2026 and 1,234.5,
  and getting that wrong is the kind of detail that makes software feel
  foreign even when every sentence in it is translated.
  """

  use Cldr,
    locales: ["en", "de"],
    default_locale: "en",
    gettext: AbuubaWeb.Gettext,
    providers: [Cldr.Number, Cldr.DateTime, Cldr.Calendar],
    generate_docs: false
end
