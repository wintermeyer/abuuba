# Sachen finden

## Entdecken

`/explore` hat drei Reiter mit je eigener Adresse: **Beiträge**, **Hashtags**
und **Leute**. Es funktioniert auch abgemeldet, denn wer sich überlegt, ob er
mitmachen will, sollte vorher sehen können, was hier los ist.

Alles darin steht neueste zuerst. Eine Rangfolge danach, was tatsächlich
Aufmerksamkeit bekommt, ist eine eigene Baustelle, und ein Etikett „im Trend“
über einer unsortierten Liste wäre gelogen.

## Das Verzeichnis

Der Reiter „Leute“ listet Konten von hier, die darum gebeten haben, gelistet zu
werden. Voreingestellt ist Nein: Wer nie eine Einstellungsseite geöffnet hat,
hat nicht zugestimmt, auf einer öffentlichen Liste der Bewohner zu stehen.

## Vorschläge

Apps, die diesen Server fragen, wem du folgen könntest, bekommen die Konten,
denen die Leute folgen, denen du schon folgst — sortiert danach, wie viele von
ihnen sich einig sind. Das ist das einzige Signal, das aus Entscheidungen
deines eigenen Umfelds besteht und nicht daraus, was auf dem Server gerade
beliebt ist.

Es erscheinen nur Konten, die gefunden werden wollen, und nie eines, dem du
schon folgst, das du blockiert oder stummgeschaltet oder weggeklickt hast. Wer
dich blockiert hat, fällt ebenfalls raus, genauso jemand auf einem Server, den
du blockiert hast, und jemand, dem du schon eine Folgeanfrage geschickt hast
und auf dessen Antwort du noch wartest. Weggeklickt bleibt weggeklickt, die
Person kommt beim nächsten Laden also nicht zurück. Diese Weboberfläche hat
noch keine Vorschlagsspalte; das Verzeichnis ist hier das Gegenstück.

## Sammlungen

Eine Sammlung ist eine Liste von Konten, die jemand zusammengestellt und
veröffentlicht hat: „Leute, die ich kenne und die über Gärtnern schreiben“, als
ein Link statt als zwölf Namen in einem angehefteten Beitrag. Sie liegt unter
`/collections/<id>` und öffnet sich auch für jemanden, der sich nirgends
angemeldet hat — genau dafür ist sie da.

Anlegen kann sie jeder aus einer App heraus: ein Name, bis zu hundert Zeichen
Beschreibung und wahlweise der Hashtag, um den es geht. Zehn Listen pro Person,
fünfundzwanzig Konten pro Liste — eine Liste mit zweihundert Leuten empfiehlt
gar nichts.

**Auf eine Liste gesetzt zu werden braucht deine Erlaubnis nicht, und dich
selbst herunterzunehmen braucht niemandes.** Du wirst benachrichtigt, und ein
Druck nimmt dich endgültig herunter: Wer dich hinzugefügt hat, kann das nicht
rückgängig machen. Falls das verkehrt herum klingt — die Alternative ist eine
Liste, deren zwölf Einträge erst alle antworten müssen, bevor irgendjemand
etwas sieht, und die deshalb nie erscheint.

Unter einem Beitrag mit einem Hashtag kann eine App die Sammlungen zu diesem
Hashtag zeigen. Nur solche, die ihre Besitzer auffindbar gelassen haben; eine
Liste, die jemand für sich behält, gilt nie als Aussage über die Leute darauf.

Diese Weboberfläche zeigt die Seite einer Sammlung. Anlegen und Bearbeiten
machen Apps; einen Bildschirm dafür gibt es hier noch nicht.

## Hashtags

`/tags/gartenarbeit` zeigt alles, was unter diesem Hashtag abgelegt ist. Groß-
und Kleinschreibung spielt keine Rolle: `#Gartenarbeit` und `#gartenarbeit` sind
ein Hashtag. Ein Hashtag, den noch niemand benutzt hat, ist trotzdem eine Seite
und kein 404, denn jeder Hashtag in jedem Beitrag ist ein Link auf diese
Adresse.

Angemeldet kannst du einem Hashtag folgen, dann landen seine Beiträge in deiner
Startseite.

