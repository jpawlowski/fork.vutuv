# Kontakte aufs Telefon holen (CardDAV)

Ein Business-Netzwerk ist auch ein Adressbuch. Die Leute, denen Sie hier folgen,
können in der Kontakte-App auf Ihrem Telefon stehen — mit Foto, Telefonnummer
und Adresse, und sie bleiben aktuell, ohne dass Sie etwas tun.

Dafür gibt es CardDAV, ein Standard, den iPhone, iPad, Mac und Android sprechen.
Sie richten das einmal ein, danach läuft es.

Das ist ausgeschaltet, bis Sie es einschalten.

## Einschalten

Öffnen Sie **Einstellungen → Adressbuch (CardDAV)** und wählen Sie, wessen
Karten auf Ihre Geräte sollen:

* **Alle, denen ich folge**
* **Leute, denen ich folge und die mir folgen** — was vutuv *vernetzt* nennt
* **Nur Leute, die ich als persönlich bekannt markiert habe**

Neben jeder Stufe steht, wie viele Kontakte sie umfasst. Als persönlich bekannt
markieren Sie jemanden im ⋯-Menü auf dessen Profil; dort schreiben Sie auch eine
private Notiz zu dieser Person, die nur Sie sehen und die als Notiz mit auf Ihr
Telefon wandert.

## Ein Zugriffs-Token statt Ihres Passworts

Ihr Telefon speichert das Passwort dauerhaft — so funktioniert CardDAV. Deshalb
geben Sie ihm **nicht Ihr vutuv-Passwort**, sondern ein Token, das nur dieses
eine darf und das Sie einzeln widerrufen können.

Unter **Einstellungen → Apps & API-Zugang → Zugriffs-Tokens → Erstellen** legen
Sie eins an. Wichtig dabei:

* Bei den Berechtigungen **Kontakte** ankreuzen. Mehr braucht es nicht.
* Dem Token den **Namen des Geräts** geben — „iPhone", „iPad im Büro". Die Liste
  zeigt Ihnen später, welches Gerät zuletzt wann abgeglichen hat, und Sie können
  genau dieses widerrufen.
* Als Gültigkeit **ein Jahr** wählen. Läuft es ab, fragt das Gerät nach einem
  neuen Passwort, statt weiter abzugleichen.

Das Token wird Ihnen **einmal** angezeigt. Kopieren Sie es, bevor Sie die Seite
verlassen.

## Auf dem iPhone oder iPad

Öffnen Sie **Einstellungen → Apps → Kontakte** und tippen Sie auf
*Account hinzufügen*.

