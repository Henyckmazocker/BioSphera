class_name SimTuning
extends Resource
## Fuente única de las constantes de comportamiento de la simulación.
##
## Antes estas cifras vivían dispersas como `const` en BehaviorSystem,
## GroupSystem, Sphere... cada una con su comentario "calibrada para...".
## Reunirlas aquí da: un solo sitio que tocar, edición en vivo por el
## jugador (objetivo del GDD) y — sobre todo — hace visible y testeable
## de qué ajustes depende la estabilidad.
##
## El recurso por defecto es `res://data/sim_tuning.tres`; lo expone el
## autoload `GlobalParams` como `GlobalParams.tuning`.
##
## NO incluye constantes estructurales de motor (tick rate, ruido de biomas,
## física): solo lo que afina el *comportamiento* de los agentes y el ritmo del
## mundo (cadencia del ciclo día/estación), editables en vivo por el jugador.

# ─── Ciclo natural (día / estaciones) ───────────────────────────────────────
# Cadencia del reloj climático (`ClimateSystem`). Un año = 4 estaciones (constante
# estructural en ClimateSystem). Con los defaults una estación dura
# seconds_per_day · days_per_season = 75 · 10 = 750 s sim (≈12,5 min a x1) y un año
# 3000 s sim (≈50 min a x1). Calendario corto a propósito: una esfera vive 60–240 s
# (data/traits.gd), así que una estación son pocas generaciones y el ciclo estacional
# (que modula el crecimiento vegetal, ver Plant.gd) se expresa durante la partida.

## Duración (s sim) de un día completo. El sol orbita según el progreso del día.
@export_range(30.0, 600.0, 5.0) var seconds_per_day: float = 75.0

## Días que dura cada estación (primavera→verano→otoño→invierno).
@export_range(1, 60, 1) var days_per_season: int = 10

# ─── Capa de decisión (Utility AI con histéresis) ───────────────────────────

## Segundos entre reevaluaciones de la acción de un agente.
@export_range(0.05, 1.0, 0.05) var decision_interval: float = 0.25

## Ventaja mínima de utilidad [0..1] que una acción alternativa debe sacarle
## a la acción actual para provocar un cambio. Es la histéresis que hace el
## thrashing imposible: para oscilar entre A y B, cada una debería superar a
## la otra por este margen a la vez — contradicción.
@export_range(0.0, 0.5, 0.01) var switch_margin: float = 0.15

## Ruido aleatorio añadido a la utilidad de cada acción. Da variedad ("no
## robótico") sin romper decisiones reales: mantener muy por debajo del
## `switch_margin`.
@export_range(0.0, 0.2, 0.01) var exploration_noise: float = 0.05

## Utilidad de fondo de `wander`. Es el suelo: cualquier necesidad real la
## supera. Define implícitamente "cuándo no hay nada mejor que hacer".
@export_range(0.0, 0.5, 0.01) var wander_utility: float = 0.12

## Duración mínima (s) que se mantiene una acción una vez elegida, aunque la
## decisión oscile — salvo que deje de ser factible. Backstop temporal contra
## el thrash: en un entorno concurrido el objetivo "más peligroso/cercano"
## cambia cada decisión; sin esto la histéresis de utilidad no basta.
@export_range(0.0, 3.0, 0.1) var min_action_duration: float = 1.0

# ─── Curvas de necesidad ────────────────────────────────────────────────────

## Tope de plantas vivas (silvestres + granja) por celda de la rejilla territorial
## (8×8 = 64 m²). Regla ÚNICA de densidad de plantas: reemplaza los antiguos topes
## por radio y escala con el tamaño del mundo (más celdas → más plantas posibles).
## Lo consulta `TerritorySystem.cell_has_room_for_plant` al sembrar/polinizar.
@export_range(1, 50, 1) var plants_per_cell_max: int = 8

## Tope GLOBAL de plantas vivas en el escenario (silvestres + granja). Acota el
## crecimiento orgánico (polinización + granjas): por encima de este total no se
## siembran más plantas, independientemente de la densidad por celda. La siembra
## inicial/rescate del Spawner está acotada por sus propios sliders (≤ tope).
## Lo consulta `TerritorySystem.cell_has_room_for_plant`.
@export_range(50, 5000, 50) var plants_total_max: int = 1000

