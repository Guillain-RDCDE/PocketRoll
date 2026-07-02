# Une pellicule infinie

### Apprendre à un Game Boy Camera de 1998 à photographier sans fin — sur un FPGA, sans PC sur le terrain.

*Voici l'histoire vraie de la naissance de PocketRoll : une descente de deux semaines à travers un
format de sauvegarde qui s'efface si vous trichez, une puce qui démarre sur un écran blanc pour des
raisons qui s'avèrent être la mauvaise version d'un compilateur, un bug qui a coûté trois jours et
qui s'est réglé en changeant un seul caractère, et une ROM que personne au monde n'avait jamais
désassemblée.*

> 🇬🇧 **This story exists in English too** → [STORY.md](STORY.md) · 🌐 **Version web illustrée (EN/FR)** → [le récit sur GitHub Pages](https://guillain-rdcde.github.io/PocketRoll/)

> **Comment lire ceci.** Le récit se suit d'une traite — vous pouvez tout lire sans jamais toucher
> une adresse hexa. Mais chaque fois que l'histoire croise quelque chose qui mérite un gros plan, il
> y a une **boîte 🔬 deep-dive** à déplier : les octets réels, le Verilog, le désassemblage, les
> offsets de registres. Sautez-les et vous avez un récit. Ouvrez-les et vous avez les schémas.

---

## Prologue — Trente photos

En 1998, le Game Boy Camera pouvait garder trente photos. Pas trente par session — trente, *en tout*,
pour toujours, jusqu'à ce que vous en effaciez pour faire de la place. La cartouche portait une petite
puce avec la place pour trente images et un programme qui comptait, poliment, jusqu'à trente, puis
refusait.

Je voulais l'infini.

Pas l'infini « on branche à un PC et on vide la pellicule » — celui-là existait déjà, et il fallait un
PC. Je voulais me tenir dans un champ avec pour seul équipement une Analogue Pocket, la cartouche
d'origine de 1998 et une carte SD, et photographier jusqu'à remplir la carte. Pas d'ordinateur. Pas de
câbles. Trente devient infini, et la caméra ne s'en aperçoit jamais.

Le problème, c'est que la caméra dit vrai. Il n'y a réellement que trente emplacements, et le
programme refuse réellement le trente-et-unième. Pour lui mentir de façon convaincante, il fallait
atteindre trois machines différentes empilées l'une dans l'autre :

- une **ROM** — le programme de la caméra — qui voit un capteur photo mais n'a aucune notion de fichier ;
- une **cartouche** qui porte physiquement le capteur et trente images ;
- et, sous les deux, une **puce programmable** qui fait semblant, porte logique par porte logique, d'être une Game Boy.

Cette troisième couche, personne ne l'attend, et c'est elle qui rend tout possible. L'Analogue Pocket
n'émule pas une Game Boy en logiciel — elle en *devient* une, en chargeant un « cœur » FPGA qui câble
une Game Boy à partir de logique brute. Et surtout, l'un de ces cœurs — le `openfpga-GBC` de budude2,
descendant du cœur Game Boy de MiSTer — peut faire tourner une **vraie cartouche branchée dans la
Pocket**, en laissant passer le bus vivant vers du vrai silicium de 1998.

Ce qui donnait au plan, aussi absurde qu'il sonnait, une forme : laisser la cartouche et son capteur
totalement intacts et physiques, et réécrire *la Game Boy en dessous* pour qu'elle remarque chaque
photo, la copie sur la SD, et recycle discrètement l'emplacement. Voici l'histoire de comment on
apprend à cette pile à mentir — et de chaque fois où elle a menti en retour.

<details>
<summary>🔬 La sauvegarde qui s'efface si vous trichez</summary>

Avant de toucher la moindre porte logique, il fallait comprendre ce qu'*est* une photo sur cette
cartouche. Les 128 Ko de RAM de sauvegarde forment un en-tête de 8 Ko suivi de trente emplacements de
4 Ko (`0x2000 + i*0x1000`). La caméra suit les emplacements utilisés avec un **vecteur sommaire de 30
octets à `0x11B2`** — un octet par emplacement, la valeur étant le numéro d'affichage de la photo,
`0xFF` voulant dire vide. Juste après vient la chaîne littérale `"Magic"` (`0x11D0`), un **checksum de
deux octets** (`0x11D5`/`0x11D6`), puis un **écho** de 37 octets de tout le bloc.

Voici le piège. Le checksum n'est pas un CRC. C'est une **somme initialisée à `0x2F`** et un **XOR
initialisé à `0x15`**, sur les octets du sommaire *seuls* — `"Magic"` est exclu. J'ai rétro-conçu ces
graines à la main et les ai confirmées contre la vérité terrain : j'ai effacé une photo sur la vraie
caméra et dumpé avant et après. Avant : deux photos, sommaire `00 01` ; après : une photo, sommaire
`00`, checksum `0x12 / 0xEA`. Ma formule donnait exactement `0x12 / 0xEA`.

Et voici la chute, le fait qui a dicté toute l'architecture : corrompez le checksum, ou perdez le
marqueur `"Magic"`, et la caméra ne se contente pas de rejeter la sauvegarde. **Au prochain démarrage,
elle efface toute la cartouche.** Code suicide. Impossible donc de libérer un emplacement en
réécrivant la sauvegarde depuis l'extérieur — l'écrasement doit venir de *l'intérieur* de la logique
de la ROM. Ce qui, plus tard, m'a forcé à désassembler une ROM que personne n'avait jamais
désassemblée. Mais je m'avance.

</details>

---

## I. La sauvegarde qui se défend

Le format de sauvegarde m'a pris une semaine à vraiment maîtriser, et l'essentiel de cette semaine
s'est passé à me tromper de façons instructives.

La documentation publique du save du Game Boy Camera — et il en existe, grâce à des gens comme Raphaël
Boichot et insideGadgets, des années sur ce matériel — se trompait subtilement sur le checksum, ou
décrivait une autre révision de ROM (Hello Kitty, ou le prototype « Debagame », qui range sa pellicule
tout autrement). Chaque fois que je bâtissais un outil sur la description d'un autre, il divergeait de
mes vrais dumps de quelques octets. J'ai donc cessé de faire confiance aux descriptions et me suis mis
à faire confiance à la cartouche : forger une sauvegarde, la charger, voir ce que la *caméra* en fait,
et laisser le désaccord m'instruire.

Cette boucle — forger, charger, observer, comparer — est devenue la méthode de tout le projet. Elle
est lente, elle est humble, et c'est la seule qui marche quand la documentation et le silicium se
contredisent et que l'un des deux ment.

À la fin de la semaine, j'avais une petite bibliothèque capable de lire la pellicule, vérifier les
deux checksums, et libérer un emplacement comme le ferait la caméra elle-même — recalculant le
checksum, recopiant l'écho, laissant les octets d'image intacts. Elle passait un auto-test contre la
vérité terrain à six octets près sur 131 072, et ces six octets se sont révélés être un horodatage
d'animation, pas de la pellicule. La recette de recyclage était juste.

Restait un seul problème, celui du prologue : je savais désormais *exactement* comment éditer la
sauvegarde, et je savais aussi que l'éditer depuis l'extérieur était un piège. La recette était à la
fois juste et inutile. Pour vraiment m'en servir, il fallait que quelque chose *à l'intérieur* du
système en marche l'applique — donc entrer dans le système en marche.

---

## II. Écran blanc

On n'« entre » pas à la légère dans une Analogue Pocket. Pas de système d'exploitation où se
connecter, pas de débogueur, pas de printf. Il y a un compilateur (le Quartus d'Intel, un mastodonte
de 20 gigaoctets), un fork d'un cœur Game Boy écrit en Verilog et VHDL, et une boucle de retour
d'environ une heure entre « j'ai changé une ligne » et « je découvre si la Pocket est d'accord ».

J'ai forké le cœur de budude2, compilé tel quel, empaqueté, copié sur la SD — et obtenu un écran noir.
Puis un *autre* écran noir. Puis un blanc.

<details>
<summary>🔬 Deux écrans noirs, deux causes sans rapport</summary>

Le premier écran noir était une erreur d'empaquetage et une leçon sur l'intransigeance d'openFPGA. Le
dossier d'un cœur sur la SD doit se nommer *exactement* `<auteur>.<nom-court>`. J'avais nommé le
dossier d'un côté et le nom-court de l'autre, et la Pocket a rejeté avec un générique « core setup
error ». Je l'ai isolé en glissant le bitstream *officiel* et en le voyant échouer à l'identique — ce
n'était donc pas mon build, c'était le nom.

Le second était plus subtil et a coûté du vrai temps. Mon build *se chargeait* et restait noir. Deux
choses fausses à la fois :

1. Le `core_top.sv` amont laisse `` `define isgbc 1 `` — il compile le cœur Game Bo**y Color**, qui
   réclame un `gbc_bios.bin`. Empaqueté en Game Boy simple, il ne démarre pas. Un caractère :
   `` `define isgbc 0 ``.
2. Même corrigé, il restait noir sauf compilé avec **Quartus Prime Lite 25.1** précisément. Les blocs
   IP et PLL committés ont été générés contre cette version ; avec 18.1 ou 24.1, ils compilent
   proprement mais synthétisent des *horloges subtilement fausses* — le FPGA tourne, ne produit aucune
   vidéo valide, et ne montre que du noir. Il n'y a pas d'erreur. Il n'y a que le noir.

L'empaquetage est son propre rituel : openFPGA veut le bitstream **inversé bit à bit** (les bits de
chaque octet retournés) et renommé `gb.rbf_r`. J'ai écrit un petit `reverse_rbf.js` pour ça, et il a
tourné à chaque build depuis.

