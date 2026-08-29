# Portare i contatti sul telefono (CardDAV)

Una rete professionale è anche una rubrica. Le persone che segue qui possono
stare nell'app Contatti del suo telefono — con foto, numero di telefono e
indirizzo — e restare aggiornate senza che lei debba fare nulla.

A questo serve CardDAV, uno standard che iPhone, iPad, Mac e Android parlano
tutti. Lo configura una volta, poi funziona da sé.

È disattivato finché non lo attiva.

## Attivarlo

Apra **Impostazioni → Rubrica (CardDAV)** e scelga di chi vuole le schede sui
suoi dispositivi:

* **Tutti quelli che seguo**
* **Le persone che seguo e che seguono me** — quello che vutuv chiama *collegati*
* **Solo le persone che ho contrassegnato come conosciute di persona**

Accanto a ogni livello c'è quanti contatti comprende. Contrassegna qualcuno come
conosciuto di persona dal menu ⋯ sul suo profilo, dove scrive anche una nota
privata su quella persona — la vede solo lei, e arriva sul telefono come nota
del contatto.

## Un token di accesso invece della password

Il telefono conserva la password per sempre — CardDAV funziona così. Quindi
**non** gli dia la sua password di vutuv, ma un token che può fare solo questo e
che può revocare da solo.

Ne crei uno in **Impostazioni → App e accesso API → Token di accesso → Crea**.
Tre cose contano:

* Spunti l'autorizzazione **contatti**. Non serve altro.
* Dia al token il **nome del dispositivo** — «iPhone», «iPad in ufficio».
  L'elenco le mostrerà quale dispositivo si è sincronizzato per ultimo e quando,
  e potrà revocare esattamente quello.
* Gli dia **un anno**. Quando un token scade, il dispositivo chiede una nuova
  password invece di sincronizzare.

Il token le viene mostrato **una volta sola**. Lo copi prima di lasciare la
pagina.

## Su iPhone o iPad

Apra **Impostazioni → App → Contatti** e tocchi *Aggiungi account*.

![Le impostazioni Contatti con «Aggiungi account»](/images/help/carddav/01-kontakte.avif)

iOS chiede prima un indirizzo email. Non ci serve — tocchi in basso
**«scegli un provider dall'elenco»**.

![L'indicazione verso l'elenco dei provider](/images/help/carddav/02-anbieter-liste.avif)

In fondo all'elenco c'è **Account CardDAV**.

![L'elenco dei provider con la voce Account CardDAV](/images/help/carddav/03-carddav-account.avif)

Ora tre campi:

![Il modulo compilato](/images/help/carddav/04-zugangsdaten.avif)

* **Server:** `{{host}}`
* **Nome utente:** il suo nome utente qui
* **Password:** il token di accesso di prima

Nient'altro — nessun `https://`, nessun percorso, nessuna porta, e sotto
*Impostazioni avanzate* non c'è niente da toccare. Tocchi **Fine**.

Qualche secondo dopo i contatti sono nell'app Contatti, come gruppo a sé,
separati da quelli privati.

*(Le immagini mostrano l'interfaccia tedesca; le schermate sono le stesse.)*

## Su Mac

**Contatti → Impostazioni → Account → +** → *Altro account Contatti…* →
**CardDAV**, tipo di account **Manuale**. Gli stessi tre dati di sopra; come
indirizzo del server basta `{{host}}`.

## Su Android

Android non porta con sé alcun client CardDAV. Il più diffuso è **DAVx⁵** — open
source, gratuito su F-Droid, a piccolo prezzo sul Play Store.

Dopo l'installazione: **+ → Accedi con URL e nome utente**, poi
`https://{{host}}` come URL di base, il suo nome utente e il token come
password. DAVx⁵ trova la rubrica da solo; poi attivi la sincronizzazione dei
contatti.

DAVx⁵ sa fare anche una cosa che il client di Apple non sa: si lascia avvisare
da noi nel momento in cui qualcosa cambia, invece di chiedere a intervalli. Un
iPhone continua a chiedere secondo il proprio calendario — è una decisione di
Apple e non possiamo cambiarla.

## Cosa arriva sul telefono, e cosa no

Viene trasmesso esattamente ciò che il profilo mostra già a ogni visitatore:
nome, foto, qualifica, numeri di telefono pubblici, indirizzi pubblici, indirizzi
email pubblici. **Nessun dato privato.**

Più la sua nota su quella persona, se ne ha scritta una. Non la vede nessun
altro.

La rubrica è **di sola lettura**. Non può modificare un contatto dal telefono —
i dati appartengono al membro, che li cambia qui. Per questo il telefono mostra
l'account come di sola lettura.

## Quando qualcuno esce

Se smette di seguire qualcuno, ne rimuove il contrassegno, lo blocca o quella
persona lascia vutuv, la sua scheda viene ritirata: alla sincronizzazione
successiva il dispositivo riceve l'istruzione di eliminarla, e lo fa — di solito
entro pochi minuti.

Lo stesso accade quando qualcuno decide di non stare più nelle rubriche altrui.

## La sua scheda

L'altra direzione la decide in **Impostazioni → Visibilità**: se altri possono
tenere la sua scheda — tutti quelli che la seguono, solo le persone che segue a
sua volta, o nessuno. Il livello più ampio è quello predefinito, perché viene
trasmesso solo ciò che il suo profilo mostra già pubblicamente.

Può revocarlo in qualsiasi momento, e funziona: la sua scheda lascia quelle
rubriche alla sincronizzazione successiva.

Nella stessa pagina decide sul **download vCard** dal suo profilo. Quello è
un'altra cosa: un file, salvato una volta, che non si aggiorna mai più — e che
non può riprendersi.

## Se non funziona

**«Verifica dell'account non riuscita»** — di solito è la password. Le serve il
token di accesso, non la sua password di vutuv, e il token deve avere
l'autorizzazione *contatti*.

**La rubrica resta vuota** — il suo livello in *Rubrica (CardDAV)* è ancora su
«Disattivato»? E segue davvero qualcuno che rientra nel livello scelto? Il numero
accanto a ogni livello glielo dice.

**Ha funzionato e poi si è fermato** — probabilmente il token è scaduto. Ne crei
uno nuovo e lo inserisca nel dispositivo.

**Manca qualcuno** — può aver deciso di non stare nelle rubriche altrui. È una
sua scelta, e la rispettiamo.
