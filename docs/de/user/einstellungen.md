# Einstellungen

Alles über dein eigenes Konto liegt unter `/settings`, ein Abschnitt pro
Adresse, alles in derselben Oberfläche. Es gibt keine Naht, an der Layout und
Navigation unter dir wechseln.

## Profil

Dein Anzeigename, was du über dich schreibst, und bis zu vier Felder aus je
einer Bezeichnung und einem Wert, auf deinem Profil in der Reihenfolge, in der
du sie eingetragen hast.

Ein Feld, dessen Wert ein Link ist, kann ein **Bestätigt** bekommen; wie die
Prüfung abläuft und was der Server nicht holt, steht unter
[Profile](profile.md).

Ein Profilbild und ein Titelbild lassen sich auf dieser Seite noch nicht
hochladen. Eine App, die die Mastodon-API spricht, kann sie schon heute setzen.

## Darstellung

Bewegung reduzieren, mehr Kontrast, die Schrift deines Systems, und Medien nicht
von selbst abspielen. Jede dieser Einstellungen folgt deinem Betriebssystem,
solange du sie hier nicht setzt; das hier ist also die Ausnahme für den Fall,
dass die Systemeinstellung für dich falsch ist.

Die Erinnerung an fehlende Bildbeschreibungen steht auch hier.

Datums- und Zahlenangaben richten sich nach der Sprache der Oberfläche: auf
einer deutschen Seite steht `05.12.2026` und `1.234,5`, auf einer englischen
`Dec 5, 2026` und `1,234.5`. Die Sprache kommt zuerst aus deiner eigenen
Einstellung, dann aus der, die du in diesem Browser gewählt hast, dann aus dem,
was dein Browser anfragt.

## Beiträge

Womit das Eingabefeld anfängt: an wen neue Beiträge gehen, wer sie zitieren
darf, und die Sprache, in der du üblicherweise schreibst.

„Nur die Erwähnten“ fehlt in der Liste der Zielgruppen mit Absicht. Als
Voreinstellung macht es aus jedem Beitrag, den du zu ändern vergisst, eine
Nachricht an niemanden.

**Sagen, aus welcher App du schreibst** ist zu Beginn eingeschaltet. Apps zeigen
das unter einem Beitrag — „via Ivory“ — und man erkennt daran, was jemand
selbst geschrieben und was ein Bot oder eine Zeitplanung geschickt hat.
Schaltest du es aus, verschwindet es für alle anderen; du selbst siehst es
weiterhin an deinen eigenen Beiträgen, denn zu vergessen, womit du etwas
geschrieben hast, wolltest du nicht. Es gilt nur für Beiträge von hier: Was ein
Beitrag von einem anderen Server sagt, ist dessen Sache.

## Angeheftete Beiträge und alte Beiträge löschen

Beides auf der Seite **Beiträge**.

**Angeheftete Beiträge** stehen oben auf deinem Profil. Angeheftet wird vom
Beitrag aus; hier siehst du die Liste und nimmst einen wieder herunter.

**Meine alten Beiträge löschen** ist aus, solange du es nicht einschaltest, und
bleibt aus, wenn du das Alter leer lässt. Trag ein Alter in Tagen ein, und alles
Ältere geht, stündlich in Häppchen, mit den Ausnahmen, die du wählst:
angeheftete Beiträge behalten (standardmäßig an), Beiträge mit Bildern oder
Video behalten, und alles behalten, was mindestens so oft favorisiert oder
geboostet wurde. Wer das benutzt, sagt meistens „das Geplauder geht, was
gezählt hat bleibt", und diese Schwellen sind, wie du sagst, was was war.

Die Seite sagt dir vorher, wie viele Beiträge betroffen sind — „das löscht
vierhundert Beiträge" vorher zu wissen ist der Unterschied zwischen einer
Einstellung und einer Überraschung. Die Beiträge gehen denselben Weg wie beim
einzelnen Löschen: andere Server werden informiert, und rückgängig geht es
nicht.

## Privatsphäre

