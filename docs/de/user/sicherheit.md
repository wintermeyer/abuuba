# Sicherheit

Vier Werkzeuge, die vier verschiedene Dinge tun. Zum falschen zu greifen ist der
übliche Grund, warum jemand hinterher immer noch unzufrieden ist.

| Du willst | Nimm |
| --- | --- |
| jemanden nicht mehr sehen, ohne Aufhebens | stummschalten |
| dass die Person dich auch nicht mehr sieht | blockieren |
| ein Thema nicht mehr sehen, egal von wem | einen Filter |
| dass die Moderation sich jemanden ansieht | eine Meldung |

## Stummschalten

Auf dem Profil: **Stummschalten**. Die Beiträge verschwinden aus deiner Timeline
und die Benachrichtigungen erreichen dich nicht mehr.

Die Person erfährt es nicht, kann dir weiter folgen und dich weiter lesen, und
du kannst es an derselben Stelle rückgängig machen. Das ist das höfliche
Werkzeug und das richtige für jemanden, den du kennst, aber heute nicht in
deiner Timeline haben willst.

Stummschalten wirkt rückwirkend genauso wie vorwärts. Deine Timeline wird beim
Aufbauen gefiltert, also verschwinden auch die Beiträge, die vor dem
Stummschalten entstanden sind, beim nächsten Neuladen. Gelöscht wird nichts,
deshalb ist beim Aufheben alles sofort wieder da.

Stummschalten wirkt überall dort, wo Beiträge auftauchen, nicht nur in der
Timeline: auch aus der Suche, aus Entdecken, von jeder Hashtag-Seite und aus
den Antworten unter einem Thread ist die Person verschwunden, und ebenso alles
von ihr, was jemand anderes teilt.

## Blockieren

Auf dem Profil: **Blockieren**. Alles, was Stummschalten tut, und zusätzlich:
Die Person kann dir nicht mehr folgen, bestehende Folge-Beziehungen in beide
Richtungen werden aufgelöst, und was sie schon in deiner Timeline hinterlassen
hat, wird wieder herausgenommen. Solange sie angemeldet ist, antwortet ihr dein
Profil mit nichts: keine Beiträge, keine angehefteten Beiträge, keine deiner
beiden Folge-Listen. Apps bekommen dieselbe leere Antwort wie die Webseite.

Ein Block gilt für ihre Worte, wo immer sie auftauchen: auch geteilt von
jemand anderem, in einem Thread, in der Suche und auf jedem Profil, das sie
geteilt hat. Nur ihr eigenes Profil siehst du weiterhin, wenn du es aufrufst –
das aufzuschlagen ist deine Entscheidung, und ein Block regelt, was dich
erreicht.

## Einen ganzen Server blockieren

Unter `/settings/filters`, im Abschnitt **Blockierte Server**: Manche Server
machen mehr Ärger als die einzelnen Konten darauf. Eine Domain zu blockieren schließt alle dort auf
einmal aus – nichts davon erreicht deine Timelines, deine Suche, deine Threads
oder deine Benachrichtigungen, und geteilte Beiträge gehen mit. Bestehende
Folge-Beziehungen in beide Richtungen werden aufgelöst wie beim Blockieren
einer Person.

Blockieren ist insofern sichtbar, als die Person merkt, dass sie dich nicht mehr
sieht. Eine Ankündigung bekommt sie nicht.

**Was Blockieren nicht kann.** Das hier ist ein Netz aus unabhängigen Servern.
Wer blockiert ist, kann sich abmelden und deine öffentlichen Beiträge lesen wie
jede fremde Person, und wer will, legt sich ein zweites Konto an. Blockieren
sorgt dafür, dass jemand verschwindet; unsichtbar macht es dich nicht. Wenn das,
was du schreibst, nur bestätigte Leute sehen sollen, stell deine Beiträge auf
„nur Follower“ und bestätige deine Follower selbst – siehe [Beiträge
schreiben](beitraege.md) und den Abschnitt Privatsphäre in den
[Einstellungen](einstellungen.md).

## Filter

Unter `/settings/filters`: Wörter und Wendungen, die du nicht sehen willst, egal
von wem. Jeder Filter sagt, **wo** er gilt – Startseite, Benachrichtigungen,
öffentliche Timelines, Threads, Profile – und **was** er tut: den Beitrag hinter
einer Warnung zusammenfalten, die du aufklappen kannst, oder ihn ganz
ausblenden.

Zusammenfalten ist meistens die bessere Voreinstellung. Bei einem Filter, der
ausblendet, merkst du nicht, wenn er danebengreift.

