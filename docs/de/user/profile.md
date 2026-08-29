# Profile

Deine Seite liegt unter `/@du`. Jemand auf einem anderen Server liegt unter
`/@sie@ihr.server`.

## Die drei Reiter

**Beiträge** lässt Antworten weg, damit jemand, der auf deinem Profil landet,
liest, was du gesagt hast, und nicht die Hälfte eines Gesprächs, das er nicht
sieht. **Beiträge und Antworten** zeigt alles. **Medien** zeigt nur die
Beiträge mit Bild, Video oder Ton.

Jeder Reiter hat eine eigene Adresse, du kannst also auf einen verlinken, und
der Zurück-Knopf führt dorthin zurück.

## Was ein Profil zeigt

**Angeheftete Beiträge** stehen auf dem ersten Reiter über allem anderen.
Anheften kannst du eigene öffentliche Beiträge, bis zu fünf davon; solche an
Follower nicht, denn was angeheftet ist, sieht jeder Profilbesuch.

**Hervorgehobene Hashtags** sind die Tags, unter denen man dich finden soll.
Einstellen kannst du sie in den [Einstellungen](einstellungen.md); andere Server
sehen sie ebenfalls, und ein Klick darauf öffnet die Beiträge dieser Person
unter diesem Tag, nicht die des ganzen Servers.

**Hervorgehobene Konten** sind Leute, die jemand auf dem eigenen Profil als
lesenswert nennt. Hervorheben kannst du nur, wem du folgst, und wenn du
entfolgst oder blockierst, verschwindet es von selbst. Die hervorgehobene
Person erfährt nichts davon, und an dem, was ihr voneinander lesen könnt,
ändert sich nichts.

Zum Hervorheben öffnest du das Profil der Person und drückst **Auf meinem
Profil hervorheben**. Der Knopf erscheint, sobald du ihr folgst, und vorher
nicht, denn der Follow ist die Grundlage dafür. **Nicht mehr hervorheben**
nimmt sie wieder herunter.

Wen du hervorgehoben hast, steht in einem Streifen auf dem ersten Tab deines
Profils, über deinen Beiträgen, und alle, die vorbeikommen, sehen ihn. Angezeigt
werden bis zu zwanzig; eine App über die API kann sich durch den Rest blättern.
Schaltest du in den [Einstellungen](einstellungen.md) **Verbergen, wem ich folge
und wer mir folgt** ein, verschwindet auch der Streifen, denn alle darin sind
Leute, denen du folgst.

**Neuigkeiten per E-Mail** stehen unten im Profilkopf, wenn die Person sie
eingeschaltet hat: ein Feld für deine Adresse, und danach eine Nachricht,
die fragt, ob die Adresse wirklich dir gehört. Ein Konto brauchst du dafür
nicht, und jede spätere Nachricht trägt einen Link, der die Neuigkeiten wieder
beendet.

**Felder** sind die vier Zeilen aus Bezeichnung und Wert unter deiner
Kurzbeschreibung. Ein Feld auf einem fremden Profil kann ein **Bestätigt**
tragen: Das ist der andere Server, der sagt, dass er den Link geprüft hat, und
wir zeigen, was er behauptet.

Deine eigenen Felder können die Marke hier ebenfalls bekommen. Schreib einen
Link auf eine Seite, die dir gehört, in den Wert, und setz auf diese Seite einen
Link zurück auf dein Profil:

```html
<a rel="me" href="https://dein.server/@du">Mastodon</a>
```

Der Server holt die Seite kurz nach dem Speichern, sucht dieses `rel="me"` und
markiert das Feld, wenn er es findet. Er schaut etwa einmal pro Woche wieder
nach: Ein verschwundener Rücklink verliert die Marke, ein später gesetzter
bekommt sie, ohne dass du etwas tun musst.

Was er nicht holt: einfache `http://`-Adressen, URLs mit Benutzername und
Passwort darin und Hostnamen in Nicht-ASCII-Buchstaben. Antwortet eine Seite mit
einem Fehler, behält das Feld seine bisherige Marke, denn ein Server, der einen
Nachmittag lang nicht erreichbar ist, beweist nicht, dass du deinen Link
entfernt hast. Selbst ein Datum ins Feld zu schreiben bringt nichts: Die Marke
ist die Aussage des Servers, nicht deine.

**Sammlungen** sind Listen von Konten, die jemand zusammengestellt hat — „Leute,
die ich kenne und die über Gärtnern schreiben“ — und als einen einzigen Link
weitergibt. Siehe [Finden](finden.md#sammlungen).

**Dieses Konto ist zu @jemand umgezogen** steht oben auf dem Profil von
jemandem, der weitergezogen ist, mit einem Link dorthin. Ohne das würdest du
einem Konto folgen, das nie wieder etwas schreibt, und nie erfahren, warum
nichts ankommt.

## Auf jemanden reagieren

Folgen, entfolgen, stummschalten und blockieren, dazu eine Notiz, die nur du
lesen kannst. Blockieren beendet auch deine Folge-Beziehung: Wer blockiert und
weiter folgt, hat eine Timeline voll mit der gerade blockierten Person.

Wen du blockierst, der sieht auch deine Beiträge nicht mehr, den direkten Link
auf die Seite eines Beitrags eingeschlossen.

Manche Leute bestätigen ihre Follower von Hand. Wer einem solchen Konto folgt,
schickt stattdessen eine Anfrage, und aus dem Knopf wird **Folgeanfrage
zurückziehen**, bis sie beantwortet ist. Ein Druck darauf nimmt die Anfrage
zurück; solange du wartest, kommt nichts von dort bei dir an.

## Mit der Tastatur lesen

`j` und `k` springen zwischen den Beiträgen auf jeder Seite, die welche
auflistet, und der Beitrag, auf dem du stehst, ist der, den der Browser
fokussiert hat – ein Screenreader liest ihn also vor und die Seite scrollt
dorthin. `Enter` öffnet ihn, `f` favorisiert, `b` teilt und `r` antwortet. `?`
listet alle Tastenkürzel auf.
