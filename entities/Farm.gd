class_name Farm
extends Node3D
## Granja: estructura estática de un grupo que asegura comida en su territorio.
##
## Cada `farm_spawn_interval` madura una planta en un radio a su alrededor,
## acelerando el ciclo de comida local. La construye el grupo pagando madera+piedra
## de su bolsa común cuando tiene ARRAIGO alto y escasea la comida (ver
## `GroupSystem._should_build_farm`). Persiste aunque el grupo desaparezca: queda
## como reliquia que sigue dando algo de comida.
##
## Mientras tenga grupo, PROYECTA territorio (dominancia de grupo) en su radio, así
## la zona sigue siendo del grupo aunque no haya unidades cerca (ver
## `TerritorySystem.project_group_influence`).
##
## Es DESTRUIBLE: las unidades de un grupo HOSTIL pueden atacarla (`take_damage`) y,
## al agotar su vida, la arrasan (`_destroy`). Ver GDD → Construcción.
##
## Tiene malla propia (pocas granjas en el mundo → no compensa el batch del
## EntityRenderer, igual que `Corpse`).
##
## Ver docs: docs/GDD/Mecánicas.md (sección "Economía y recursos").

const PLANT_SCENE: PackedScene = preload("res://entities/Plant.tscn")
## Modelo 3D de la granja (campo de cultivo estilo AoE2). Sustituye a la malla
## procedural caja+techo que se construía a mano.
const MODEL_SCENE: PackedScene = preload("res://assets/models/farm.glb")
## Oscurecimiento máximo del material al quedarse sin vida (feedback de daño).
const DAMAGE_DARKEN: float = 0.6

@export var world_bounds: Vector2 = Vector2(60.0, 60.0)
var group_id: int = -1
## Vida actual. Init a `farm_max_health` en `_ready`; al llegar a 0, la granja se
## destruye (ver `take_damage`/`_destroy`).
var health: float = 0.0

var _world: World
var _rng: RandomNumberGenerator
var _timer: float = 0.0
# Materiales del modelo (uno por superficie) y su color original: se oscurecen
# según el daño recibido como feedback visual de destrucción inminente.
var _materials: Array[BaseMaterial3D] = []
var _base_albedos: Array[Color] = []


func _ready() -> void:
	_rng = RandomNumberGenerator.new()
	_rng.randomize()
	_world = get_tree().get_first_node_in_group("world") as World
	health = GlobalParams.tuning.farm_max_health
	add_to_group(&"farms")
	_build_visual()


## Activación explícita (último paso tras posicionar): registra el tick lento y
## loguea la construcción.
func activate() -> void:
	SimulationClock.register_entity(self, true)
	EventLog.log_event(&"farm_built", {
		"group_id": group_id,
		"position": [global_position.x, global_position.y, global_position.z],
	}, &"groups")


func _exit_tree() -> void:
	SimulationClock.unregister_entity(self)


func _on_tick(dt_sim: float) -> void:
	# Proyección territorial: mantiene la zona como del grupo aunque no haya unidades.
	# Una granja-reliquia (grupo disuelto) no proyecta (group_id == -1).
	TerritorySystem.project_group_influence(global_position, group_id,
		GlobalParams.tuning.farm_territory_radius,
		GlobalParams.tuning.farm_territory_strength, dt_sim)
	_timer += dt_sim
	# La sequía también frena la siembra: si no, las granjas (plantas ya maduras,
	# sin polinizar) alimentan a todos y anulan el evento. Ver `Climate.food_supply_scale`.
	var interval: float = GlobalParams.tuning.farm_spawn_interval / maxf(Climate.food_supply_scale(), 0.01)
	if _timer < interval:
		return
	_timer = 0.0
	# La densidad la gobierna el tope por celda de la rejilla (ver
	# `_spawn_plant_around`): si la celda destino está llena, no se siembra.
	_spawn_plant_around(GlobalParams.tuning.farm_radius)


