# Öffentliche Seiten, Einbetten und Teilen

## Was Besucher sehen

Beiträge, Profile, Entdecken, Hashtags, die Startseite und die Info-Seite
funktionieren ohne Anmeldung und ohne JavaScript. Sie werden vom Server gebaut,
ein irgendwo eingefügter Link zeigt also eine echte Vorschau, und wer ihm folgt,
liest die tatsächliche Seite statt eines Ladekringels.

## Suchmaschinen

Jede öffentliche Seite hier bittet Suchmaschinen, sich fernzuhalten, und zwar so
lange, bis das zugehörige Konto etwas anderes sagt. Der Schalter dafür ist
**Suchmaschinen dürfen meine Beiträge indexieren** unter Einstellungen →
Privatsphäre; er steht anfangs aus, und einschalten nimmt die Bitte von deinem
Profil und von deinen Beiträgen. Die Seiten mit deinen Folge-Listen nehmen sie
nie zurück, denn dort stehen andere Leute, die niemand gefragt hat.

Die Seiten, die Beiträge anderer Leute sammeln — Entdecken, ein Hashtag, ein
Suchergebnis, eine Sammlung — bitten Suchmaschinen fernzubleiben, ganz gleich
was jemand angehakt hat. Die Leute auf so einer Seite sind sich untereinander
uneinig, und bei Uneinigkeit gilt die strengere Antwort. Die Info-Seite, die
Startseite, die Nutzungsbedingungen und der Datenschutz bleiben auffindbar: Das
sind die eigenen Worte des Servers, und ein Server, den niemand suchen kann,
nützt niemandem bei der Suche nach einem.

Das ist eine Bitte und keine Mauer. Einen Crawler, der sie ignoriert, hält hier
nichts auf, und ein Beitrag, den jemand anderes zitiert oder geteilt hat, liegt
auf dessen Server unter dessen Einstellung.

## Info, Nutzungsbedingungen und Datenschutz

`/about` trägt, was dieser Server ist, seine Regeln, wie man den Betreiber
erreicht, und die Zahlen: Leute, Beiträge, bekannte Server, und wie viele
Menschen diesen Monat und dieses Halbjahr aktiv waren. Es sind dieselben Zahlen,
die die Programmierschnittstelle meldet, die beiden können sich also nicht
widersprechen.

`/terms` und `/privacy` zeigen, was die Administration hier geschrieben hat, mit
dem Datum, ab dem der Text galt. Bedingungen, denen jemand im März zugestimmt
hat, sind nicht die Bedingungen vom September, das Datum gehört also zum
Dokument. Wo nichts geschrieben wurde, sagt die Seite das, statt leer zu sein.

## Einen Beitrag einbetten

Jeder öffentliche Beitrag lässt sich auf einer anderen Seite einbinden.
`/embed/<id>` ist der Beitrag für sich, ohne Navigation und ohne Eingabefeld,
und es ist die einzige Adresse auf diesem Server, die in einem Rahmen stehen
darf.

Redaktionssysteme, die oEmbed verstehen, finden sie von selbst: Die Seite eines
Beitrags trägt einen `json+oembed`-Link, und `/api/oembed?url=<der Beitrag>`
beschreibt den Rahmen. Beantwortet werden nur Adressen auf diesem Server, dieser
Endpunkt lässt sich also nicht dazu benutzen, eine fremde Seite so aussehen zu
lassen, als käme sie von hier.

Eine Einbettung zeigt nur, was alle sehen können. Zu einem Beitrag an Follower
gibt es keine.

## Hierher teilen

`/share?title=…&text=…&url=…` öffnet das Eingabefeld mit diesen Bestandteilen
darin – darauf zeigt ein Knopf „auf deinem Fediverse-Server teilen“ auf einer
anderen Seite. Gepostet wird nichts, bis du auf Senden drückst.

## Vom eigenen Server aus reagieren

Wenn du hier einen Beitrag liest und dein Konto woanders liegt, passieren
Folgen, Antworten und Teilen auf deinem Server und nicht auf diesem.
`/authorize_interaction?uri=<der Beitrag>` fragt nach deiner Adresse und schickt
dich zur Suche deines eigenen Servers, in die diese Adresse schon eingetragen
ist.

Nach einem Passwort wird nicht gefragt, und in deinem Namen passiert nichts. Es
ist nur eine Weiterleitung.

## Wer wem folgt

`/@name/followers` und `/@name/following`, als Reiter auf jedem Profil
verlinkt. Sie sind öffentlich, denn wem jemand folgt, steht ohnehin öffentlich
auf dem Profil, von dem aus gefolgt wird.

Wer das nicht möchte, schaltet unter Einstellungen → Privatsphäre **Verbergen,
wem ich folge und wer mir folgt** ein. Die Seiten sagen das dann allen außer der
Person selbst, die ihre eigenen Listen weiterhin sieht — eine Einstellung, die
die Listen vor der Person verbirgt, die sie gesetzt hat, sähe beim ersten
Nachschauen wie ein Fehler aus. Apps über die API bekommen dieselbe leere
Antwort, die Einstellung bedeutet also überall dasselbe. Die Folge-Beziehungen
funktionieren so oder so.

Der Streifen mit hervorgehobenen Konten auf dem Profil geht mit ihnen, denn alle
darin sind Leute, denen das Konto folgt.

## Feeds

`/@name/feed.rss` sind die öffentlichen Beiträge einer Person,
`/tags/etwas/feed.rss` ist alles Öffentliche zu einem Hashtag. Beides ist
gewöhnliches RSS, jeder Feed-Reader kommt damit zurecht, und für beides braucht
es nirgendwo ein Konto.

Für den Hashtag-Feed gilt dieselbe Regel wie für die Hashtag-Seite: Hat die
Administration die Timelines für Leute ohne Konto geschlossen, kommt er leer
zurück. Ein Profil-Feed ist keine Timeline und bleibt davon unberührt.

In einem Feed stehen nur öffentliche Beiträge und nie ein Boost: ein Feed ist
eine Liste dessen, was jemand geschrieben hat, und einer, der sich nach einem
fleißigen Boost-Nachmittag mit fremden Beiträgen füllt, wird abbestellt. Nicht
gelistete Beiträge sind ebenfalls draußen, denn „nicht gelistet" heißt genau
„nicht in den Listen, die dieser Server veröffentlicht", und ein Feed ist eine
davon.

Eine Inhaltswarnung wird zum Titel des Eintrags, damit in der Übersicht eines
Readers die Warnung steht und nicht das, wovor sie warnt.

## Zwei Adressen für dieselbe Sache

Jedes Konto und jeder Beitrag hier hat zwei Adressen. `/@alice` und
`/@alice/12345` sind die Seiten, die Menschen lesen. `/users/alice` und
`/users/alice/statuses/12345` benutzen andere Server: das sind die
Kennungen, die in jeder Nachricht mitreisen, die abuuba verschickt. Sie landen
also in fremden Datenbanken und früher oder später auch in einem Browser oder
einem Chatfenster.

Wer so eine Adresse im Browser öffnet, landet auf der Seite. Für andere Server
ändert sich nichts — die fragen ein anderes Format an und bekommen dieselbe
Antwort wie immer. Ein Link, den jemand aus einer Nachricht kopiert hat,
funktioniert damit für Menschen, ohne für Maschinen kaputtzugehen.

Adressen ohne Seite, etwa die Outbox eines Profils, sagen weiterhin, dass sie
sich nicht als Seite anzeigen lassen. Stattdessen aufs Profil zu schicken hieße,
eine Frage zu beantworten, die niemand gestellt hat.