| Einstellung | Was sie tut |
| --- | --- |
| Follower erst bestätigen | Jede Folge-Beziehung wird zu einer Anfrage, die du beantwortest |
| Mich im Verzeichnis listen | Dein Konto erscheint auf der öffentlichen Verzeichnisseite dieses Servers |
| Suchmaschinen dürfen meine Beiträge indexieren | Anfangs aus. Solange er aus ist, bitten dein Profil und deine Beiträge Crawler, sie zu überspringen; gilt nur für öffentliche Beiträge |
| Verbergen, wem ich folge und wer mir folgt | Die Listen sind nicht mehr öffentlich, und der Streifen mit hervorgehobenen Konten auf deinem Profil geht mit ihnen; die Folge-Beziehungen bleiben |
| Dieses Konto schreibt automatisch | Markiert es als Bot, worauf manche Leute filtern |

**Seiten, die mich als Autorin oder Autor nennen dürfen** ist das Feld unter
diesen Schaltern. Eine Domain pro Zeile — `example.com`, oder füg die ganze
Adresse ein, das Schema wird abgeschnitten. Teilt jemand hier einen Link auf
eine eingetragene Seite, weist die Vorschaukarte dich als Urheberin oder
Urheber aus, mit Namen und Bild.

Es geht deshalb in diese Richtung, weil die Angabe von der Seite selbst kommt.
Eine Seite kann behaupten, irgendwer habe sie geschrieben; die Domain hier
einzutragen ist deine Zustimmung dazu. Eine Seite, die du nicht eingetragen
hast, kann deinen Namen nicht an ihre Links hängen, egal was in ihrer
Seitenquelle steht. Bleibt das Feld leer, kann es niemand.

**Hervorgehobene Hashtags** sind Abkürzungen zu dem, worüber du schreibst; sie
stehen auf deinem Profil, mit der Zahl der öffentlichen Beiträge dazu. Tipp
einen ein oder nimm einen der Vorschläge — das sind Tags, die du mehr als
einmal benutzt und noch nicht hervorgehoben hast. Gezählt wird nur, was
Besucher auch sehen könnten.

## Neuigkeiten per E-Mail

Das erscheint nur, wenn die Administration es für den Server eingeschaltet hat.
Damit kann jemand, der hier kein Konto möchte, stattdessen eine E-Mail-Adresse
angeben und lesen, was du schreibst.

Wenn du es einschaltest, siehst du, wie viele Adressen bestätigt haben. An eine
Adresse geht nichts, bevor die Person dahinter selbst bestätigt hat, und eine
Adresse ohne Bestätigung bekommt höchstens eine Nachricht pro Tag, egal wie oft
das Formular abgeschickt wird — eine Adresse, die jemand aus Versehen oder mit
Absicht eingetippt hat, lässt sich also nicht mit Nachrichten überziehen. Eine
Adresse, die nie antwortet, wird nach einer Woche gelöscht. In jeder Nachricht
steht ein Link, der die Neuigkeiten beendet, und dafür braucht es weder Konto
noch Passwort.

Wieder ausschalten beendet neue Abos. Die Adressen, die schon bestätigt haben,
werden dabei nicht gelöscht.

Sobald jemand bestätigt hat, erscheint unter dem Schalter ein Feld **An sie
schreiben**: Betreff, Text, und es geht an alle bestätigten Adressen. Bis zu
vier Nachrichten am Tag; darunter steht, was du schon geschickt hast, mit Datum
und der Zahl der erreichten Adressen. Jede Nachricht trägt denselben Link zum
Beenden, und E-Mail-Programme mit eigenem „Abbestellen“-Knopf finden ihn in den
Kopfzeilen.

Abonniert wird auf deiner Profilseite: Ist das eingeschaltet, steht unter
deiner Kurzbeschreibung ein kleines Formular, das nach einer Adresse fragt. Du
musst dafür nichts weitergeben außer der Adresse deines Profils.

## Filter

Wörter und Wendungen, die du nicht sehen willst. Ein Filter nennt, wo er gilt
(Startseite, Benachrichtigungen, öffentliche Timelines, Threads, Profile),
wonach er sucht, ein Wort pro Zeile, und was er tut: den Beitrag hinter einer
Warnung zusammenfalten oder ihn ganz ausblenden.