## Radio (m) al que una esfera en seek_food localiza la planta madura más
## cercana hacia la que dirigirse. Mucho mayor que la visión: representa la
## búsqueda activa de comida. Sin esto, sin planta a la vista seek_food
## degenera en paseo aleatorio y los agentes mueren sin encontrar comida.
@export_range(15.0, 80.0, 5.0) var food_search_radius: float = 40.0

## Hambre [0..1] a la que buscar comida alcanza urgencia máxima (utilidad 1).
## A media hambre (≈0.55, energía ≈45) comer ya debe ganar a pelear, huir o
## cortejar: si se deja para casi la inanición, el agente cambia a seek_food
## sin energía suficiente para llegar a la comida y muere.
@export_range(0.4, 1.0, 0.05) var hunger_critical: float = 0.55

## Energía [0..1] bajo la cual el cortejo se desvanece (rampa suave, no corte).
@export_range(0.0, 1.0, 0.05) var mate_min_energy: float = 0.45

## Hambre [0..1] sobre la cual el cortejo se desvanece (rampa suave, no corte).
@export_range(0.0, 1.0, 0.05) var mate_max_hunger: float = 0.60

## Salud mínima (fracción de MAX_HEALTH) para poder reproducirse (gate duro de
## `Sphere.can_reproduce()`): una esfera malherida no cría.
@export_range(0.0, 1.0, 0.05) var repro_min_health_01: float = 0.5

## Madurez reproductiva como fracción de la longevidad propia (gate duro de
## `Sphere.can_reproduce()`). Fracción y no edad absoluta para no premiar la
## evolución de longevidades cortas (madurar antes sin coste).
@export_range(0.0, 0.5, 0.01) var repro_maturity_01: float = 0.15

# ─── Disputa de comida ──────────────────────────────────────────────────────

## Radio (m) alrededor de una planta dentro del cual otras esferas cuentan
## como contendientes por ese alimento.
@export_range(1.0, 12.0, 0.5) var food_contention_radius: float = 4.0

## Predisposición a disputar [0..1] por encima de la cual una esfera lucha
## por un alimento escaso en vez de ceder y buscar otro.
@export_range(0.0, 1.0, 0.05) var contest_threshold: float = 0.45

# ─── Grupos ─────────────────────────────────────────────────────────────────

## Segundos entre reevaluaciones del objetivo de un grupo por su líder.
@export_range(1.0, 15.0, 0.5) var group_reeval_interval: float = 4.0

## Hambre media del grupo [0..1] que dispara la búsqueda de comida (forage).
@export_range(0.0, 1.0, 0.05) var group_hunger_trigger: float = 0.55

## Radio máximo (m) de un punto de migración elegido por un grupo.
@export_range(5.0, 60.0, 1.0) var group_migrate_radius: float = 25.0

## Duración máxima (s) de una etapa de migración antes de re-elegir rumbo. Acota
## el caso de miembros distraídos (pelea/huida) que nunca alcanzan el target, sin
## volver al re-sorteo de dirección en cada reevaluación.
@export_range(4.0, 60.0, 1.0) var group_migrate_timeout: float = 16.0

## Cohesión mínima de un grupo (media de afinidades internas entre miembros,
## rango ~[-100, 100]). Si la cohesión cae por debajo, el grupo se disuelve.
## La cohesión decae con los conflictos (el combate baja la afinidad), así que
## un grupo que pelea internamente acaba rompiéndose. 0 = se disuelve en cuanto
## la afinidad media entre sus miembros se vuelve negativa (ver GDD → grupos).
@export_range(-50.0, 50.0, 1.0) var group_cohesion_min: float = 0.0

# ─── Acoplamiento individuo ↔ grupo ─────────────────────────────────────────

## Afinidad inicial (ALTA) de una cría hacia cada progenitor al nacer. El vínculo
## es mutuo: la cría quiere a los padres y los padres a la cría.
@export_range(0.0, 100.0, 1.0) var birth_parent_affinity: float = 40.0

## Afinidad inicial (levemente alta) de una cría hacia el resto de miembros del
## grupo que hereda de un progenitor al nacer. También mutua.
@export_range(0.0, 100.0, 1.0) var birth_group_affinity: float = 12.0

## Peso de `loyalty` (frente a `sociability`) en la utilidad de `follow_group`.
## 0 = solo sociabilidad (comportamiento previo); 1 = solo lealtad.
@export_range(0.0, 1.0, 0.05) var follow_loyalty_weight: float = 0.4

