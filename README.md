# computercraft-scripts

ComputerCraft (CC: Tweaked) turtle scripts.

- `hub.lua` + `miner.lua`: **Mine Army**. Een hub met dashboard in je basis, en een vloot mining turtles die via hun eigen schacht naar het erts-niveau gaan, daar zijgangen graven en weer terugkomen.
- `smartmine.lua`: de oude losse tunnel-miner (zonder hub). Werkt nog steeds.

## Mine Army

### Wat het doet
- Elke turtle rijdt 1 blok vooruit (naar het gat dat je daar gemaakt hebt) en gaat daar omlaag. Hij maakt die 1x1 schacht **één keer** af tot het erts-niveau. Daarna gebruikt hij die schacht elke trip opnieuw. Iron ligt boven diamond, dus dezelfde schacht werkt voor elk niveau.
- Op het erts-niveau graaft hij een hoofdgang. Om de 4 blokken komt er een zijgang (3 blokken steen ertussen), standaard 64 lang.
- De gangen zijn 1x1. Hij kijkt wel naar het blok erboven en eronder, dus hij vindt evenveel erts als in een 3 hoge gang, maar sneller. In 1 hoge gangen kunnen ook geen mobs spawnen.
- Grotten: komt een wand, plafond of vloer uit in een grot (lucht of water), dan zet hij dat gat dicht met cobble. Loopt een zijgang een grot in, dan sluit hij de gang af en begint aan de volgende. De hoofdgang gaat er recht doorheen en metselt zichzelf onderweg dicht. Zo blijven de gangen vrij van mobs, water en lava.
- Bij elke stap kijkt hij links en rechts in de wand. Ertsen volgt hij als ader. Voor het doel-erts (bv. diamond) checkt hij 18 van de 26 buren.
- Lava wordt afgedicht met het eerste neerzetbare non-ore blok. Hij stapt nooit in lava. Kolen gebruikt hij nooit om af te dichten.
- Troep (cobble, deepslate, tuff, grind, enz.) gooit hij om de ~10 blokken weg. Eén stapel houdt hij als seal-blok. Alle ertsen, ook modded, houdt hij.
- Gaat naar huis als de inventory vol is, de fuel op de terugweg nodig is, of de hub hem terugroept. Daar lost hij in de kist, tankt kolen uit dezelfde kist en gaat weer.
- Onthoudt positie en voortgang in een bestand. Na een reboot of chunk-unload gaat hij eerst veilig naar huis en gaat dan verder waar hij was.
- Het gat dekt hij op vloerhoogte af met een blok zodra hij erin zit, zodat niemand erin valt. Op de terugweg graaft hij het weer open, rijdt omhoog en 1 blok terug naar zijn startplek (kist achter hem).

| Knop | Niveau (Y) |
|---|---|
| Diamond / Redstone | -58 |
| Gold | -16 |
| Lapis | 0 |
| Iron | 16 |
| Copper / Coal | 48 |

### Regio's (geen botsingen)
Elke turtle heeft een "rol" = de richting van zijn hoofdgang. De zijgangen gaan steeds een kwartslag met de klok mee:

| Rol | Hoofdgang | Zijgangen |
|---|---|---|
| east  | oost  | zuid |
| south | zuid  | west |
| west  | west  | noord |
| north | noord | oost |

Zo krijgt elke turtle zijn eigen kwadrant, en geen gang kruist een schacht van een andere turtle.

### Benodigd
- Per turtle: mining turtle (pickaxe) + wireless modem (gewoon of ender).
- Per turtle: een kist direct **achter** de turtle. Brandstof: kolen of lava-emmers (in de kist of in de turtle zelf).

### Brandstof: lava-emmers
- Een volle lava-emmer = 1000 fuel. De turtle verbrandt volle emmers uit zijn eigen inventory en uit de kist.
- Lege emmers houdt hij. Komt hij onderweg een lava-bron tegen, dan schept hij die op met een lege emmer, verbrandt hem meteen (+1000 fuel) en dicht het gat daarna af met een blok. Op Y -58 zit veel lava, dus een turtle met een emmer tankt zichzelf.
- 2 volle emmers per turtle is genoeg om te beginnen. Werk je alleen met kolen, geef hem dan toch 1 lege emmer.
- Stromende lava kan niet in een emmer, die wordt alleen afgedicht.
- Basis-computer (advanced voor kleur/klikken) + wireless modem. Monitor optioneel (advanced monitor = aanraakknoppen).

