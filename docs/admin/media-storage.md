# Where media lives

## Two backends, one behaviour

Local disk by default; an S3-compatible bucket when configured. Everything else
in the application asks for a key and a URL and does not know which is in
force, which is what lets a server move from one to the other without touching
anything but configuration.

| Variable | Means |
| --- | --- |
| `MEDIA_ROOT` | Where the local backend writes |
| `MEDIA_STORAGE=s3` | Use the bucket instead |
| `S3_BUCKET`, `S3_REGION` | The bucket |
| `S3_ENDPOINT` | For anything that speaks the protocol without being AWS |
| `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | Credentials |
| `MEDIA_ALIAS_HOST` | A CDN in front of either backend |

S3 requests are signed here rather than through an SDK. The whole of what this
server needs is PUT, DELETE and HEAD on one bucket, and a signing function is a
hundred lines where an SDK is a dependency tree with its own HTTP client, its
own configuration and its own opinions about credentials.

Set `S3_ENDPOINT` for anything that is not AWS and the bucket becomes the first
segment of the path rather than part of the hostname. Both shapes are signed
correctly, and the path-style one has been checked against a real MinIO bucket
rather than only against a stub: a signature is either accepted by a server or
it is not, and nothing short of a server can tell you which.

## The layout is the reference implementation's

```
media_attachments/files/003/815/271/original/8f3c2a1b4d5e6f70.jpg
└── class ──────┘ └─┘  └── id ────┘ └ style ┘ └── filename ───┘
```

The id is padded to at least nine digits and split into three-digit groups.
Not because it is the best possible layout, but because a server moving to abuuba
can copy its media tree across byte for byte and have every path still resolve.
A layout of our own would make the importer rewrite millions of paths, and
every one it got wrong would be a picture nobody can see any more.

Padding keeps the tree even: without it the first thousand attachments would
all sit in one directory and everything after them in another shape entirely.

## Names are ours, never the uploader's

Random, with only the extension surviving from what was uploaded, bounded and
stripped of anything that is not a letter or a digit. A filename arrives from a
stranger: keeping it hands them a say in the URL, and two people uploading
`holiday.jpg` would collide. The extension survives because it is what tells a
browser whether to play a video or offer a download.

## Other people's media sits under `cache/`

```
cache/media_attachments/files/003/815/271/original/…
```

One prefix, and it is what makes a whole tree of it safe to delete. Remote
media can be fetched again from the server it came from; a local file has
nowhere to be fetched back from, and deleting one is deleting somebody's
picture.

`Abuuba.Media.VacuumWorker` runs daily and drops remote copies older than the
`content_retention_days` setting, leaving the row with its `remote_url` intact
so the attachment still renders as itself and the bytes come back when somebody
looks at the post. **Off unless a retention is set**: somebody who has not
chosen a number has not chosen to delete anything.

Coming back happens on the first request through the media proxy, so the reader
who asks first waits for the round trip. `mix abuuba.media refresh` does it ahead
of them in bulk — worth running after a retention sweep took more than it was
meant to, or before a server everybody here reads from goes away for good.

## Cache headers

Objects are immutable. The name contains random bytes and the id is never
reused, so what sits at a key is the same bytes forever. S3 objects are written
with `cache-control: public, max-age=31536000, immutable`, and the local
backend serves the same header through `Plug.Static`. That is the difference
between a CDN that fetches a picture once and one that revalidates it on every
reader's timeline.

## Upgrading a pre-release copy

Media used to be stored flat as `<id>.<ext>` in the root. Nothing migrates
those: this project has no releases yet, and a dev or test copy is regenerated
by uploading again. A server that did have data would move each file to
`media_attachments/files/<partition>/original/<name>` and set the row's
`file_file_name` to the basename.
