# Translating posts

## Off unless you set it up

A translate button nobody configured is a button that answers every press with
an error, so nothing is offered until a provider and its credentials are there.
`/api/v2/instance` reports `configuration.translation.enabled`, and the web UI
shows the button only where the answer is yes.

| Provider | Variables |
| --- | --- |
| DeepL | `TRANSLATION_PROVIDER=deepl`, `DEEPL_API_KEY` (a free key ends in `:fx` and the host is worked out from that), optional `DEEPL_HOST` |
| LibreTranslate | `TRANSLATION_PROVIDER=libretranslate`, `LIBRETRANSLATE_ENDPOINT`, usually `LIBRETRANSLATE_API_KEY` |

Both are adapters behind `Abuuba.Translation`, so a third one is a module rather
than a change to any call site.

## One call per post, not five

The content, the content warning, the poll options and the media descriptions
go in a single request and come back in the same order. Providers bill per
request as well as per character, and five round trips is five chances to be
rate limited on a post somebody is waiting to read.

LibreTranslate's endpoint takes one text at a time, so a batch is a series of
requests there. The cache is what stops that mattering.

## Custom emoji are marked as not to be translated

Each `:shortcode:` is wrapped in `<span translate="no">`, which both providers
honour when the text is sent as HTML — and both adapters send it as HTML for
exactly this reason. Without it a shortcode comes back translated into
something that is no longer a shortcode and no longer renders.

## Cached for a day, keyed on the words

The key is a hash of what was actually sent plus the language pair. Two posts
with the same text are one translation, a hundred readers asking about one post
is one call, and an edited post is a new entry without anything having to
remember to invalidate it. Entries carry their own expiry and an hourly worker
takes the stale ones.

The list of supported languages is cached for a week, because it is a property
of the provider account and changes about never.

**Failures are never cached.** A minute of being rate limited would otherwise
become a day of a button that does nothing.

## Only what anybody may read

Public and unlisted posts. Translating means handing the words to a third
party, and a followers-only post is not ours to hand over however much the
person reading it would like it translated. A post already in the language
asked for is refused too, rather than being sent and paid for.

## What a refusal means

| Answer | Means |
| --- | --- |
| 501 | No provider is configured |
| 422 | The post cannot be translated, or is already in that language |
| 503 `quota` | The provider account has spent its allowance |
| 503 `Too many` | Rate limited; try again shortly |
| 503 `credentials` | The key was refused |

Each one says what somebody can do about it. "Something went wrong" is the one
answer nobody can act on, and mapping DeepL's 456 onto a quota message is the
difference between an admin topping up an account and an admin reading logs.