</details>

L'écran blanc, quand il est enfin venu, était un progrès : blanc veut dire que le cœur est vivant et
exécute le démarrage de la caméra, il ne voit simplement pas de sauvegarde valide. Et ce fut l'instant
où tout a cessé d'être théorie. Le 19 juin, ma propre Game Boy sur mesure — compilée depuis les
sources sur ma machine, inversée bit à bit, copiée sur une SD — a démarré la vraie cartouche Game Boy
Camera et **a pris une photo.**

La pile tenait debout. Il fallait maintenant lui apprendre à mentir.

---

## III. Le bug qui a mangé trois jours

Voici la partie dont je suis le moins fier et dont j'ai le plus appris.

Le but était simple à énoncer : quand la caméra prend une photo, copier les 128 Ko de RAM de
sauvegarde sur la SD. Je savais que la Pocket pouvait écrire des fichiers. Je savais où vivaient les
photos. Ç'aurait dû être une après-midi.

Ce ne fut pas une après-midi. J'ai essayé de miroiter la RAM de la cartouche en mémoire interne :
garbage. J'ai essayé le bus-mastering — pauser la Game Boy et piloter le bus cartouche moi-même pour
lire les seize banques : garbage. J'ai essayé la sauvegarde native de sortie de la Pocket : *le même
garbage.* Techniques différentes, à des semaines d'écart, produisant toutes octet pour octet la même
sortie fausse. Quand toutes les routes mènent au même mauvais endroit, ce ne sont pas les routes qui
sont fausses. C'est qu'on lit au mauvais endroit.