![Die Kontakte-Einstellungen mit „Account hinzufügen"](/images/help/carddav/01-kontakte.avif)

iOS fragt zuerst nach einer E-Mail-Adresse. Die brauchen wir nicht — tippen Sie
unten auf **„wähle einen Anbieter aus der Liste aus"**.

![Der Hinweis auf die Anbieterliste](/images/help/carddav/02-anbieter-liste.avif)

Ganz unten in der Liste steht **CardDAV-Account**.

![Die Anbieterliste mit dem Eintrag CardDAV-Account](/images/help/carddav/03-carddav-account.avif)

Jetzt drei Felder:

![Das ausgefüllte Formular](/images/help/carddav/04-zugangsdaten.avif)

* **Server:** `{{host}}`
* **Benutzername:** Ihr Benutzername hier
* **Passwort:** das Zugriffs-Token von oben

Mehr nicht — kein `https://`, keinen Pfad, keinen Port, und unter *Erweiterte
Einstellungen* müssen Sie nichts anfassen. Tippen Sie auf **Fertig**.

Ein paar Sekunden später stehen die Kontakte in der Kontakte-App. Sie erscheinen
dort als eigene Gruppe, getrennt von Ihren privaten Kontakten.

## Auf dem Mac

**Kontakte → Einstellungen → Accounts → +** → *Anderer Kontakte-Account…* →
**CardDAV**, Accounttyp **Manuell**. Dieselben drei Angaben wie oben, bei
Serveradresse genügt `{{host}}`.

## Auf Android

Android bringt von Haus aus keinen CardDAV-Client mit. Am weitesten verbreitet
ist **DAVx⁵** — quelloffen, im F-Droid-Store kostenlos, im Play Store gegen
einen kleinen Betrag.

Nach der Installation: **+ → Anmelden mit URL und Benutzername**, dann
`https://{{host}}` als Basis-URL, Ihren Benutzernamen und das Token als
Passwort. DAVx⁵ findet das Adressbuch selbst, danach schalten Sie die
Synchronisation für Kontakte ein.

DAVx⁵ kann außerdem etwas, das Apple nicht kann: Es lässt sich von uns
benachrichtigen, sobald sich etwas ändert, statt in Abständen nachzufragen. Auf
einem iPhone bleibt es beim regelmäßigen Nachfragen — das ist Apples Entscheidung
und nichts, was wir ändern können.

## Was auf dem Telefon landet — und was nicht

Übertragen wird genau das, was das Profil ohnehin jedem Besucher zeigt: Name,
Foto, Berufsbezeichnung, öffentliche Telefonnummern, öffentliche Adressen,
öffentliche E-Mail-Adressen. **Keine privaten Angaben.**

Dazu Ihre eigene Notiz zu dieser Person, falls Sie eine geschrieben haben. Die
sieht niemand außer Ihnen.

Das Adressbuch ist **schreibgeschützt**. Sie können einen Kontakt auf dem Telefon
nicht bearbeiten — die Angaben gehören dem Mitglied, und es ändert sie hier. Ihr
Telefon zeigt den Account deshalb als „nur lesen" an.

## Wenn jemand herausfällt

Wenn Sie jemandem nicht mehr folgen, die Markierung entfernen, die Person
blockieren oder sie vutuv verlässt, wird deren Karte zurückgezogen: Ihr Gerät
bekommt beim nächsten Abgleich die Anweisung, sie zu löschen, und tut das auch —
meist innerhalb von Minuten.

Dasselbe gilt, wenn jemand entscheidet, nicht mehr in fremden Adressbüchern zu
stehen.

## Ihre eigene Karte

Die andere Richtung entscheiden Sie unter **Einstellungen → Sichtbarkeit**: ob
andere Ihre Karte in ihr Adressbuch holen dürfen — alle, die Ihnen folgen, nur
die, denen Sie zurückfolgen, oder niemand. Voreingestellt ist die weiteste
Stufe, denn übertragen wird nur, was Ihr Profil ohnehin öffentlich zeigt.

Das können Sie jederzeit zurücknehmen, und es wirkt: Ihre Karte verlässt die
Adressbücher beim nächsten Abgleich.

Auf derselben Seite entscheiden Sie über den **vCard-Download** auf Ihrem Profil.
Der ist etwas anderes: eine Datei, einmal gespeichert, die nie wieder aktuell
wird — und die Sie nicht zurückholen können.

## Wenn es nicht klappt

**„Account-Verifizierung fehlgeschlagen"** — meist stimmt das Passwort nicht.
Sie brauchen das Zugriffs-Token, nicht Ihr vutuv-Passwort, und das Token braucht
die Berechtigung *Kontakte*.

**Das Adressbuch bleibt leer** — steht Ihre Stufe unter *Adressbuch (CardDAV)*
noch auf „Aus"? Und folgen Sie überhaupt jemandem, der in die gewählte Stufe
fällt? Die Zahl neben jeder Stufe sagt es Ihnen.

**Es hat funktioniert und hört plötzlich auf** — vermutlich ist das Token
abgelaufen. Legen Sie ein neues an und tragen Sie es im Gerät ein.

**Jemand fehlt** — vielleicht hat diese Person entschieden, nicht in fremden
Adressbüchern zu stehen. Das ist ihre Entscheidung, und wir respektieren sie.