### Gewone wireless modems
Een gewone wireless modem reikt ongeveer 64 blokken. Diep onder de grond hoort de hub de turtles dus niet. Dat is geen probleem:
- Opdrachten haalt een turtle op als hij thuis is, en daar lost hij ook zijn buit. Dat werkt altijd, zolang de hub binnen ~64 blokken van de turtles staat (naast ze is prima).
- Op het dashboard staat een turtle die onderweg is in oranje als "Onder de grond". Rood "GEEN SIGNAAL" betekent dat hij thuis zou moeten zijn maar niets laat horen.
- Een turtle graaft maximaal `mineMinutes` (standaard 15) minuten per trip en komt dan terug, ook als hij nog niet vol is. Zo wordt een nieuwe erts-keuze binnen een kwartier opgepikt. Aan te passen in `hub.state`.
- `TERUG NU` bereikt alleen turtles binnen bereik. De hub blijft de oproep herhalen, maar een turtle diep beneden komt pas terug na zijn trip-tijd. `STOP` werkt altijd: thuis blijft hij staan.
- Met ender modems werkt alles live, zonder deze beperkingen.

### Installeren
Op elke turtle en op de hub-computer (`http` moet aan staan op de server):
```
wget https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/main/install.lua install
install
```
Of kopieer `miner.lua` / `hub.lua` handmatig (pastebin, diskette).

### Instellen: jouw 4 turtles
Ze staan op y=65, z=-743, met de kist aan de noordkant (z=-744), dus ze kijken **south**. Controleer dat even. Bij `setup` waarschuwt de turtle als hij geen kist achter zich ziet.
```
-- turtle op x=-216 (oostelijkste)
miner setup -216 65 -743 south east
-- turtle op x=-218
miner setup -218 65 -743 south south
-- turtle op x=-220
miner setup -220 65 -743 south north
-- turtle op x=-222 (westelijkste)
miner setup -222 65 -743 south west
```
Setup zet ook een `startup.lua` neer en geeft de turtle een label (`Miner-east`, ...). Daardoor start hij na een reboot vanzelf en houdt hij zijn bestanden als je hem oppakt.

Hub-computer:
```
hub install
hub
```
Herstart daarna de turtles (of typ `miner`).

### Bediening (dashboard)
- Tik op een erts (Diamond, Iron, ...). Alle turtles gaan daarvoor graven. Een nieuwe keuze geldt vanaf de volgende trip.
- Tik eerst op een turtle in de lijst en dan op een erts: alleen die turtle krijgt dat erts. `ALLE` gaat terug naar de hele vloot.
- `STOP`: na de huidige trip thuis blijven.
- `TERUG NU`: meteen naar huis (als hij binnen bereik is). `HERVAT` laat ze weer gaan.
- Toetsenbord: `1`-`7` erts, `s` stop, `r` terug, `h` hervat, `a` alle, `q` afsluiten.
- Onderaan staat het totaal dat in de kisten is gelost.

### Turtles updaten via de hub
Sleep de nieuwe `miner.lua` naar het scherm van de **hub-computer**. Elke turtle die thuiskomt ziet dat de hub een andere versie heeft, haalt hem op, controleert of het geldige Lua is en herstart.
- Dit gebeurt alleen thuis, na het lossen. Positie, richting en voortgang staan in `miner.state` en `miner.cfg`, die blijven gewoon staan. Na de herstart gaat hij verder bij dezelfde zijgang.
- Turtles die nog niet bijgewerkt zijn staan op het dashboard met een `*` achter hun naam.
- Een kapot bestand wordt geweigerd. De turtle houdt dan zijn oude versie.
- Wil je de hub zelf bijwerken: sleep ook `hub.lua` erheen en herstart de hub-computer.
- Let op: iedereen op de server met een computer en modem zou zich als "hub" kunnen voordoen. Op een server met vreemden is dat een risico.

Zonder hub: `miner diamond` (of `iron`, `gold`, ...) laat één turtle zelfstandig werken.

### Goed om te weten
- Turtles werken alleen in geladen chunks. Gaat de chunk uit, dan stopt de turtle. Komt de chunk terug, dan start hij opnieuw, gaat naar huis en werkt verder.
- Hoe meer zijgangen er al zijn, hoe langer de hoofdgang en de reis. De lengte van de zijgangen staat in `hub.state` (`branchLen`).
- Instellingen bovenin `miner.lua`: `BRANCH_LEN`, `JUNK_EVERY`, `MAX_VEIN`, `FUEL_MARGIN`.