L'outil qui a tout craqué était bête et parfait : un **fichier-témoin** rempli de `0xAA`. J'ai rempli
la sauvegarde de `0xAA`, chargé, pris une photo, dumpé. Si mon dump revenait plein de `0xAA`, ma
*capture* était cassée ; si autre chose, mon *chemin de lecture* l'était. Il est revenu à 98,6 % de
`0xFF`, pas du tout du `0xAA`. Le fichier que je lisais n'était même pas celui que j'avais écrit. Je
ne regardais pas mon dump. Je ne l'avais jamais regardé.

<details>
<summary>🔬 Un caractère : 0x2 → 0x3</summary>

Les slots de données de la Pocket ont un champ `address` — l'endroit où la Pocket lit quand elle
sauvegarde ce slot sur SD. Mon buffer de dump était exposé au bridge de la Pocket à `0x30000000`. Mais
le slot que j'avais configuré était marqué `nonvolatile`, et son `address` pointait toujours sur
`0x20000000` — la région du *save-handler*, la plomberie conçue pour la sauvegarde normale d'une
cartouche virtuelle.

Donc à chaque sortie et chaque mise en veille, la Pocket effectuait consciencieusement une
« sauvegarde native » : elle lisait `0x20000000` (du n'importe quoi en mode cartouche physique) et
**écrasait mon fichier de dump avec.** Je relisais toujours le garbage du save-handler — jamais mon
buffer soigneusement capturé. Chaque technique avait marché ; je n'avais simplement jamais regardé sa
sortie.

Le fix : pointer l'`address` du slot sur `0x30000000`. Un chiffre hexa. `0x2` → `0x3`. Trois jours. La
leçon m'est restée : quand *toutes* vos approches échouent *à l'identique*, cessez d'améliorer les
approches — vous lisez ou écrivez au mauvais endroit, et l'identité de l'échec est l'indice.

</details>

Ce chiffre corrigé, les dumps ont pris vie. Un **espion** passif — surveiller chaque octet que la
caméra elle-même lit sur la cartouche et le copier de côté — a produit une sauvegarde valide avec de
vraies photos : mon visage, mon bureau, un piano. Pour capter les seize banques (un buffer de 128 Ko
ne tient pas dans la block RAM du FPGA, saturée par la RAM cartouche du cœur), j'ai détourné les 128 Ko
de SRAM externe inutilisée de la Pocket comme buffer. Puis, parce que faire défiler chaque photo à la
main était pénible, j'ai ressuscité le bus-master que j'avais abandonné — et cette fois, ayant enfin
*vu* sa vraie sortie, je l'ai fait marcher en un bouton.

<details>
<summary>🔬 N'inventez pas d'horloge pour le bus d'un autre</summary>

Le bus-master lit la cartouche en pilotant lui-même les lignes d'adresse et de banque pendant que la
Game Boy est en pause. Ma première version échantillonnait la donnée à `cart_phi_fall` — le front
descendant de l'horloge PHI de la cartouche, l'endroit évident. Résultat : 94,8 % correct, de vraies
données photo, mais l'annuaire relu en `00` et le checksum faux. Une marge de timing ratée.

Le fix : cesser d'inventer un point d'échantillonnage et *emprunter celui qui marche déjà* : le cœur
Game Boy latche les lectures cartouche à son enable d'horloge CPU, `ce_cpu`. Échantillonner là — au
front exact qu'utilise la vraie gb — et l'annuaire est parfait, le checksum colle, l'écho colle. Un
bouton, seize banques, sauvegarde valide. (Cette leçon exacte revient une dernière fois, au dernier
chapitre — pour un bus que je ne *pilotais* même pas.)

</details>

Fin juin, le dump était solide — puis c'est devenu beau. L'intuition, quand elle est venue, avait
l'air d'un cadeau : *les save states écrivent déjà sur la SD en plein jeu et reprennent sans accroc.
Arrête de te battre contre la pause. Utilise ce qui pause déjà proprement.* Le save-state natif de la
Pocket fige la Game Boy à un point sûr, sérialise sa mémoire et reprend. J'ai fait deux changements
pour qu'il capture les *photos* (le capteur les écrit dans la cartouche hors du bus CPU, si bien que le
miroir natif ne les voit jamais), et soudain le dump tenait en un seul appui qui n'interrompait rien.
MugDump, mon décodeur compagnon, a appris à lire le fichier `.sta` directement. La moitié « terrain »
du rêve fonctionnait : photographier, save-state, continuer, décoder à la maison.