## Fuerza del "refugio": un cobarde amenazado con grupo cerca eleva su deseo de
## seguir al grupo en `(1-bravery)·threat_pressure·este_valor`.
@export_range(0.0, 2.0, 0.05) var group_refuge_bonus: float = 0.5

## Tope de utilidad de `follow_group` SOLO cuando aplica el refugio (con amenaza).
## Sin amenaza, sigue acotado por FOLLOW_GROUP_MAX (0.5).
@export_range(0.5, 1.0, 0.05) var follow_group_refuge_max: float = 0.85

## Cuánto sesga la huida hacia el centroide del grupo (0 = huida ciega previa,
## 1 = directo al grupo). Solo si el grupo está del lado contrario a la amenaza.
@export_range(0.0, 1.0, 0.05) var flee_to_group_bias: float = 0.5

## Nº de aliados cercanos para "apoyo pleno" (normaliza `ally_support` a [0..1]).
@export_range(1.0, 8.0, 1.0) var group_support_count: float = 3.0

## Reducción del miedo (utilidad de `flee`) con apoyo pleno de aliados [0..1].
@export_range(0.0, 1.0, 0.05) var support_fear_relief: float = 0.4

## Arrojo extra (utilidad de `fight`) con apoyo pleno de aliados. Puede superar
## FIGHT_MAX de forma modesta (tope global de fight con apoyo ≈ 0.9).
@export_range(0.0, 1.0, 0.05) var support_fight_bonus: float = 0.3

## Offset (m) sobre la VISIÓN MEDIA del grupo para el radio de alejamiento: un
## miembro a más de (visión_media + offset) del centroide se considera "fuera de
## la vista del grupo" y empieza a erosionar la afinidad que el resto le tiene.
@export_range(0.0, 30.0, 1.0) var group_stray_vision_offset: float = 5.0

## Cuánto crece el radio de alejamiento con el TAMAÑO del grupo (las manadas
## grandes se dispersan más por naturaleza). 0 = radio fijo (comportamiento
## previo); 1 = el radio escala con √(miembros/2), igual que el radio de forrajeo
## colectivo. Evita que un grupo grande expulse en masa a sus miembros por
## dispersarse de un único centroide.
@export_range(0.0, 1.0, 0.05) var group_stray_size_scaling: float = 1.0

## Afinidad de referencia a partir de la cual la erosión por dispersión se frena
## casi del todo: un miembro muy querido (familia, afinidad ≥ este valor) se
## "perdona" y casi no pierde afinidad por alejarse. A afinidad 0 la erosión es
## plena; entre medias, escala lineal (mín. 10 % de erosión para los más queridos).
@export_range(1.0, 100.0, 1.0) var group_kin_forgive_affinity: float = 30.0

## Radio de cohesión de la manada como FRACCIÓN del radio de expulsión (stray): en
## reagrupamiento (GATHER) un miembro cuenta como "agrupado" si está dentro de este
## radio del centroide, en vez de tener que ir al punto exacto (da volumen a la
## manada). Siempre < 1 para quedar SIEMPRE por debajo del límite de expulsión;
## escala con el tamaño porque el stray radius escala con √(miembros).
@export_range(0.1, 0.95, 0.05) var group_cohesion_radius_ratio: float = 0.6

## Segundos que un miembro debe llevar alejado antes de que empiece la erosión.
@export_range(0.0, 30.0, 0.5) var group_stray_grace: float = 6.0

## Afinidad/seg que el resto del grupo pierde hacia un miembro alejado (antes de
## escalar por distancia y por (1 - lealtad del que se aleja)).
@export_range(0.0, 10.0, 0.1) var group_stray_affinity_decay: float = 1.5

## Afinidad media RECIBIDA por debajo de la cual un miembro es expulsado del
## grupo (solo en grupos de 3+; con 2 lo gestiona la regla de < 2 miembros).
@export_range(-100.0, 0.0, 1.0) var group_expel_affinity: float = -15.0

# ─── Relaciones entre grupos ────────────────────────────────────────────────

## Radio (m) alrededor del centroide dentro del cual dos grupos "se ven" e
## interactúan (fusión / hostilidad). Solo se evalúan pares de grupos cercanos.
@export_range(5.0, 60.0, 1.0) var group_interact_radius: float = 20.0

