# Plan de implementación — BioSphera

Backlog ejecutable. Al cerrar una tarea, marcarla `[x]` y propagar cualquier decisión
nueva a la doc correspondiente (GDD / `docs/Programación.md`). Ver workflow en
[CLAUDE.md](../CLAUDE.md).

---

## Economía de recursos (comida, madera, piedra, oro)

Diseño completo en `docs/GDD/Mecánicas.md` → "Economía y recursos". Implementado en una
tanda; aquí queda el registro de lo cerrado y lo pendiente de pulir/balancear.

### Hecho

- [x] **A** — Clase base `ResourceNode` (enum `Type` FOOD/WOOD/STONE/GOLD, API
  `harvest`/`is_harvestable`, señales `harvested`/`depleted`). `Plant` pasa a extenderla
  (FOOD, sin cambios de comportamiento). Índice espacial genérico por tipo en
  `SpatialIndexSystem` (`register_resource`/`query_resources`; `register_plant`/
  `query_plants` como alias de FOOD).
- [x] **B** — `TreeNode` (madera regenerable) y `Deposit` (piedra/oro finito). Spawn
  inicial sesgado por bioma en `Spawner` (`RESOURCE_BIOME_WEIGHT`) + campos
  `initial_wood/stone/gold` en `SimConfig`. Render por tipo (MultiMesh) en
  `EntityRenderer`.
- [x] **C** — Inventario por esfera + bolsa común del grupo. Transferencia al unirse
  (`GroupSystem.register_member`) y al fusionar (`_merge_groups`). Rasgo heredable
  `industriousness` en `Traits.BEHAVIOR_KEYS`.
- [x] **E** — Acción `GATHER` en Utility AI + drives (arma/granja/oportunista). Selección
  y recolección de nodos en `Sphere`. Fabricación instantánea de armas (`weapon_level`) y
  bono en `_combat_power`.
- [x] **F** — `Goal.BUILD_FARM` en `GroupSystem` (arraigo+recursos vs migrar) + entidad
  `Farm` que madura plantas en su radio, pagada de la bolsa.
- [x] **D** — Oro → poder individual (loner irradia afinidad) y de grupo (rebaja umbral de
  fusión + empuja afinidad). `GroupSystem.power`, `Sphere.individual_power`.
- [x] **G/H** — Render de recursos/granjas; UI de inventario/arma/poder en `InspectPanel`;
  tunables de economía en `SimTuning`. Propagación a GDD/Programación/AGENTS.

### Iteración 2 (refinamientos) — hecho

- [x] Piedra más común y abundante por yacimiento (pesos de bioma + `units_total`/
  `units_per_harvest` en `Spawner`; `INITIAL_STONE_DEFAULT`).
- [x] Madera/piedra **solo por intención** (arma/granja); oro oportunista
  (`Sphere._decide_action`).
- [x] Granja **proactiva** de grupos asentados + timeout/cooldown anti-bloqueo
  (`GroupSystem`); sin precondición de tener ya los recursos.
- [x] **Ventana de inspección de grupo** (`ui/GroupInspectPanel.gd` + `Groups.get_group_info`
  + alta en `Hud`): líder, bolsa, poder, unidades con arma, nº de granjas.

### Iteración 3 (relaciones y conflicto entre grupos) — hecho

- [x] **Afinidad de grupo con estado** (libro `relations` por grupo) mezclada con la media
  individual (`_effective_inter_affinity`), con olvido lento y purga al disolver/fusionar.
- [x] **Propiedad de granjas + robo**: `Plant.owner_group_id`, `Farm` la fija,
  `Sphere._eat` detecta el robo, `GroupSystem.register_theft` (libro de grupo + líder→ladrón).
- [x] **Escalada INVADE**: `Goal.INVADE`, `_evaluate_war`/`_enter_invade`/`_refresh_invade_target`;
  alta enemistad → invadir territorio; extrema → ir a por el líder (`war_leader_id` + prioridad
  de combate en `Sphere`).
- [x] Tunables en `SimTuning`; INVADE en paneles; objetivo de guerra en `GroupInspectPanel`;
  doc GDD.

### Iteración 4 (balance tras analizar partida) — hecho

- [x] **Robo de granja reformulado**: las unidades evitan plantas de granja ajena salvo
  hambre/valentía/buena relación (`_willing_to_take_foreign`); al comerla, **comparten**
  (sube amistad, `register_share`) si hay afinidad, o **roban** (una vez por planta,
  `Plant.theft_charged`) si no. Corrige el flood de 14k `farm_theft` que ahogaba las fusiones.
- [x] **Recursos regenerables**: rescate lento de piedra/oro a un mínimo en `Spawner`
  (`resource_rescue_interval`, `min_stone`/`min_gold`) + más oro (inicial 30, 3–8/yacimiento).

### Iteración 5 (granjas como anclas territoriales y destruibles) — hecho

- [x] **Granjas proyectan territorio**: `TerritorySystem.deposit_group` +
  `project_group_influence` (peso auto-calibrado por equilibrio con el half-life, falloff
  radial); `Farm._on_tick` deposita dominancia de grupo en `farm_territory_radius`/
  `farm_territory_strength`. La zona sigue siendo del grupo sin unidades presentes.
- [x] **Granjas destruibles**: `Farm.health` (`farm_max_health`) + `take_damage`/`_destroy`
  (evento `farm_destroyed`, sin saqueo). Nueva acción `BehaviorSystem.Action.ATTACK_FARM`
  (tope `RAID_MAX` < pelear/comer/huir); `Sphere` adquiere granja de grupo **hostil**
  (`_pick_enemy_farm`/`_is_farm_target_valid`, gate `Groups.has_rivals`) y la ataca
  (`_attack_farm`, daño = `_combat_power · farm_attack_damage_mult`). Doc GDD actualizada.

### Pendiente (pulido y balance)

- [x] **Normalización de tamaños**: fuente única `data/visual_scale.gd` (`VisualScale`).
  Escala absoluta y fija en u de terreno; altura visual desacoplada del `size` de
  gameplay (banda 0.8–1.8 u, normalizada por altura nativa del `.glb` por especie).
  Jerarquía planta/roca < entidad < granja (huella) < árbol. Tocados `Sphere`
  (escala/etiquetas + `visual_height`/`visual_ground_radius`), `EntityRenderer`
  (árbol), `Farm` (huella), `GroupHighlight`/`CameraRig`. **Pendiente: el usuario
  verifica en simulación y ajusta constantes si el import difiere del AABB medido.**
- [ ] Verificar en simulación (el usuario ejecuta): regresión de comida, recolección,
  armas, granjas, oro→absorciones; FPS con 100 esferas. Ver "Verificación" del plan.
- [ ] Re-guardar `data/sim_tuning.tres` con los nuevos `@export` de economía y de granja
  (territorio/vida/asalto) — ahora usan los defaults del script.
- [ ] Exponer densidades de recurso por preset (`SimPreset`/`StartScreen`) y la media de
  `industriousness` por especie en `SimConfig.BEHAVIOR_TRAITS`.
- [ ] Balance: costes/rendimientos/umbrales, escala oro→poder, densidad de yacimientos.
- [ ] Decisiones abiertas: reparto de la bolsa al disolverse un grupo. (Granjas
  destruibles: cerrado en Iteración 5 — destruibles por hostiles, sin saqueo.)