Ein Filter sucht nach ganzen Wörtern, solange du nichts anderes sagst; „Katze“
lässt „Katzenklo“ also in Ruhe. Für einen Filter, der einen Wortteil erwischen
soll, nimm das Häkchen weg. Groß- und Kleinschreibung spielt keine Rolle, und
gesucht wird auch in der Inhaltswarnung, denn genau dort steht meistens das
Thema.

Diese Seiten halten sich daran. Ein Beitrag, auf den eine **Falten**-Regel
passt, erscheint als eine Zeile mit dem Namen der Regel und **Trotzdem
anzeigen** daneben — so kannst du deine eigene Regel für einen einzelnen
Beitrag aufheben, ohne hierher zurückzugehen. Ein Beitrag, auf den eine
**Verstecken**-Regel passt, wird gar nicht erst gezeichnet, und der Name der
Regel auch nicht: Verstecken heißt, nicht einmal erfahren zu wollen, dass da
etwas war.

Das gilt überall, wo Beiträge aufgelistet werden — Startseite, Hashtag, Profil
und Thread, je nach den Stellen, die du angehakt hast. Die eine Ausnahme ist
ein Beitrag, den du selbst geöffnet hast: Einem Link zu einem Beitrag zu folgen
heißt, genau diesen Beitrag sehen zu wollen, also wird er gezeigt, auch wo
deine Regeln ihn in einer Liste gefaltet hätten.

Der Server löscht und versteckt nichts vor dir: Ein gefilterter Beitrag kommt
weiterhin an, und erst deine eigene Ansicht faltet ihn zusammen oder lässt ihn
weg. Genau deshalb zeigt dir das Aufheben eines Filters, was du verpasst hast.

Eine App kann einem Filter auch einen einzelnen Beitrag hinzufügen — für den
einen, der durch die Wörter rutscht, weil er über die Sache schreibt, ohne sie
zu nennen. In dieser Weboberfläche gibt es dafür noch keinen Knopf; Apps, die
die Mastodon-API sprechen, können es.

## Folge ich

Alle, denen du folgst, mit je einem Kästchen. Mehrere ankreuzen und in einem
Zug entfolgen, statt einzeln nacheinander.