## Afinidad media cruzada (entre miembros de los dos grupos) por ENCIMA de la
## cual dos grupos cercanos se fusionan (el grande absorbe al pequeño).
@export_range(0.0, 100.0, 1.0) var group_merge_affinity: float = 30.0

## Cuánto rebaja la DIFERENCIA de tamaño el umbral de fusión: 0 = umbral simétrico
## (comportamiento clásico), 1 = un grupo diminuto se funde en uno enorme con casi
## cualquier afinidad positiva. El umbral efectivo baja proporcionalmente a la
## disparidad de tamaño entre los dos grupos (un grupo pequeño se integra más
## fácil en uno grande).
@export_range(0.0, 1.0, 0.05) var group_merge_size_bias: float = 0.5

## Afinidad media cruzada por DEBAJO de la cual dos grupos cercanos se marcan
## como rivales (hostilidad). Negativa: requiere conflicto acumulado real.
@export_range(-100.0, 0.0, 1.0) var group_hostility_affinity: float = -15.0

## Segundos que dura una rivalidad sin refrescarse (al separarse o recuperar
## afinidad, caduca y los grupos dejan de ser hostiles).
@export_range(1.0, 60.0, 1.0) var group_rival_ttl: float = 12.0

## Arrojo extra (utilidad de `fight`) al pelear contra un miembro de un grupo
## RIVAL. Amplifica las peleas grupales una vez hay una chispa de combate.
@export_range(0.0, 1.0, 0.05) var group_hostility_fight_bonus: float = 0.3

# ─── Nidos (hogar del grupo asentado) ───────────────────────────────────────
# Un grupo que se queda en su zona funda un nido (ver `GroupSystem._update_settlement`).
# Los días se pasan a ticks con `seconds_per_day` y `SimulationClock.TICKS_PER_SECOND`.

## Miembros mínimos del grupo para que su arraigo cuente hacia fundar un nido.
@export_range(2, 20, 1) var nest_min_members: int = 5

## Días seguidos cumpliendo el criterio de arraigo (el mismo de la granja:
## `farm_build_ownership_min` en el centroide + territorialidad media) para fundar.
@export_range(0.25, 10.0, 0.25) var nest_settle_days: float = 2.0

## Días sin ningún miembro dentro de `nest_radius` tras los que el nido se abandona.
@export_range(0.25, 10.0, 0.25) var nest_abandon_days: float = 2.0

## Días que tarda un nido huérfano en hundirse y desaparecer.
@export_range(0.25, 10.0, 0.25) var nest_decay_days: float = 3.0

## Radio (m) del nido: un miembro dentro lo mantiene y una cría dentro está «en el
## nido». Igual que `farm_radius`.
@export_range(2.0, 20.0, 1.0) var nest_radius: float = 8.0

## Correa (m): con el centroide más lejos que esto del nido, GATHER vuelve al centroide.
@export_range(10.0, 120.0, 5.0) var nest_leash_radius: float = 40.0

## Arrojo extra (utilidad de `fight`) de un adulto que defiende su nido con crías en él.
## Mismo orden que `territory_defense_bonus`.
@export_range(0.0, 1.0, 0.05) var nest_defense_bonus: float = 0.15

# ─── Territorialidad (mapa de dominancia) ────────────────────────────────────
# Una rejilla de influencia (TerritorySystem) mide qué especie/grupo domina
# cada zona. Los ajenos sienten reluctancia a entrar (coste blando que el hambre
# rompe) y más miedo; los dueños defienden su zona con más arrojo. Ver GDD →
# Mecánicas (Territorialidad).

## Persistencia (s) del rastro de dominancia: tiempo en que la influencia
## acumulada en una celda cae a la mitad tras dejar de depositarse. Mayor =
## territorios que perduran más tras marcharse sus dueños.
@export_range(1.0, 60.0, 1.0) var territory_half_life: float = 12.0

## Influencia cruda que se considera "dominancia plena" (=1 al normalizar).
## Calibra cuántas esferas/cuánto tiempo hacen falta para que una zona cuente
## como territorio firme. Menor = el territorio se afirma con menos presencia.
@export_range(1.0, 50.0, 1.0) var territory_dominance_full: float = 8.0

