# computercraft-scripts

ComputerCraft (CC: Tweaked) turtle scripts.

- `hub.lua` + `miner.lua`: **Mine Army**. Een hub met dashboard in je basis, en een vloot mining turtles die via hun eigen schacht naar het erts-niveau gaan, daar zijgangen graven en weer terugkomen.
- `smartmine.lua`: de oude losse tunnel-miner (zonder hub). Werkt nog steeds.

## Mine Army

### Wat het doet
- Elke turtle graaft **één keer** een 1x1 schacht recht onder zijn startplek. Daarna gebruikt hij die schacht elke trip opnieuw. Iron ligt boven diamond, dus dezelfde schacht werkt voor elk niveau.
- Op het erts-niveau graaft hij een hoofdgang. Om de 4 blokken komt er een zijgang (3 blokken steen ertussen), 3 hoog en 1 breed, standaard 32 lang.
- Bij elke stap kijkt hij links en rechts in de wand. Ertsen volgt hij als ader. Voor het doel-erts (bv. diamond) checkt hij 18 van de 26 buren.
- Lava wordt afgedicht met het eerste neerzetbare non-ore blok. Hij stapt nooit in lava. Kolen gebruikt hij nooit om af te dichten.
- Troep (cobble, deepslate, tuff, grind, enz.) gooit hij om de ~10 blokken weg. Eén stapel houdt hij als seal-blok. Alle ertsen, ook modded, houdt hij.
- Gaat naar huis als de inventory vol is, de fuel op de terugweg nodig is, of de hub hem terugroept. Daar lost hij in de kist, tankt kolen uit dezelfde kist en gaat weer.
- Onthoudt positie en voortgang in een bestand. Na een reboot of chunk-unload gaat hij eerst veilig naar huis en gaat dan verder waar hij was.
- Het gat boven de schacht dekt hij af met een blok zodra hij weg is, zodat niemand erin valt.

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
- Per turtle: mining turtle (pickaxe) + **ender modem** (een gewone wireless modem haalt diep onder de grond de hub niet. Dan werkt alles nog, maar ziet de hub hem alleen als hij thuis is).
- Per turtle: een kist direct **achter** de turtle, met kolen erin.
- Basis-computer (advanced voor kleur/klikken) + ender modem. Monitor optioneel (advanced monitor = aanraakknoppen).

### Installeren
Op elke turtle en op de hub-computer (`http` moet aan staan op de server):
```
wget https://raw.githubusercontent.com/140er/computercraft-scripts/refs/heads/claude/mine-lua-turtle-9o3j9v/install.lua install
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

Zonder hub: `miner diamond` (of `iron`, `gold`, ...) laat één turtle zelfstandig werken.

### Goed om te weten
- Turtles werken alleen in geladen chunks. Gaat de chunk uit, dan stopt de turtle. Komt de chunk terug, dan start hij opnieuw, gaat naar huis en werkt verder.
- Hoe meer zijgangen er al zijn, hoe langer de hoofdgang en de reis. De lengte van de zijgangen staat in `hub.state` (`branchLen`).
- Instellingen bovenin `miner.lua`: `BRANCH_LEN`, `JUNK_EVERY`, `MAX_VEIN`, `FUEL_MARGIN`.