Wer auf *dich* wartet, steht nicht hier, sondern auf einer eigenen Seite, die
die Navigation mit einer Zahl anzeigt, solange jemand wartet. Siehe
[Folgeanfragen](sicherheit.md#folgeanfragen).

## Sicherheit

Passwort ändern, wofür das aktuelle nötig ist: Sonst gehört das Konto dem, der
an einen unbeaufsichtigten Bildschirm tritt.

Die Anmeldung in zwei Schritten hat eine eigene Seite. **Abmelden** beendet
diese eine Sitzung und lässt deine anderen Geräte in Ruhe; es steht auch in der
Seitenleiste unter der Navigation, auf jeder Seite. **Überall abmelden** beendet
jede Sitzung, auch die, in der du gerade sitzt — das ist der Griff für einen
Rechner, dem du nicht mehr traust.


**Letzte Anmeldungen** listet die jüngsten Versuche an deinem Konto mit
Zeitpunkt, Adresse und Browser — auch die gescheiterten. Dass jemand anderes
dein Passwort probiert, ist genau das, was man früh mitbekommen sollte, und
nichts sonst hier würde es dir sagen. Die Liste wird 30 Tage aufgehoben und dann
gelöscht: sie ist dafür da, „war ich das letzten Dienstag" zu beantworten, und
nicht dafür, ein Archiv deiner Aufenthaltsorte zu sein.

## Apps

Apps, bei denen du dich mit diesem Konto angemeldet hast. Eine davon
zurückzuziehen entwertet jedes Token, das sie für dich hält – eine App, die
zweimal angemeldet ist, bleibt also nicht einmal angemeldet.

Zu jeder App steht, was sie darf — in denselben Worten wie auf dem
Anmeldebildschirm, den du beim Einlassen gesehen hast: deine Timelines lesen,
für dich posten, in deinem Namen Leuten folgen und so weiter. Das sind Grenzen
und keine Etiketten. Eine App, die nur lesen wollte, kann auch dann nichts
posten, wenn sie es versucht; der Server weist sie ab, statt sich darauf zu
verlassen, dass die App sich benimmt.

Eine App, die zweimal angemeldet ist, hat zwei Sätze von Rechten, und die Zeile
zeigt beide zusammen — die Frage ist ja, was diese App erreichen kann, und
nicht, welche ihrer Anmeldungen es kann. Braucht eine App später mehr, muss sie
dich erneut über den Anmeldebildschirm schicken, und du siehst die neue Liste,
bevor du zustimmst.

## Konto

Deine anderen Konten, eine Webadresse pro Zeile. Ein Konto hier zu benennen ist
die Voraussetzung dafür, später dorthin umzuziehen, und es zählt nur, wenn
dieses Konto seinerseits dieses hier benennt.

Der Umzug zu einem anderen Konto steht ebenfalls auf dieser Seite und ist
[weiter unten](#zu-einem-anderen-konto-umziehen) beschrieben. Deine Daten
exportieren und das Konto löschen gibt es noch nicht.

## Einladungen

Nur, wenn die Betreiberin dieses Servers deinem Konto die Berechtigung gegeben
hat. Ein Code, mit dem sich jemand anmelden kann, auch wenn Anmeldungen sonst
geschlossen sind, mit einer optionalen Obergrenze für die Anzahl der Leute und
einem optionalen Ablaufdatum. Das Häkchen „folgt dir“ heißt, dass wer damit
ankommt, dir von Anfang an folgt – meist ist das der Sinn der Sache: Ihr kennt
euch ja.

Codes lassen Zeichen weg, die einander ähnlich sehen, damit man einen über den
Tisch vorlesen kann, ohne ihn buchstabieren zu müssen.

Verschick den kurzen Link, `https://dieser-server/invite/CODE`. Er öffnet das
Anmeldeformular mit bereits eingetragenem Code, und wer so ankommt, wird nicht
gefragt, warum er beitreten möchte – das hast du ja schon beantwortet. Ein Code,
der abgelaufen ist, aufgebraucht wurde oder sich vertippt hat, landet trotzdem
auf dem Formular und sagt, welcher der drei Fälle es war. Für die Person mit dem
Link sind das drei verschiedene Dinge, und sie sollte dich nicht fragen müssen,
welches davon passiert ist.

## Importieren

Jeder Fediverse-Server gibt dir ein ZIP mit allem, was du geschrieben hast, und
bis jetzt konnte kein Server so eines wieder einlesen. **Einstellungen →
Importieren** nimmt eines an: Deine Beiträge kommen mit ihren Bildern und ihren
ursprünglichen Daten zurück, dein Profil liest sich also in der Reihenfolge, in
der du geschrieben hast, und nicht als Wand von Beiträgen mit dem heutigen
Datum.

Manches kann nicht mitkommen, und das weiß man besser vorher als eine Woche
später:

- **Die alten Adressen.** Deine Beiträge lagen auf einer anderen Domain und
  können dort nicht wieder liegen. Jeder Link, den jemals jemand auf einen davon
  geteilt hat, bleibt kaputt; die Kopien hier haben neue Adressen.
- **Deine Follower.** Eine Folge-Beziehung ist eine Abmachung zwischen zwei
  Servern, und einer davon ist weg. Wer dem alten Konto folgte, muss diesem
  folgen.
- **Geteilte Beiträge und Umfragen.** Ein geteilter Beitrag zeigt auf einen
  fremden, den das Archiv nicht enthält. Die Stimmen einer Umfrage wurden
  woanders gezählt und könnten hier nicht stimmen.

Importierte Beiträge bleiben aus allen Startseiten und aus dem Netz heraus. Sie
sind Jahre alt, und niemandes Follower haben darum gebeten, ein Jahrzehnt
fremder Geschichte am Stück vorgesetzt zu bekommen.

Favoriten und Lesezeichen werden über die Adresse nachgeschlagen, sie kommen
also zurück, wenn es den Beitrag noch irgendwo gibt. Was nicht gefunden wird,
wird aufgelistet statt stillschweigend verworfen.

Ein Archiv zu lesen dauert Minuten statt Sekunden, es läuft deshalb im
Hintergrund: Den Tab zu schließen hält es nicht an, und wer auf die Seite
zurückkommt, sieht, wie weit es ist und was nicht übernommen werden konnte.

### Listen

Dieselbe Seite nimmt die CSV-Dateien, die dein alter Server ausgibt:
Folge-Beziehungen, Blockierungen, Stummschaltungen, Domain-Blockierungen,
Listen, Lesezeichen und Filter. Lade sie einzeln hoch, unter den Namen, mit
denen sie gekommen sind – erkannt wird eine Datei zuerst an ihrem Inhalt und
danach an ihrem Namen, und was beides nicht hergibt, wird abgelehnt statt
geraten: Eine Blockierliste als Folge-Liste zu lesen würde dich denen folgen
lassen, vor denen du dich versteckt hast.

**Ergänzen** lässt stehen, was du hast, und fügt hinzu, was in der Datei steht.
**Durch die Datei ersetzen** bringt deinen Bestand mit der Datei in Deckung, was
man nach dem Bearbeiten eines Exports will. Lesezeichen und Filter werden dabei
nie geleert: Eine über Jahre gewachsene Leseliste räumt man nicht beiläufig ab,
weil man eine Datei mit zwölf Einträgen anwendet.

Jede Zeile ist ein eigener Versuch. Eine Folge-Liste von einem Server, der
zugemacht hat, nennt Konten auf hundert anderen, und manche davon wird es nicht
mehr geben; die werden namentlich aufgelistet und der Rest läuft weiter.

## Zu einem anderen Konto umziehen

**Einstellungen → Konto** zieht dieses Konto zu einem anderen um und sagt es
jedem Server, der dir folgt.

Zwei Dinge müssen vorher stimmen. Das andere Konto muss dieses in seinen eigenen
Aliassen nennen – das ist die Hälfte, die nur du erledigen kannst, und ohne sie
könnte jeder jedes beliebige Konto als Ziel angeben und bekäme eine Followerliste
ausgehändigt. Und du darfst in den letzten 30 Tagen nicht schon umgezogen sein,
denn wiederholtes Umziehen ist die Art, wie eine Followerliste schneller durchs
Netz gereicht wird, als irgendwer es bemerken kann.

Deine Follower auf diesem Server werden hier umgehängt. Jeder andere Server
bekommt die Mitteilung und entscheidet selbst, was das Einzige ist, was dieser
Server mit Followern tun kann, die er nicht hält.

Wenn du zurückkommst, räumt **Ich bin zurück** den Zeiger weg, damit die Server
aufhören weiterzuleiten. Die 30 Tage setzt das nicht zurück.

### Nach einem Umzug

Wenn du deine Follower von Hand bestätigst, kommen alle bisherigen auf einmal
an, weil jeder ihrer Server im selben Moment handelt. **Alle annehmen**
beantwortet den ganzen Schwung, und zwar mit derselben Antwort, die du ihnen
schon einmal gegeben hast.

## Moderation

Was die Moderation hier über dein Konto entschieden hat, älteste Entscheidung
zuletzt. Jeder Eintrag sagt, was getan wurde, wann, und was die moderierende
Person dir dazu geschrieben hat. Es ist derselbe Text, den sie gesehen hat, und
keine Zusammenfassung davon.

Wenn du eine Entscheidung für falsch hältst, kannst du einmal Einspruch
einlegen, innerhalb von 20 Tagen. Schreib in das Feld, warum, und die Moderation
sieht es in ihrer Warteschlange. Wie es ausgeht, erfährst du, und die Seite sagt
es dann, statt das Formular erneut anzubieten.

Ein Einspruch pro Entscheidung, nicht einer pro Versuch. So lange Einspruch
einzulegen, bis zufällig jemand anderes liest, ist eine Lotterie und kein
Einspruch.

Eine später aufgehobene Entscheidung bleibt als aufgehoben auf der Seite stehen.
Sie zu tilgen würde deinen eigenen Einspruch ins Leere zeigen lassen.

Dieselbe Seite listet, was die Entscheidungen dieses Servers über **andere
Server** dich gekostet haben. Wenn er die Föderation mit einem beendet, werden
die Folge-Beziehungen zwischen dir und den Leuten dort in beide Richtungen
gelöscht. Das lässt sich von hier aus nicht rückgängig machen: Die andere Seite
ist nicht mehr erreichbar, um zu fragen, und eine Folge-Beziehung steht dort
genauso in den Büchern wie hier. Was du weiterhin siehst, ist, welcher Server es
war, wie viele Beziehungen es gekostet hat, und wann.

## Exportieren

Zwei verschiedene Dinge auf derselben Seite.

**Listen** gibt es als je eine CSV-Datei: Folge ich, Blockierte,
Stummgeschaltete, Listen, blockierte Server, Lesezeichen, Filter. Sie laden
sofort herunter und haben das Format, das der Import dieses Servers liest — ein
Export von hier ist also ein Import anderswo. Genau darum geht es.

**Eine Kopie von allem** ist dein Profil und jeder Beitrag als JSON, zusammen
mit den CSV-Dateien und deinen Favoriten und Lesezeichen als eigene Adressliste,
in einem ZIP. Diese beiden Listen liest ein *Archiv*-Import, hier wie anderswo;
die CSV-Datei mit demselben Namen liest der Einstellungs-Import eines anderen
Servers. Beides liegt in der Datei, denn es sind zwei verschiedene Aufgaben und
nicht dasselbe zweimal. Sie wird im Hintergrund gebaut, weil dafür dein ganzes
Konto durchlaufen wird, und du bekommst eine E-Mail, wenn sie fertig ist. Eine pro Woche, und die Datei wird nach zwei Tagen gelöscht: sie ist
dein ganzes Konto in einer einzigen Datei, und es gibt keinen guten Grund, dass
sie länger auf einer Festplatte liegt, als du zum Herunterladen brauchst.

Bilder und Videos sind **nicht** im ZIP. Es enthält ihre Adressen, die so lange
funktionieren, wie dieser Server läuft. Wenn dir das wichtig ist, sichere sie,
bevor du das Konto schließt, nicht danach.

## Konto schließen

Ganz unten auf der Exportseite, hinter deinem Passwort. Deine Beiträge, Bilder,
Folge-Beziehungen, Listen, Filter, Lesezeichen, Sitzungen und Apps werden
gelöscht — die Bilder als Dateien auf der Platte, nicht nur als Datensätze —,
und jeder Server, der von dir gehört hat, wird aufgefordert, seine Kopie zu
löschen. Das lässt sich nicht rückgängig machen.

Das Konto verschwindet in dem Moment, in dem du bestätigst: nichts davon ist
mehr sichtbar, und niemand kann sich damit anmelden. Die Datensätze selbst
werden kurz danach gelöscht, und diese Lücke ist Absicht — die Nachricht an die
anderen Server wird mit einem Schlüssel signiert, der am Konto hängt, also muss
das Konto seine eigene Ankündigung lange genug überleben, um sie zu verschicken.

Dein **Benutzername bleibt und niemand kann ihn je bekommen**. Das ist kein
Versehen: jede alte Erwähnung, jeder Link und jeder Screenshot deines Namens
würde sonst auf die Person zeigen, die ihn als Nächstes registriert, und das ist
Identitätsmissbrauch, den niemand beabsichtigen musste.

Hol dir vorher deine Kopie. Danach gibt es nichts mehr zu exportieren, und ein
Archiv, das du schon gebaut hattest, wird mit dem Konto gelöscht statt seine
zwei Tage abzuwarten.

### Deine Bilder

Ein Profilbild und ein Titelbild, beide auf der Profilseite. JPEG, PNG, GIF oder
WebP, bis 8 MB — das steht dort, bevor du eine Datei auswählst, und nicht erst
nach einem gescheiterten Upload.

Was du schickst, wird hier einmal auf die Größe verkleinert, die die größte
Stelle braucht, an der es auftaucht. Niemand, der deine Beiträge liest, sollte
ein Foto mit viertausend Pixeln laden, um es bei vierzig zu sehen.

**Entfernen** nimmt eines wieder weg. Darunter liegt kein Standardbild: ein
Profil ohne Bild zeigt kein Bild, statt einer grauen Silhouette, die man erst
als „keins" deuten muss.