## Peso [0..1] de la dominancia de GRUPO frente a la de especie en la presión
## que sienten los ajenos. 0 = solo cuenta la especie; 1 = un clan intimida a
## los no-miembros tanto como una especie rival.
@export_range(0.0, 1.0, 0.05) var territory_group_intimidation: float = 0.7

## Cuánto amplifica la presión territorial rival la utilidad de `flee` (un
## invasor se asusta más ante una amenaza estando en zona enemiga).
@export_range(0.0, 2.0, 0.05) var territory_fear_weight: float = 0.6

## Cuánto reduce el miedo (utilidad de `flee`) dominar la propia celda: el
## dueño aguanta en su zona en vez de huir.
@export_range(0.0, 1.0, 0.05) var territory_home_courage: float = 0.4

## Arrojo extra (utilidad de `fight`) por dominar la celda: el dueño defiende su
## territorio. Como los bonos de apoyo/hostilidad, puede superar FIGHT_MAX algo.
@export_range(0.0, 1.0, 0.05) var territory_defense_bonus: float = 0.3

## Fuerza del rechazo a elegir un DESTINO en zona rival (wander y búsqueda
## activa de comida). Probabilidad de descartar un candidato = presión rival ·
## (1-valentía) · (1-hambre) · este valor. 0 = sin reluctancia de movimiento.
@export_range(0.0, 1.0, 0.05) var territory_dest_avoid: float = 0.8

## Penalización al forrajear en zona rival: infla la distancia EFECTIVA de una
## planta en territorio enemigo, así se prefiere comer en zona propia/neutral
## salvo que el hambre o la valentía lo compensen.
@export_range(0.0, 3.0, 0.1) var territory_food_avoid: float = 1.0

## Fuerza del ARRAIGO al territorio del propio grupo: probabilidad de descartar un
## destino (wander / búsqueda de comida) que SAQUE a la esfera de la zona que su
## grupo domina. Escala con el rasgo `territoriality`, con la dominancia propia de
## la celda y con (1 - hambre): el hambre, la huida y la migración de grupo lo
## rompen, pero una esfera muy territorial apenas se aleja de su núcleo. 0 = sin
## arraigo. Coste blando por GRUPO (un loner no tiene zona propia). Ver GDD →
## Territorialidad.
@export_range(0.0, 2.0, 0.05) var territory_home_attachment: float = 0.8

## Radio (m) en el que una granja proyecta dominancia de GRUPO en el mapa
## territorial (la mantiene aunque no haya unidades cerca). Ver GDD →
## Territorialidad y `TerritorySystem.project_group_influence`.
@export_range(4.0, 40.0, 1.0) var farm_territory_radius: float = 18.0

## Dominancia [0..1] que una granja SOSTIENE en el centro de su radio (cae hacia
## el borde). El peso depositado se auto-calibra con el half-life para mantener
## esta dominancia sea cual sea la cadencia del tick lento de la granja.
@export_range(0.0, 1.0, 0.05) var farm_territory_strength: float = 0.8

# ─── Economía: recolección, armas, granjas y poder ───────────────────────────
# Capa de recursos (madera/piedra/oro): recolección dirigida por necesidades,
# fabricación de armas, construcción de granjas y oro→poder. Ver GDD → Economía.

## Radio (m) de búsqueda activa de un nodo de recurso al ejecutar GATHER cuando se
## pierde el objetivo (análogo a `food_search_radius` para la comida).
@export_range(10.0, 80.0, 5.0) var gather_search_radius: float = 30.0

## Necesidad de arma mínima (0..1) por encima de la cual una unidad fabrica un
## arma si tiene recursos. Por debajo, no merece la pena el gasto.
@export_range(0.0, 1.0, 0.05) var weapon_craft_threshold: float = 0.5

## Coste de fabricar un nivel de arma (de inventario propio o bolsa del grupo).
@export_range(0, 10, 1) var weapon_cost_wood: int = 2
@export_range(0, 10, 1) var weapon_cost_stone: int = 2

## Multiplicador de poder de combate POR NIVEL de arma (1 + nivel·este valor).
@export_range(0.0, 2.0, 0.05) var weapon_damage_mult: float = 0.5

## Cuánto sacia cada nivel de arma ya fabricado la necesidad de fabricar más
## (evita acumular armas sin límite; junto a WEAPON_LEVEL_MAX en Sphere).
@export_range(0.0, 1.0, 0.05) var weapon_satiation: float = 0.4