Tout marchait sauf la seule chose dont le projet portait le nom. La caméra s'arrêtait toujours à
trente.

---

## IV. Patcher une ROM que personne n'avait désassemblée

J'avais passé un mois à bâtir une machine capable de dumper les photos à l'infini et de recycler les
emplacements sans faute — et elle était bloquée par un programme de 1998 qui comptait jusqu'à trente
et disait non.

Mon premier réflexe fut d'aller dans la sauvegarde libérer un emplacement. Mais le piège du prologue
était absolu — éditez la sauvegarde de l'extérieur et la cartouche se suicide au redémarrage. La
rétro-ingénierie de la communauté le confirmait : forger un emplacement libre rate le checksum ou perd
le `"Magic"`, et toute la pellicule est effacée. Éditer la RAM est une impasse par conception.

La prise de conscience, quand elle est venue, a tout recadré : **le capteur n'a jamais été le
problème.** Les photos marchaient déjà. Le seul obstacle était un bout de *logiciel* — la logique
« pellicule pleine » de la ROM — et le logiciel, ça se patche. Pas en reflashant la cartouche (je
refusais d'ouvrir ou de modifier le matériel physique), mais en interceptant les lectures ROM qui
traversent déjà mon cœur FPGA et en *substituant d'autres octets à quelques adresses précises.* Le même
tour que l'espionnage des sélections de banque, pointé sur une nouvelle cible : réécrire le programme à
mesure que la Game Boy le lit.

Un obstacle à ce plan : pour patcher la routine « pellicule pleine », il fallait la *trouver*. Et elle
n'avait jamais été trouvée.

<details>
<summary>🔬 Désassembler le Game Boy Camera, parce que personne ne l'avait fait</summary>

J'ai lancé une recherche profonde et large — des dizaines d'agents en parallèle à travers les
communautés homebrew, ROM-hacking et préservation — pour un désassemblage de la logique de gestion
photo de la caméra. Il n'y en a pas. Il y a des désassemblages des *minijeux*, des outils qui *lisent*
le save, des projets qui *remplacent* toute la ROM (le `gb-photo` d'untoxa), mais personne n'avait
publié la logique « la pellicule est-elle pleine, et où est un emplacement libre » du firmware
commercial. J'ai donc écrit un petit désassembleur LR35902 et l'ai fait moi-même, contre les ROM US
(« GAMEBOYCAMERA ») et japonaise (« POCKETCAMERA V1.1 »).

Toute la gestion photo vit dans la **banque ROM `$02`**, à des offsets *identiques* entre US et JP —
signe fort de routines canoniques. `02:444D` est la boucle « scanne la pellicule » partagée : appelée
avec `A = $FF`, elle trouve un emplacement *libre* ; appelée avec un numéro, elle trouve *cette
photo*. Elle est générique — ce qui rend son patch direct dangereux. Et les routines de checksum en
`02:431F`/`432F` sont recalculées par le propre chemin de commit de la ROM — donc un patch d'octet qui
passe par le flux d'écriture normal obtient un checksum *correct* gratuitement, **sans suicide.** Cette
faille est ce qui rend toute l'approche survivable.

</details>

Trouver la routine était le début, pas la fin. Ont suivi quatre itérations matérielles, chacune
prouvant mon modèle de la ROM légèrement faux et m'enseignant la couche suivante.

Le premier patch neutralisait le refus « plein » aux trois sites d'écriture de photo. Résultat : le
trente-et-unième tir affichait **« no blank frame »** et s'arrêtait quand même. Il y avait donc un
garde *en amont* des sites d'écriture. Le deuxième patch visait le scan partagé `02:444D`. Résultat :
*aucun changement* — ce qui était l'indice. Si patcher le scan ne changeait rien, le garde ne
consultait pas le scan.

Puis l'observation qui a tout craqué : effacez la photo n°1 sur la caméra et la n°2 devient la n°1. La
pellicule *se renumérote*. Ce n'est pas un scan. C'est un **compteur.**

<details>
<summary>🔬 Ce n'était jamais un scan. C'était un compteur en $D561.</summary>

Après chaque opération, la ROM exécute `02:4466` : elle recharge l'annuaire en RAM de travail à
`$D563`, **renumérote et compacte** (la « pellicule glissante » que je voyais quand les suppressions
renumérotaient), puis compte les emplacements occupés :

```
02:4499   LD BC,$1E00        ; B = 30 (boucle), C = 0 (compte)
          ... boucle 30x ... ; LD A,(HL+); CP $FF; INC C si occupe
02:44A9   LD ($D561),A       ; le SEUL ecrivain de $D561
```

Chaque garde « pellicule pleine » de toute la ROM — banques 4, 6, 7 et préambules des sites d'écriture
— est les trois mêmes instructions : `LD A,($D561); CP $1E; saut-si-pas-inferieur → plein`. Elles
lisent toutes un octet. Il y avait un vrai point d'étranglement, et ce n'était pas un scan.

Le fix tient en un octet. Plafonner la boucle de comptage à 29 au lieu de 30 — offset `$049B`, `1E` →
`1D`. Désormais `$D561` n'atteint jamais 30, tous les gardes passent, la caméra ne refuse jamais. Sur
le matériel, le tir n°31 ne disait plus « no blank frame ». **La pellicule était infinie.**

Mais plafonner à 29 écrase toujours le même emplacement. Pour une *vraie* pellicule — recycler le plus
ancien d'abord, 0→29→0 — j'ai redirigé la recherche d'emplacement libre vers une routine injectée dans
l'espace libre à `$7AB5` (1 355 octets `$00` inutilisés en banque `$02`, communs aux deux ROM). Elle
renvoie l'emplacement de la photo la *plus ancienne* ; comme `02:4466` renumérote après chaque tir, le
« numéro 0 » tourne sur les emplacements physiques, et les écritures parcourent les trente. Elle teste
`A` d'abord pour que *seule* la recherche d'emplacement libre (`A=$FF`) soit détournée — une recherche
par numéro renvoie toujours l'honnête « non trouvé » de la ROM (détourner *celles-là* corrompt l'état
et plante, une leçon d'un crash de save-state ultérieur).

</details>

Le 30 juin, j'ai photographié au-delà de trente dans un album vide, et les photos atterrissaient sur
des emplacements *différents* — 30, puis 29, puis 28, arrivant par le bout et tournant. La pellicule
cyclait. Trente emplacements physiques, sans cesse rafraîchis, gardant toujours les trente photos les
plus récentes. **La pellicule était infinie, par logiciel seul, la cartouche et son capteur totalement
intacts.** Le problème « remettre la pellicule à zéro » — la seule question ouverte qui hantait chaque
document de conception — n'était pas résolu. Il était *supprimé.* On ne remet jamais à zéro une
pellicule qui se recycle toute seule.

Le rêve, sur le papier, était complet. Restait une verrue, tapie dans la fonctionnalité sur laquelle
je m'étais le plus appuyé.

---

## V. Coupé en deux

Chaque fois que je déclenchais un save-state pour dumper les photos, l'écran glitchait, revenait
environ une milliseconde, **se coupait en deux**, et gelait. Il fallait quitter et relancer le cœur
pour continuer. Le dump lui-même allait bien — le `.sta` était écrit et valide avant le gel — mais la
*reprise* était cassée. Lot après lot, je relançais à la main.

J'aurais pu livrer comme ça. Ça marchait ; c'était juste laid. Mais « coupé en deux, puis gel » est un
symptôme trop précis pour le laisser courir. Le dernier chapitre de ce projet est donc une histoire de
débogage sans débogueur — car je n'ai jamais ouvert la Pocket, jamais branché de sonde, et travaillé
entièrement depuis les fichiers de log de l'appareil et les sources du cœur.

D'abord j'ai prouvé ce que ce n'*était pas.* Ça arrivait avec mon overlay pellicule-infinie
**désactivé** — le cœur en marche était donc octet pour octet le cœur amont d'origine. Ce n'était pas
mon patch ROM. Le timing était propre. Ça se reproduisait sur un album fraîchement effacé. Les données
de sauvegarde étaient prouvées valides. Quoi que ce fût, c'était dans la *reprise de la Game Boy
émulée elle-même*, et c'était sans doute cassé depuis toujours — je ne l'avais jamais remarqué, parce
que je relançais de toute façon.

L'expression « coupé en deux » était l'indice. L'interface du Game Boy Camera utilise des effets
raster en milieu d'image — elle change les registres de scroll et de fenêtre *pendant que l'écran se
dessine.* Une image qui se coupe à l'horizontale et gèle, c'est un affichage qui a repris à la
mauvaise ligne, ou un CPU qui a déraillé en pleine image. Je suis donc entré dans le cœur et j'ai posé
la seule question qui comptait : **qu'est-ce qui, exactement, tourne encore pendant une pause de
save-state alors qu'il ne le devrait pas ?**

<details>
<summary>🔬 L'horloge de la cartouche physique ne s'est jamais arrêtée</summary>

En mode passthrough physique, le CPU émulé n'est *pas* mis en attente par la cartouche
(`cart_wait_n = 1'b1`). Une lecture cartouche n'est bien cadencée que parce que deux compteurs, tous
deux battant sur la même horloge système, restent en relation de phase fixe : `clkdiv` dans
`speedcontrol` (le générateur de phase de l'enable CPU `ce_cpu`), et `cart_phi_counter` dans
`core_top` (l'horloge PHI de la cartouche physique).

Pendant un save-state la Game Boy est en pause : `speedcontrol` **gèle `clkdiv`**. Mais `cart_phi`
n'était remis à zéro qu'au reset dur ou à un changement de vitesse — *jamais à la pause.* Donc pendant
que la machinerie du save-state passait ses nombreux cycles à sérialiser tout l'état de la console,
**`cart_phi` continuait de tourner librement.** À la reprise, `clkdiv` repartait de sa phase gelée
tandis que `cart_phi` était à une phase arbitraire, dérivée. La première lecture cartouche après
reprise latchait une donnée hors phase ; le CPU lisait du garbage, sautait ailleurs, et gelait — et
parce qu'il cessait d'écrire les registres scroll/LCDC en pleine image, l'UI raster de la caméra se
coupait en deux.

Le fix est de geler `cart_phi` sur *exactement* les cycles où `clkdiv` l'est. J'ai exposé l'état
interne `PAUSED` de `speedcontrol` comme nouvelle sortie `pause_active` — soigneusement, car la pause a
une queue de 15 cycles au relâchement, et geler à quelques cycles près réintroduirait la dérive — et
j'ai maintenu `cart_phi` tant qu'elle est asservie. Erreur résiduelle : environ une horloge système
sur trente-deux, ~3 %, confortablement dans la fenêtre de donnée PHI-haut. Et comme `speedcontrol` ne
pause que sans accès cartouche en cours, la gb ne gèle jamais en pleine transaction. `cart_phi` était
le *seul* signal physique qui dérivait ; gelez-le, et les deux horloges reprennent au pas.

C'est la leçon `ce_cpu` du chapitre III, revenue sous sa forme finale. À l'époque j'avais appris à ne
pas inventer d'horloge pour un bus que je *pilotais*. Ici le bug était l'image miroir : un bus que je
ne pilotais *pas*, dont j'avais simplement oublié d'arrêter l'horloge.

</details>

Deux fichiers modifiés. Un nouveau signal exposé depuis le contrôleur de vitesse ; une poignée de
lignes pour geler l'horloge cartouche avec l'horloge CPU. J'ai compilé, inversé bit à bit, copié sur
la SD, flashé, pris quelques photos, et appuyé **Analogue + Haut**.

L'écran a plongé, et est revenu. Entier. Pas de coupure. Pas de gel.

J'ai continué à photographier.

---

## Épilogue — Infini

Le flux de travail tient désormais en un souffle et ne demande rien d'autre que l'appareil en main :
**photographier trente ; save-state — il reprend proprement ; photographier trente de plus, les plus
anciens emplacements se recyclent, la caméra ne refuse jamais ; save-state à nouveau ; décoder à la
maison avec MugDump.** Pas de PC sur le terrain. Pas de remise à zéro. Pas de relance. Une cartouche de
1998, son capteur d'origine totalement intact, prenant une pellicule illimitée de photos sur une carte
SD, parce que la Game Boy en dessous a été discrètement instruite à mentir.

Je tiens à être honnête sur ce que ce fut, car c'est la partie qui mérite d'être gardée. Ce ne fut pas
une marche propre. Ce fut un format de sauvegarde qu'il a fallu soumettre par la méfiance, trois jours
perdus pour un seul chiffre hexa, quatre itérations matérielles pour apprendre qu'un « scan » était un
« compteur », une ROM que j'ai dû désassembler parce que le monde ne l'avait pas fait, et un gel final
débogué avec pour seuls outils des fichiers de log et une théorie sur une horloge. Chaque vraie percée
est venue de la même façon : quand tout échouait *à l'identique*, je regardais au mauvais endroit ;
quand j'étais invité sur du matériel, j'empruntais le timing qu'il utilisait déjà au lieu d'inventer le
mien. Ces deux idées, encore et encore, sont la colonne vertébrale d'ingénierie de ce projet.

La pellicule infinie est la première brique. J'en vois une seconde d'ici — une ROM homebrew
« appareil photo pur », tournant sur ce même cœur, tout en viseur et exposition, sans rien du fatras
de minijeux de 1998. Mais c'est une autre histoire, et celle-ci est finie. La pellicule ne se termine
plus.

**Trente, pour toujours.**

---

### Le sentier, si vous voulez le suivre

Les écrits techniques, dans l'ordre, vivent sous [`pocketroll/docs/`](pocketroll/docs/) :

- [**01 — format de sauvegarde SRAM**](pocketroll/docs/01-game-boy-camera-sram-format.md) — rétro-conçu et validé terrain.
- [**06 — récit de guerre build & debug**](pocketroll/docs/06-build-and-debug-war-story.md) — écrans blancs, `isgbc`, versions de Quartus.
- [**07 — la saga du dump**](pocketroll/docs/07-the-dump-saga.md) — impasses, le témoin `0xAA`, le bug d'un chiffre.
- [**09 — le dump fluide via save-state**](pocketroll/docs/09-the-fluid-dump-via-savestate.md).
- [**10 — état & feuille de route**](pocketroll/docs/10-state-and-roadmap.md) — la frontière du reset, et la décision de patcher la ROM.
- [**11 — désassemblage ROM & overlay d'écrasement**](pocketroll/docs/11-rom-disasm-overwrite.md) — le désassemblage maison, banque `$02`.
- [**12 — fix de reprise du save-state**](pocketroll/docs/12-savestate-resume-handoff.md) — la désync PHI cartouche physique et son fix.

Le cœur est un fork du `openfpga-GBC` de budude2, sans lequel rien de tout ceci n'aurait été possible ;
la rétro-ingénierie du format de sauvegarde s'appuie sur les travaux de Raphaël Boichot, insideGadgets,
et la communauté de préservation du Game Boy Camera au sens large.
