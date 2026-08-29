# The media pipeline

## What it needs on the machine

**ffmpeg and ffprobe** for video, audio and animated pictures, and **libvips**
(through `vix`) for still pictures. A server without ffmpeg still takes
pictures; a video uploaded there is recorded as failed with `ffmpeg_missing`
rather than crashing a worker on every attempt.

Processing runs in its own Oban queue, `media`, four at a time. Transcoding a
video is minutes of CPU where everything in the `ingress` queue is milliseconds
of database work, and one long video must not hold a slot inbound federation
needs.

## Pictures

- Capped at 3840×2160 **pixels**, on the product rather than either dimension,
  so a panorama and a poster are judged by how much work they are rather than
  how wide they are. Anything over is scaled down keeping its aspect.
- A 640×360-equivalent thumbnail.
- Metadata stripped, **ICC profile kept**. A photograph carries where it was
  taken and on what, and somebody posting a picture has not agreed to publish
  their address; dropping the colour profile as well would make wide-gamut
  images render wrong rather than merely unlabelled.
- A 4×4 blurhash, computed from a 32-pixel version of the picture. Encoding a
  full-size photograph would cost more and look identical.

## Video

The trick that matters is **passthrough**. A phone records h264 video and aac
audio, which is exactly what a transcode would produce, so when the streams are
already compliant and inside the frame limits the file is remuxed with
`-c copy`: the same bytes moved into a container with its index at the front.
Seconds instead of minutes, and no generation loss. `meta.passthrough` records
which path a file took.

Everything else is transcoded to h264/aac, scaled to fit 1920×1080, capped at
60fps, at a bitrate computed from the picture (0.08 bits per pixel per second)
rather than a number somebody picked, because 720p and 1080p at the same
bitrate are two very different pictures.

Either way the index goes at the front (`+faststart`). Without it a reader
watches a spinner for the length of the download, which on a phone is the
difference between a video somebody watches and one they scroll past.

The first frame becomes the thumbnail.

## Animated pictures

An animated GIF becomes an mp4 and is typed `gifv`. A looping GIF is an
enormous file for what it shows; clients already know how to play a `gifv`, and
it costs about a tenth as much to send.

## Audio

Transcoded to mp3. Cover art embedded in the file is pulled out as the
thumbnail **before** the transcode, since the transcode drops every stream that
is not audio, and its average colour is recorded as `meta.accent_colour` for a
player to draw itself in.

## The state machine

`queued → in_progress → complete`, or `failed`. The API's status codes hang off
it: `POST /api/v2/media` answers 202, and `GET /api/v1/media/:id` answers 206
until the attachment is complete.

A small picture (under 2 MB) is processed inside the request and comes back
complete, so an ordinary photo post is one round trip rather than two. It goes
through the same pipeline: a photograph that skipped it would reach a timeline
with its location metadata intact and no blurhash, and "it was under two
megabytes" is not a reason for that.

Failures are recorded, not retried forever. A file that cannot be processed
will not process on the fifth attempt either, and a client polling a 206 that
never becomes a 200 is waiting for something that is never coming. The attempts
that do happen are for the transient case: a machine that ran out of disk, or
an ffmpeg that was killed. The reason lands in `meta.error`.

Nothing here trusts the upload's own description of itself. A container can
claim anything, so what a file is comes from reading it.

## Where the files go

[Where media lives](media-storage.md) covers the layout, the two backends and
the remote-media cache.

## Limits

| Kind | Default | Setting |
| --- | --- | --- |
| Picture | 16 MB | `media_image_size_limit` |
| Video and audio | 99 MB | `media_video_size_limit` |

The instance document reports the same numbers, so a client that checks before
uploading and a server that refuses afterwards cannot disagree about what the
limit was.

## The media proxy

Another server's pictures are served from this one, at
`/media_proxy/:id/:style`, rather than linked straight from where they came
from.

The reason is the reader. A timeline of twenty posts from twelve servers,
rendered with the origin URLs, is twelve servers learning that reader's IP
address, their browser, and which posts they looked at and when. None of them
has any business knowing that: the reader chose to be here, not there.

The first request fetches the file through the ordinary outbound layer — the
same SSRF guards, circuit breaker and timeouts as everything else this server
fetches — and writes it where local attachments live. Everything after that is
served off disk, and `Abuuba.Media.VacuumWorker` drops it on your retention
setting exactly as it drops any other cached remote media. There is no second
cache with rules of its own.

It cannot be pointed anywhere. The path names an attachment row this server
already has, so the only URLs it will ever fetch are ones this server had
already decided to accept. A proxy that took a URL from the request would be an
open proxy, and open proxies get found.

One address may make this server fetch thirty pictures it does not yet have
per ten minutes, and after that it is answered 429. Only the fetches are
counted. A reader scrolling a busy timeline of pictures already on this disk
is reading local files and is never counted at all, however many they open --
what the limit exists for is somebody naming attachment rows in turn, each one
costing an outbound request to somebody else's server at the pace of whoever
is asking.

Files are served with a year's immutable cache, `nosniff`, and a content
security policy that stops them being read as pages: they are somebody else's
bytes served from your origin, which is where your session cookie lives.

## Media pages

`/media/:id` sends a media link to the post the file belongs to, which is where
it has its caption, its author and its thread. `/media/:id/player` is the bare
file for another site to frame, carrying no navigation and no session.