## Coste en recursos de construir una granja (se paga de la bolsa del grupo).
@export_range(0, 30, 1) var farm_cost_wood: int = 8
@export_range(0, 30, 1) var farm_cost_stone: int = 8

## Arraigo de grupo mínimo (dominancia territorial propia 0..1) para que el grupo
## prefiera CONSTRUIR una granja (proactivamente o frente a migrar).
@export_range(0.0, 1.0, 0.05) var farm_build_ownership_min: float = 0.4

## Tiempo máximo (s) que un grupo persiste en la obra de granja sin completarla
## (sin lograr juntar madera/piedra). Al vencer, abandona y entra en cooldown del
## mismo valor antes de volver a intentarlo.
@export_range(5.0, 120.0, 1.0) var farm_build_timeout: float = 25.0

## Intervalo (s) con el que una granja madura una planta a su alrededor.
@export_range(1.0, 30.0, 1.0) var farm_spawn_interval: float = 6.0

## Radio (m) en el que la granja siembra/madura plantas.
@export_range(2.0, 20.0, 1.0) var farm_radius: float = 8.0

## Vida de una granja. Las unidades de un grupo HOSTIL pueden atacarla (acción
## ATTACK_FARM) y, al agotarla, la destruyen. Ver GDD → Construcción.
@export_range(20.0, 500.0, 10.0) var farm_max_health: float = 100.0

## Multiplicador del daño de estructura: DPS contra una granja = poder de combate
## del atacante (`_combat_power`, el arma cuenta) · este valor. Calibra cuánto
## tarda en arrasarse una granja.
@export_range(0.5, 30.0, 0.5) var farm_attack_damage_mult: float = 6.0

## Escala de la utilidad de ATTACK_FARM (junto al tope RAID_MAX en BehaviorSystem):
## arrasar una granja enemiga es un acto de conflicto, por debajo de pelear/comer/huir.
## A 1.0 una unidad agresiva/territorial en guerra alcanza el tope; menor lo atenúa.
@export_range(0.0, 1.0, 0.05) var farm_raid_weight: float = 1.0

## Escala oro→poder INDIVIDUAL: poder = clamp(oro · esto, 0, 1). Mayor = pocas
## piezas de oro ya intimidan/atraen.
@export_range(0.0, 1.0, 0.01) var gold_power_scale: float = 0.08

## Escala oro→poder de GRUPO sobre el oro de la bolsa común.
@export_range(0.0, 1.0, 0.01) var gold_power_scale_group: float = 0.04

## Cuánto sesga la diferencia de poder la afinidad (atracción hacia el poderoso:
## alianzas/absorciones más fáciles para el rico).
@export_range(0.0, 5.0, 0.1) var power_affinity_weight: float = 2.0

## Cuánto rebaja el umbral de fusión la ventaja de poder del grupo absorbente
## (un grupo rico absorbe pequeños con más facilidad).
@export_range(0.0, 1.0, 0.05) var power_merge_bias: float = 0.5

# ─── Relaciones y conflicto entre grupos ─────────────────────────────────────
# Afinidad de grupo con estado (libro propio) además de la media de afinidades
# individuales; robo de comida de granjas ajenas; escalada invadir→atacar líder.
# Ver GDD → "Relaciones y conflicto entre grupos".

## Peso [0..1] del libro de grupo frente a la media de afinidades individuales en
## la afinidad EFECTIVA entre grupos (0 = solo individuos, 1 = solo libro de grupo).
@export_range(0.0, 1.0, 0.05) var group_relation_weight: float = 0.5

## Paso de olvido por reevaluación: cuánto se acerca a 0 cada entrada del libro de
## grupo si no hay nuevos agravios (enfría las guerras). 0 = no olvida.
@export_range(0.0, 10.0, 0.1) var group_relation_decay: float = 0.5

## Penalización al libro de grupo del dueño hacia el grupo del ladrón por cada
## bocado robado de su granja.
@export_range(0.0, 20.0, 0.5) var theft_group_penalty: float = 3.0

## Penalización a la afinidad individual (líder dueño → ladrón) por bocado robado.
@export_range(0.0, 20.0, 0.5) var theft_individual_penalty: float = 4.0