## Siembra una planta madura en una posición válida del radio (mismo criterio de
## validez que el Spawner: walkable + navmesh alcanzable).
func _spawn_plant_around(radius: float) -> void:
	for _attempt in 6:
		var angle: float = _rng.randf() * TAU
		var dist: float = _rng.randf_range(1.5, radius)
		var pos: Vector3 = global_position + Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)
		pos.x = clampf(pos.x, -world_bounds.x * 0.5 + 1.0, world_bounds.x * 0.5 - 1.0)
		pos.z = clampf(pos.z, -world_bounds.y * 0.5 + 1.0, world_bounds.y * 0.5 - 1.0)
		if _world != null:
			pos.y = _world.get_terrain_height(pos.x, pos.z) + 0.25
		if not Biomes.is_walkable_at(pos):
			continue
		if _world != null and not _world.is_navmesh_reachable(pos):
			continue
		# Tope de densidad por celda (compartido con las plantas silvestres).
		if not TerritorySystem.cell_has_room_for_plant(pos):
			continue
		var plant: Plant = PLANT_SCENE.instantiate()
		get_parent().add_child(plant)
		plant.world_bounds = world_bounds
		plant.global_position = pos
		plant.stage = Plant.Stage.MATURE
		plant.age = _rng.randf() * Plant.MATURE_LIFETIME
		# La planta pertenece al grupo dueño de la granja: comerla siendo ajeno = robo.
		plant.owner_group_id = group_id
		plant.activate()
		return


## Instancia el modelo 3D de la granja (campo de cultivo) y prepara sus materiales
## para el feedback de daño. El origen del modelo está en la base (Z=0): descansa a
## ras de suelo sin offset, ya que el nodo Farm está a la altura del terreno.
func _build_visual() -> void:
	var inst: Node3D = MODEL_SCENE.instantiate()
	# Hito con huella mayor que cualquier entidad. Escala derivada de la huella
	# objetivo en `VisualScale` (fuente única de escala visual).
	inst.scale = Vector3.ONE * VisualScale.farm_scale()
	add_child(inst)
	# Duplicar el material de cada superficie a un override propio (no mutar el
	# material compartido del import) y cachear su color base para oscurecerlo al
	# recibir daño. Mismo patrón que world/EntityModel.gd.
	for n in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		for s in range(mi.get_surface_override_material_count()):
			var src: Material = mi.get_active_material(s)
			var mat: BaseMaterial3D = (src.duplicate() if src is BaseMaterial3D
				else StandardMaterial3D.new())
			mi.set_surface_override_material(s, mat)
			_materials.append(mat)
			_base_albedos.append(mat.albedo_color)


# ---------------- GUARDADO ----------------
# Ver `SaveGame` y `Sphere.to_save`. `group_id` se guarda tal cual (ver plan, M2).

func to_save(_ids: Dictionary) -> Dictionary:
	return {
		"k": &"farm",
		"pos": global_position,
		"group_id": group_id,
		"health": health,
		"timer": _timer,
	}


## Restaura desde `to_save`. `_ready` ya fijó `health = farm_max_health`: la vida
## guardada se sobrescribe DESPUÉS de `activate()`, y con ella el oscurecimiento.
func from_save(d: Dictionary, _node_of: Array) -> void:
	global_position = d.pos
	group_id = int(d.group_id)
	_timer = float(d.timer)
	activate()
	health = float(d.health)
	_apply_damage_tint()


# ---------------- DAÑO Y DESTRUCCIÓN ----------------

## Recibe daño de una unidad atacante (acción ATTACK_FARM de un grupo hostil). Al
## agotar la vida, la granja se destruye. El feedback visual oscurece el techo.
func take_damage(amount: float, attacker: Sphere) -> void:
	if amount <= 0.0 or health <= 0.0:
		return
	health -= amount
	_apply_damage_tint()
	if health <= 0.0:
		_destroy(attacker)


## Oscurece el modelo según la vida que le queda (feedback de daño).
func _apply_damage_tint() -> void:
	var t: float = clampf(health / maxf(GlobalParams.tuning.farm_max_health, 0.001), 0.0, 1.0)
	for i in _materials.size():
		_materials[i].albedo_color = _base_albedos[i].darkened((1.0 - t) * DAMAGE_DARKEN)


## Arrasa la granja: loguea el evento y se elimina. La influencia territorial que
## proyectaba cesa sola por decaimiento. Las plantas ya sembradas persisten (siguen
## con su `owner_group_id`).
func _destroy(attacker: Sphere) -> void:
	EventLog.log_event(&"farm_destroyed", {
		"group_id": group_id,
		"attacker_group": attacker.group_id if is_instance_valid(attacker) else -1,
		"position": [global_position.x, global_position.y, global_position.z],
	}, &"groups")
	queue_free()