## Wer dich erreichen darf

`/settings/notifications` nimmt sechs Arten von Absendern – Leute, denen du
nicht folgst, Leute, die dir nicht folgen, sehr neue Konten, private Erwähnungen
von jemandem, der nicht auf dich antwortet, von der Moderation eingeschränkte
Konten und automatisierte Konten – und lässt dich jede davon annehmen, filtern
oder ignorieren. Wo ein Absender auf mehrere davon passt, gilt die strengste
Antwort.

**Filtern ist das Umkehrbare.** Es legt die Nachrichten auf eine Warteliste auf
derselben Seite, wo du sie weiterhin lesen und durchwinken kannst.
**Ignorieren hebt nichts auf**, es gibt also nichts, was du dir später anders
überlegen könntest. Nimm im Zweifel Filtern.

Ausführlicher steht das unter [Benachrichtigungen](benachrichtigungen.md).

## Jemanden melden

Meldungen gehen an die Moderation dieses Servers und, wenn du willst,
zusätzlich an die Moderation des Servers, von dem die Person kommt.

**Einen Melde-Knopf gibt es in der Weboberfläche noch nicht.** Melden geht über
die Programmierschnittstelle, eine Mastodon-kompatible App kann also eine
Meldung abgeben. Wenn dir keine App zur Verfügung steht, schreib an die Adresse
auf der [Info-Seite](oeffentliche-seiten.md) des Servers; eine Beschreibung per
Mail ist langsamer als eine Meldung, aber nicht schlechter.

Eine Meldung kann mehrere Beiträge benennen, einen Satz dazuschreiben, was daran
falsch ist, und auf Wunsch eine Kopie an den anderen Server weitergeben. Bei
Spam lohnt das Weitergeben; bei einem persönlichen Streit sollte man es sich
überlegen, denn es sagt der Gegenseite, wer sich beschwert hat.

## Passwort vergessen

`/reset-password`, verlinkt von der Anmeldeseite. Gib die Adresse an, mit der du
dich angemeldet hast, und ein Link kommt per E-Mail zurück. Der Link
funktioniert einmal und gilt sechs Stunden.

Die Seite antwortet gleich, egal ob es zu der Adresse ein Konto gibt oder nicht.
Das ist Absicht: stünde dort "kein solches Konto", könnte jeder über das
Formular herausfinden, wer auf diesem Server ist, und diese Liste ist für
Leute, die Phishing-Mails schreiben, einiges wert.

Ein neues Passwort zu setzen meldet dich überall ab, auch in Apps. Das ist der
Zweck und kein Nebeneffekt: wer sein Passwort zurücksetzt, vermutet meistens
jemand anderen im eigenen Konto, und eine angemeldet gebliebene App lässt diese
Person genau dort.

Zwei Dinge ändert ein Zurücksetzen **nicht**. Es schaltet die Anmeldung in zwei
Schritten nicht ab: das Zurücksetzen beweist, dass du deine E-Mail lesen kannst,
und genau das soll der zweite Schritt überleben. Und falls du deine Adresse nie
bestätigt hattest, gilt sie danach als bestätigt, weil es derselbe Beweis ist.

Du bekommst eine zweite E-Mail, die dir sagt, dass das Passwort geändert wurde.
Wenn so eine ankommt und du es nicht warst, fordere sofort ein neues Passwort an
und sag den Leuten Bescheid, die diesen Server betreiben.

## Anmeldung in zwei Schritten

`/settings/two-factor`. Dein Passwort plus ein Code aus einer App auf deinem
Telefon, damit ein gestohlenes Passwort allein nicht reicht.

Bewahre die Wiederherstellungscodes, die du dabei bekommst, an einem anderen Ort
auf als auf dem Telefon. Telefon und Codes gleichzeitig zu verlieren heißt, das
Konto zu verlieren, und niemand aus der Moderation kann das für dich abschalten.

Wo du gerade in diesem Teil der Einstellungen bist: **Überall abmelden** auf der
Sicherheitsseite beendet jede Sitzung, auch die, in der du gerade sitzt. Das ist
das Mittel für den geliehenen Rechner, von dem du dich abzumelden vergessen
hast.

## Wenn dein Konto eingeschränkt wird

Wenn die Moderation etwas mit deinem Konto macht, erfährst du, was passiert ist
und warum, und es gibt einen Einspruch. Beides steht unter
`/settings/moderation`, zusammen mit allem, was mit dem Konto schon passiert
ist. Die Gegenseite desselben Vorgangs steht im Handbuch für Admins unter
[account actions, strikes and appeals](../../admin/account-actions.md)
(englisch).