## Afinidad efectiva (≤) a partir de la cual un grupo INVADE el territorio del
## enemigo. Negativa: requiere enemistad acumulada real.
@export_range(-100.0, 0.0, 1.0) var group_invade_affinity: float = -40.0

## Afinidad efectiva (≤) a partir de la cual la invasión va A MUERTE: apunta
## directamente al líder enemigo.
@export_range(-100.0, 0.0, 1.0) var group_war_affinity: float = -75.0

# ─── Comida de granja: conciencia, evitación y compartir ─────────────────────
# Las plantas de una granja son del grupo que la construyó. Las esferas ajenas las
# EVITAN salvo necesidad/valentía; y si la relación con el dueño es buena, comerlas
# es COMPARTIR (sube amistad) en vez de robar.

## Hambre (0..1) por encima de la cual una esfera ajena sí toma comida de una
## granja de otro grupo (la necesidad rompe la evitación).
@export_range(0.0, 1.0, 0.05) var farm_food_avoid_hunger: float = 0.55

## Valentía por encima de la cual una esfera ajena toma comida de granja ajena
## sin importar el hambre (se atreve a robar).
@export_range(0.0, 1.0, 0.05) var farm_food_avoid_brave: float = 0.7

## Relación (afinidad) con el grupo/líder dueño por encima de la cual comer su
## comida de granja es COMPARTIR (sin penalización, sube amistad) en vez de robo.
@export_range(0.0, 100.0, 1.0) var farm_share_affinity: float = 20.0

## Subida de afinidad (libro de grupo y hacia el líder) al compartir comida de
## granja con un afín.
@export_range(0.0, 20.0, 0.5) var share_group_bonus: float = 3.0

## Intervalo (s) del rescate LENTO de yacimientos finitos (piedra/oro): repone
## hasta el mínimo configurado para que la economía no muera a media partida.
@export_range(10.0, 300.0, 5.0) var resource_rescue_interval: float = 60.0

# ─── Plaga (evento del entorno, modelo SIR) ──────────────────────────────────
# Contagio por proximidad con recuperación e inmunidad por cepa. Las reglas viven
# en `systems/Plague.gd`; el estado de cada infección, en `Sphere`. Ver docs:
# docs/GDD/Mecánicas.md (eventos del entorno) y el plan «Eventos del Entorno».

## Peso [0..1] de la genética (tamaño y longevidad) frente a la vitalidad (salud ×
## energía) en la resistencia a la plaga. 0 = solo cuenta el estado del momento.
@export_range(0.0, 1.0, 0.05) var plague_genetic_weight: float = 0.4

## Pacientes cero a intensidad 1 (las esferas más débiles al arrancar la plaga);
## el número efectivo es `max(1, ceil(intensidad × este valor))`.
@export_range(1, 50, 1) var plague_max_zeros: int = 5

## Intervalo (s sim) con el que cada infectado intenta contagiar a sus vecinos.
@export_range(0.1, 10.0, 0.1) var plague_contagion_interval: float = 1.0

## Radio (m) de contagio alrededor de cada infectado.
@export_range(0.5, 15.0, 0.5) var plague_radius: float = 3.0

## Probabilidad base de contagio por vecino y por intento, a fuerza de plaga 1 y
## debilidad 1 (`p = fuerza × esto × debilidad`).
@export_range(0.0, 1.0, 0.01) var plague_contagion: float = 0.5

## Duración de la infección como fracción de la longevidad efectiva de la propia
## esfera (`_t_longevity × lifespan_multiplier × mod de especie`, la misma que la
## muerte por vejez). En fracción y no en días porque una esfera vive entre 0,8 y
## 3,2 días: con un curso fijo en días nadie llegaba a curarse. Al acabar el curso,
## la esfera se cura e inmuniza a esa cepa.
@export_range(0.05, 1.0, 0.05) var plague_infection_frac: float = 0.25

## Salud perdida en todo el curso, en fracciones de `MAX_HEALTH`, a debilidad 0.5
## (el daño escala con `0.5 + debilidad`): con 0.8, el daño del curso llega a
## `MAX_HEALTH` con debilidad > 0.75 al infectarse. Se reparte por igual en cada segundo sim del curso. La
## salud no se regenera: quien se cura muy tocado queda estéril.
@export_range(0.0, 2.0, 0.05) var plague_damage_per_course: float = 0.8