## Suche

`/search` sucht an drei Stellen gleichzeitig: Leute, Hashtags und Beiträge. `?q=`
und `?type=` stehen in der Adresse, eine Suche ist also ein Link, den du
verschicken, und ein Lesezeichen, das du behalten kannst.

Du siehst nur Beiträge, die du sehen darfst. Ein Beitrag an Follower taucht in
der Suche einer fremden Person nicht auf, bloß weil ein Wort passte.

### Eine Suche eingrenzen

| Geschrieben | Findet |
| --- | --- |
| `from:alice` | Beiträge einer Person |
| `has:media` | Beiträge mit Bild, Video oder Ton |
| `has:poll` | Beiträge mit Umfrage |
| `is:reply` | Antworten, ebenso `is:boost` oder `is:sensitive` |
| `language:de` | Beiträge in einer Sprache |
| `in:library` | nur, was du geschrieben oder aufgehoben hast |
| `in:public` | alles, was jeder lesen darf |
| `before:2026-01-01` | Beiträge vor einem Datum |
| `after:2026-01-01` | Beiträge nach einem Datum |
| `during:2026-01-01` | Beiträge von einem Tag |

Sie lassen sich mit Wörtern und miteinander kombinieren:
`from:alice has:media gartenarbeit`. Das `@` vor einem Namen ist optional.
`is:` und `has:` darfst du mehrfach angeben, und jedes davon schränkt weiter
ein: `is:reply is:sensitive` findet Antworten mit einer Warnung und nicht das
eine oder das andere. Bei den übrigen gilt das zuletzt Getippte, denn zwei
Autoren oder zwei Sprachen sind ein Widerspruch und keine Verfeinerung.

Alles, was wie ein Operator aussieht und keiner ist, bleibt Teil der Wörter: Wer
nach `farbe:blau` sucht, findet diesen Text. Ein Datum, das keines ist, macht
dasselbe – `before:bald` ist eine Suche nach „before:bald“.

`from:` mit einem Namen, den es nicht gibt, findet nichts statt alles. Die
Operatoren grenzen Beiträge ein und bedeuten für einen Namen oder einen Hashtag
nichts, diese beiden Abschnitte suchen also nach den getippten Wörtern und
übergehen die Operatoren.

## Wie die Treffer zustande kommen

Die Suche findet ganze Wörter, keine Bruchstücke: `garten` findet nicht
`gartenarbeit`. Wörter in Anführungszeichen suchen die Wendung, und ein Minus
davor lässt eines weg: `gartenarbeit -sonne`.

Welche Beiträge auffindbar sind, ist enger gefasst als welche du lesen darfst.
Alles Öffentliche findet jeder. Alles andere findet nur, wer es geschrieben hat,
wer darin erwähnt wird, und wer es favorisiert, geteilt oder als Lesezeichen
abgelegt hat – also die Leute, die es aufgehoben haben. `in:library` sucht nur,
was du geschrieben oder aufgehoben hast, `in:public` sucht alles, was jeder
lesen darf.

## Trends

Entdecken listet, worüber gerade mehr Leute schreiben als sonst: Hashtags, Links
und Beiträge. Das wird daraus berechnet, wie viele verschiedene Leute etwas
heute benutzt haben verglichen mit gestern, ein Hashtag, den täglich zehn Leute
benutzen, taucht also nicht auf. Gleichmäßige Nutzung ist kein Trend.

In diese Listen kommt nichts, bevor jemand aus der Moderation es angesehen und
freigegeben hat. Das macht die Listen kürzer, als sie sein könnten, und es
sorgt dafür, dass darin nicht einfach steht, was am härtesten geschoben wurde.

Deine eigenen Beiträge erscheinen dort nur, wenn dein Profil auffindbar gestellt
ist und die Moderation dein Konto freigegeben hat. Antworten, als heikel
markierte Beiträge und alles, was nicht öffentlich ist, zählen nie mit.

## Die Startseite des Servers

Abgemeldet sagt `/`, was dieser Server ist, ob man sich anmelden kann, und zeigt
neue öffentliche Beiträge von Leuten hier. Angemeldet führt sie dich direkt zu
deiner eigenen Timeline.
