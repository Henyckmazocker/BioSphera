#!/usr/bin/env python3
"""
analyze_logs.py — Análisis completo de una sesión de BioSphera.

Uso:
  python3 tools/analyze_logs.py                    # última sesión
  python3 tools/analyze_logs.py 2026-05-17T12-48   # prefijo de sesión
  python3 tools/analyze_logs.py --list             # listar sesiones disponibles
"""

import json
import sys
import os
import glob
import collections
import math
from pathlib import Path

LOG_DIR = Path.home() / "snap/godot-4/21/.local/share/godot/app_userdata/BioSphera/logs"
FALLBACK_LOG_DIR = Path.home() / ".local/share/godot/4/app_userdata/BioSphera/logs"

# Rangos de rasgos físicos (espejo de data/traits.gd) para normalizar desviaciones.
TRAIT_RANGES: dict[str, tuple[float, float]] = {
    "size": (0.5, 3.0),
    "speed": (1.0, 6.0),
    "vision": (3.0, 12.0),
    "metabolism": (0.5, 2.0),
    "longevity": (60.0, 240.0),
}
PHYS_KEYS = ["size", "speed", "vision", "metabolism", "longevity"]
BEHAVIOR_KEYS = ["aggression", "sociability", "loyalty", "bravery",
                 "reproductive_appetite", "selectivity", "territoriality"]
ALL_TRAIT_KEYS = PHYS_KEYS + BEHAVIOR_KEYS
MUTATION_BASE_SIGMA = 0.06  # GlobalParams.mutation_base_rate

# Dirección de fitness empírica (ver sección FACTORES DE SUPERVIVENCIA):
# metabolismo y tamaño bajos → más longevidad; velocidad/visión altas → más.
# +1 = "más alto es mejor", -1 = "más bajo es mejor", 0 = neutro/desconocido.
FITNESS_DIR: dict[str, int] = {
    "metabolism": -1, "size": -1, "speed": +1, "vision": +1, "longevity": +1,
}


# ─── utilidades ────────────────────────────────────────────────────────────────

def find_log_dir() -> Path:
    for d in [LOG_DIR, FALLBACK_LOG_DIR]:
        if d.exists():
            return d
    sys.exit(f"No se encontró el directorio de logs. Rutas buscadas:\n  {LOG_DIR}\n  {FALLBACK_LOG_DIR}")


def list_sessions(log_dir: Path) -> list[str]:
    files = glob.glob(str(log_dir / "*_sphere_A.jsonl"))
    sessions = sorted({Path(f).name.replace("_sphere_A.jsonl", "") for f in files})
    return sessions


def load_session(log_dir: Path, prefix: str) -> dict[str, list[dict]]:
    """Carga todos los archivos de la sesión y devuelve {categoria: [eventos]}."""
    data: dict[str, list[dict]] = {}
    for path in sorted(log_dir.glob(f"{prefix}_*.jsonl")):
        key = path.name.replace(f"{prefix}_", "").replace(".jsonl", "")
        events = []
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        events.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
        data[key] = events
    return data


def bar(value: int, scale: int = 1) -> str:
    return "█" * max(1, value // scale) if value > 0 else ""


def pct(n: int, total: int) -> str:
    return f"{100 * n / total:.1f}%" if total > 0 else "0%"


def hline(char: str = "─", width: int = 60) -> str:
    return char * width


# ─── análisis ──────────────────────────────────────────────────────────────────

def section(title: str) -> None:
    print(f"\n{'═' * 60}")
    print(f"  {title}")
    print('═' * 60)


def analyze_population(data: dict) -> None:
    section("POBLACIÓN Y SUPERVIVENCIA")

    births: dict[str, list] = {}
    deaths: dict[str, list] = {}
    all_ids: set = set()

    # Recopilar todos los IDs que aparecen en action_change (= vivos en algún momento)
    # y los que aparecen en death (con id, tras el fix del log).
    dead_ids: set = set()
    for cat, events in data.items():
        if not cat.startswith("sphere_"):
            continue
        sp = cat.replace("sphere_", "")
        births[sp] = []
        deaths[sp] = []
        for e in events:
            sid = e["data"].get("id")
            if e["kind"] == "action_change" and sid:
                all_ids.add(sid)
            elif e["kind"] == "birth":
                births[sp].append(e)
                # id del hijo disponible desde el fix del log
                if sid:
                    all_ids.add(sid)
            elif e["kind"] == "death":
                deaths[sp].append(e)
                if sid:  # disponible tras el fix; None en logs antiguos
                    dead_ids.add(sid)

    # Si los death events tienen id (log nuevo), supervivientes es exacto.
    # Si no (log antiguo), reportamos el total de IDs únicos como aproximación.
    has_death_ids = any(
        e["data"].get("id") is not None
        for events in data.values() for e in events
        if e.get("kind") == "death"
    )
    if has_death_ids:
        survivors = len(all_ids - dead_ids)
        survivors_note = ""
    else:
        survivors = len(all_ids)
        survivors_note = " (aprox — logs sin id en death, actualiza el juego)"

    total_births = sum(len(v) for v in births.values())
    total_deaths = sum(len(v) for v in deaths.values())

    # tick máximo
    max_tick = max(
        (e.get("tick", 0) for events in data.values() for e in events),
        default=0
    )
    sim_s = max_tick / 30.0

    print(f"  Duración sesión : {sim_s:.0f}s sim ({sim_s/60:.1f} min) — tick {max_tick}")
    print(f"  Supervivientes  : {survivors}{survivors_note}")
    print(f"  Nacimientos     : {total_births}  ({'+'.join(str(len(births.get(s,[]))) for s in sorted(births))} por especie)")
    print(f"  Muertes totales : {total_deaths}")

    print()
    for sp in sorted(deaths):
        d_list = deaths[sp]
        b_list = births.get(sp, [])
        causes = collections.Counter(e["data"]["cause"] for e in d_list)
        max_gen = max((e["data"]["generation"] for e in b_list), default=1)
        print(f"  Especie {sp}: {len(d_list)} muertes | {len(b_list)} nacimientos | gen_max={max_gen}")
        for cause, cnt in causes.most_common():
            print(f"    {cause}: {cnt} ({pct(cnt, len(d_list))})")


def analyze_gravity_bug(data: dict) -> None:
    section("CHECK BUG GRAVEDAD (Y < −2)")

    found = False
    for cat, events in data.items():
        if not cat.startswith("sphere_"):
            continue
        sp = cat.replace("sphere_", "")
        for e in events:
            y = e["data"].get("position", [0, 0, 0])[1]
            if y < -2.0:
                found = True
                d = e["data"]
                print(f"  ⚠  {d.get('name','?')} (sp={sp}) Y={y:.2f} "
                      f"tick={e.get('tick','?')} kind={e['kind']}")
    if not found:
        print("  ✓  Ninguna esfera con Y < −2. Bug gravedad corregido.")


def analyze_actions(data: dict) -> None:
    section("DISTRIBUCIÓN DE ACCIONES")

    for cat, events in data.items():
        if not cat.startswith("sphere_"):
            continue
        sp = cat.replace("sphere_", "")
        counter = collections.Counter(
            e["data"]["new_action"]
            for e in events if e["kind"] == "action_change"
        )
        total = sum(counter.values())
        if total == 0:
            continue
        print(f"  Especie {sp}  (total transiciones: {total})")
        for action, cnt in counter.most_common():
            b = bar(cnt, max(1, total // 40))
            print(f"    {action:<15} {cnt:5d}  {pct(cnt, total):>6}  {b}")
        print()


def analyze_eat_timeline(data: dict) -> None:
    section("TASA DE COMIDA (eat events por ventana de 500 ticks)")

    eat_counts: collections.Counter = collections.Counter()
    for cat, events in data.items():
        if not cat.startswith("sphere_"):
            continue
        for e in events:
            if e["kind"] == "eat":
                bucket = (e.get("tick", 0) // 500) * 500
                eat_counts[bucket] += 1

    if not eat_counts:
        print("  Sin eventos eat registrados.")
        return

    max_tick = max(eat_counts)
    max_val = max(eat_counts.values())
    scale = max(1, max_val // 30)
    total_eats = sum(eat_counts.values())
    print(f"  Total eats: {total_eats}")
    for bucket in range(0, max_tick + 500, 500):
        cnt = eat_counts.get(bucket, 0)
        b = bar(cnt, scale)
        print(f"  ticks {bucket:5d}–{bucket+499:<5d}  {cnt:4d}  {b}")


def analyze_deaths_detail(data: dict) -> None:
    section("DETALLE MUERTES POR HAMBRE — DISTRIBUCIÓN DE EDADES")

    hunger_ages: list[float] = []
    for cat, events in data.items():
        if not cat.startswith("sphere_"):
            continue
        for e in events:
            if e["kind"] == "death" and e["data"].get("cause") == "hunger":
                hunger_ages.append(e["data"]["age"])

    if not hunger_ages:
        print("  Sin muertes por hambre.")
        return

    hunger_ages.sort()
    median = hunger_ages[len(hunger_ages) // 2]
    print(f"  Total: {len(hunger_ages)}  min={hunger_ages[0]:.1f}  "
          f"max={hunger_ages[-1]:.1f}  mediana={median:.1f}")
    buckets = [(0, 30), (30, 60), (60, 90), (90, 120), (120, 999)]
    for lo, hi in buckets:
        cnt = sum(1 for a in hunger_ages if lo <= a < hi)
        b = bar(cnt, max(1, len(hunger_ages) // 30))
        label = f"{lo}–{hi if hi < 999 else '∞':>3}"
        print(f"  edad {label}s:  {cnt:3d}  {b}")


def analyze_early_deaths(data: dict, threshold: float = 30.0,
                         profiles: dict | None = None) -> None:
    section(f"MUERTES TEMPRANAS (edad < {threshold:.0f}s sim)")

    early: list[tuple] = []
    for cat, events in data.items():
        if not cat.startswith("sphere_"):
            continue
        sp = cat.replace("sphere_", "")
        for e in events:
            d = e["data"]
            if e["kind"] == "death" and d.get("cause") == "hunger" and d["age"] < threshold:
                g = d.get("genome", {})
                # Fallback a profiles para logs sin genome en el death event.
                if not g and profiles:
                    sid = d.get("id")
                    if sid and sid in profiles:
                        g = profiles[sid].get("genome", {})
                early.append((d["age"], d.get("sphere", "?"), sp,
                               g.get("metabolism", 0), g.get("speed", 0), g.get("size", 0)))
    early.sort()
    if not early:
        print(f"  Sin muertes por hambre antes de {threshold}s sim.")
        return
    print(f"  {'Nombre':<20} {'sp':2}  {'edad':>6}  {'metab':>5}  {'speed':>5}  {'size':>5}")
    print(f"  {hline('-', 55)}")
    for age, name, sp, met, spd, sz in early:
        print(f"  {name:<20} {sp:2}  {age:6.1f}  {met:5.2f}  {spd:5.2f}  {sz:5.2f}")


def analyze_flee_targets(data: dict, top_n: int = 10) -> None:
    section(f"TOP {top_n} CAUSANTES DE HUIDAS")

    counter: collections.Counter = collections.Counter()
    for cat, events in data.items():
        if not cat.startswith("sphere_"):
            continue
        for e in events:
            d = e["data"]
            if e["kind"] == "action_change" and d.get("new_action") == "flee" and d.get("target"):
                counter[d["target"]] += 1

    if not counter:
        print("  Sin eventos flee con target.")
        return
    for name, cnt in counter.most_common(top_n):
        b = bar(cnt, max(1, counter.most_common(1)[0][1] // 20))
        print(f"  {name:<25}  {cnt:4d}  {b}")


def analyze_combat(data: dict) -> None:
    section("COMBATE")

    fight_transitions = collections.Counter()
    combat_deaths = 0
    for cat, events in data.items():
        if not cat.startswith("sphere_"):
            continue
        sp = cat.replace("sphere_", "")
        for e in events:
            if e["kind"] == "action_change" and e["data"].get("new_action") == "fight":
                fight_transitions[sp] += 1
            elif e["kind"] == "death" and e["data"].get("cause") == "combat":
                combat_deaths += 1

    total_fight = sum(fight_transitions.values())
    if total_fight == 0:
        print("  ⚠  0 transiciones a fight — combate inactivo.")
    else:
        print(f"  Transiciones a fight: {total_fight}")
        for sp, cnt in sorted(fight_transitions.items()):
            print(f"    Especie {sp}: {cnt}")
    print(f"  Muertes por combate: {combat_deaths}")


def analyze_plants(data: dict) -> None:
    section("PLANTAS")

    plant_events = data.get("plants", [])
    if not plant_events:
        print("  Sin datos de plantas.")
        return

    # Plantas iniciales arrancan como "mature" (Spawner usa start_mature=True).
    # Las de polinización/rescate arrancan como "seed". Se usa el stage del
    # evento spawn en lugar del tick=0 porque call_deferred() puede correr en
    # tick=1 aunque el spawn ocurra antes del primer tick del reloj.
    spawns_t0 = sum(1 for e in plant_events
                    if e["kind"] == "spawn" and e["data"].get("stage") == "mature")
    spawns_later = sum(1 for e in plant_events
                       if e["kind"] == "spawn" and e["data"].get("stage") != "mature")
    stage_counts = collections.Counter(
        e["data"].get("new_stage", "?")
        for e in plant_events if e["kind"] == "stage_change"
    )

    print(f"  Spawns iniciales (mature) : {spawns_t0}")
    print(f"  Spawns polinización/rescue: {spawns_later}")
    print(f"  Maduraciones              : {stage_counts.get('mature', 0)}")
    print(f"  Marchitados (wilted)      : {stage_counts.get('wilted', 0)}")

    # Timeline de wilts
    wilt_ticks = sorted(
        e.get("tick", 0)
        for e in plant_events
        if e["kind"] == "stage_change" and e["data"].get("new_stage") == "wilted"
    )
    if wilt_ticks:
        print(f"\n  Distribución de wilts por ventana de 500 ticks:")
        wilt_counter: collections.Counter = collections.Counter(
            (t // 500) * 500 for t in wilt_ticks
        )
        max_wilt = max(wilt_counter.values())
        for bucket in range(0, max(wilt_ticks) + 500, 500):
            cnt = wilt_counter.get(bucket, 0)
            if cnt > 0:
                b = bar(cnt, max(1, max_wilt // 20))
                print(f"    ticks {bucket:5d}–{bucket+499:<5d}  {cnt:3d}  {b}")


def analyze_population_over_time(data: dict) -> None:
    section("EVOLUCIÓN DE LA POBLACIÓN (por especie)")

    all_events: list[tuple] = []
    for cat, events in data.items():
        if not cat.startswith("sphere_"):
            continue
        sp = cat.replace("sphere_", "")
        for e in events:
            all_events.append((e.get("tick", 0), sp, e["kind"], e["data"].get("id")))
    all_events.sort()

    alive: dict[str, set] = collections.defaultdict(set)
    dead_ids: set = set()
    max_tick = max((t for t, *_ in all_events), default=0)
    snapshot_interval = max(500, (max_tick // 8 // 500) * 500)
    snapshots: dict[int, dict] = {}

    for tick, sp, kind, sid in all_events:
        bucket = (tick // snapshot_interval) * snapshot_interval
        if kind == "action_change" and sid and sid not in dead_ids:
            alive[sp].add(sid)
        elif kind == "death" and sid:
            alive[sp].discard(sid)
            dead_ids.add(sid)
        if bucket not in snapshots:
            snapshots[bucket] = {s: len(v) for s, v in alive.items()}

    species = sorted(alive.keys() | {sp for snap in snapshots.values() for sp in snap})
    header = f"  {'tick':>7}  {'sim_s':>6}  " + "  ".join(f"sp{s:>2}" for s in species)
    print(header)
    print(f"  {hline('-', len(header) - 2)}")
    for bucket in sorted(snapshots):
        snap = snapshots[bucket]
        row = f"  {bucket:7d}  {bucket/30:6.0f}s  "
        row += "  ".join(f"{snap.get(s, 0):5d}" for s in species)
        print(row)


def analyze_survivors(data: dict, top_n: int = 15) -> None:
    section(f"TOP {top_n} SUPERVIVIENTES (última aparición en log)")

    seen: dict = {}
    dead: set = set()
    for cat, events in data.items():
        if not cat.startswith("sphere_"):
            continue
        sp = cat.replace("sphere_", "")
        for e in events:
            sid = e["data"].get("id")
            if not sid:
                continue
            if e["kind"] == "death":
                dead.add(sid)
            elif e["kind"] == "action_change":
                seen[sid] = (e["data"].get("name", "?"), sp, e.get("tick", 0),
                             e["data"].get("age", 0), e["data"].get("energy", 0))

    has_death_ids = bool(dead)
    if has_death_ids:
        survivors = [(v[2], v[0], v[1], v[3], v[4])
                     for k, v in seen.items() if k not in dead]
    else:
        survivors = list(seen.values())
        survivors = [(v[2], v[0], v[1], v[3], v[4]) for v in survivors]
        print("  (logs sin id en death — lista incluye posibles muertos)")
    survivors.sort(reverse=True)
    print(f"  {'Nombre':<22} {'sp':2}  {'last_tick':>9}  {'edad':>7}  {'energy':>8}")
    print(f"  {hline('-', 58)}")
    for last_tick, name, sp, age, energy in survivors[:top_n]:
        print(f"  {name:<22} {sp:2}  {last_tick:9d}  {age:7.1f}  {energy:8.1f}")


# ─── diagnóstico conductual ────────────────────────────────────────────────────

def build_sphere_profiles(data: dict) -> dict:
    """
    Construye un perfil por esfera a partir de todos los eventos.
    Clave: instance_id (int). Cada perfil contiene genome, acciones, eats,
    mortalidad y los campos necesarios para el análisis de coherencia.
    """
    profiles: dict = {}

    for cat, events in data.items():
        if not cat.startswith("sphere_"):
            continue
        sp = cat.replace("sphere_", "")

        for e in events:
            d = e["data"]
            sid = d.get("id")

            if e["kind"] == "action_change" and sid:
                if sid not in profiles:
                    profiles[sid] = {
                        "id": sid,
                        "name": d.get("name", "?"),
                        "species": sp,
                        "generation": d.get("generation", 1),
                        "genome": d.get("genome", {}),
                        "actions": collections.Counter(),
                        "eats": 0,
                        "died": False,
                        "cause": None,
                        "age_final": 0.0,
                        "energy_final": 0.0,
                        "flee_targets": [],
                        "fight_targets": [],
                    }
                p = profiles[sid]
                action = d.get("new_action", "?")
                p["actions"][action] += 1
                p["age_final"] = max(p["age_final"], d.get("age", 0.0))
                p["energy_final"] = d.get("energy", 0.0)
                if action == "flee" and d.get("target"):
                    p["flee_targets"].append(d["target"])
                elif action == "fight" and d.get("target"):
                    p["fight_targets"].append(d["target"])

            elif e["kind"] == "eat":
                sid_eat = d.get("id")
                if sid_eat and sid_eat in profiles:
                    profiles[sid_eat]["eats"] += 1

            elif e["kind"] == "death":
                sid_d = d.get("id")
                if sid_d and sid_d in profiles:
                    profiles[sid_d]["died"] = True
                    profiles[sid_d]["cause"] = d.get("cause")
                    profiles[sid_d]["age_final"] = d.get("age", profiles[sid_d]["age_final"])

    # Campos derivados
    for p in profiles.values():
        total = sum(p["actions"].values())
        p["total_actions"] = total
        p["action_pct"] = {k: v / total for k, v in p["actions"].items()} if total > 0 else {}
        g = p["genome"]
        m = float(g.get("metabolism", 1.25))
        s = float(g.get("size", 1.75))
        consume = m * (0.6 + 0.4 * s)
        p["theoretical_starvation"] = 100.0 / consume if consume > 0 else 999.0

    return profiles


def _trait(p: dict, key: str, default: float = 0.5) -> float:
    return float(p["genome"].get(key, default))


def _tercile_label(value: float, lo: float, hi: float) -> str:
    mid = (lo + hi) / 2.0
    q1 = (lo + mid) / 2.0
    q3 = (mid + hi) / 2.0
    if value < q1:
        return "bajo"
    elif value > q3:
        return "alto"
    return "medio"


def _mean(lst: list) -> float:
    return sum(lst) / len(lst) if lst else 0.0


def _correlation_direction(xs: list, ys: list) -> str:
    """Devuelve '↑ correlación positiva', '↓ negativa' o '~ sin relación' simple."""
    if len(xs) < 4:
        return "~ (pocos datos)"
    n = len(xs)
    mx, my = _mean(xs), _mean(ys)
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    dx = sum((x - mx) ** 2 for x in xs)
    dy = sum((y - my) ** 2 for y in ys)
    denom = math.sqrt(dx * dy) if dx * dy > 0 else 0
    r = num / denom if denom > 0 else 0.0
    if r > 0.15:
        return f"↑ positiva  (r≈{r:+.2f})"
    elif r < -0.15:
        return f"↓ negativa  (r≈{r:+.2f})"
    return f"~ sin relación (r≈{r:+.2f})"


def _pearson(xs: list, ys: list) -> float:
    """Coeficiente de correlación de Pearson (float). 0.0 si pocos datos."""
    if len(xs) < 4:
        return 0.0
    mx, my = _mean(xs), _mean(ys)
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    dx = sum((x - mx) ** 2 for x in xs)
    dy = sum((y - my) ** 2 for y in ys)
    denom = math.sqrt(dx * dy)
    return num / denom if denom > 0 else 0.0


def analyze_species_behavior(data: dict) -> None:
    section("COMPORTAMIENTO POR ESPECIE (vs expectativas del diseño)")

    profiles = build_sphere_profiles(data)

    # Expectativas del GDD (traits.gd):
    # Especie A: social_bias=0.25 → más solitaria → más wander, menos follow_group
    # Especie B: social_bias=0.75 → más sociable → más follow_group, coopera más
    EXPECTED = {
        "A": {"follow_group": "bajo", "wander": "alto", "nota": "solitaria (social_bias=0.25)"},
        "B": {"follow_group": "alto", "wander": "bajo", "nota": "sociable (social_bias=0.75)"},
    }

    sp_data: dict = {}
    for p in profiles.values():
        sp = p["species"]
        if sp not in sp_data:
            sp_data[sp] = {
                "actions": collections.Counter(),
                "sociabilities": [],
                "aggressions": [],
                "ages": [],
                "eats": [],
                "survived": 0,
                "died_hunger": 0,
                "total": 0,
            }
        sd = sp_data[sp]
        for a, cnt in p["actions"].items():
            sd["actions"][a] += cnt
        sd["sociabilities"].append(_trait(p, "sociability"))
        sd["aggressions"].append(_trait(p, "aggression"))
        sd["ages"].append(p["age_final"])
        sd["eats"].append(p["eats"])
        sd["total"] += 1
        if not p["died"]:
            sd["survived"] += 1
        if p["cause"] == "hunger":
            sd["died_hunger"] += 1

    for sp in sorted(sp_data):
        sd = sp_data[sp]
        total_a = sum(sd["actions"].values())
        exp = EXPECTED.get(sp, {})
        print(f"\n  ── Especie {sp} ({exp.get('nota', '')})")
        print(f"     Individuos: {sd['total']}  |  Sobreviven: {sd['survived']}  "
              f"|  Muertos hambre: {sd['died_hunger']}")
        print(f"     Sociabilidad media: {_mean(sd['sociabilities']):.2f}  "
              f"Agresión media: {_mean(sd['aggressions']):.2f}")
        print(f"     Eats por individuo: {_mean(sd['eats']):.1f}  "
              f"Edad final media: {_mean(sd['ages']):.1f}s")
        print(f"     Distribución de acciones:")
        for action, cnt in sd["actions"].most_common():
            pct_v = 100 * cnt / total_a if total_a > 0 else 0
            flag = ""
            if action == "follow_group":
                observed = "alto" if pct_v > 8 else "bajo"
                expected_lvl = exp.get("follow_group", "?")
                flag = "  ✓" if observed == expected_lvl else "  ⚠ esperado: " + expected_lvl
            elif action == "wander":
                observed = "alto" if pct_v > 20 else "bajo"
                expected_lvl = exp.get("wander", "?")
                flag = "  ✓" if observed == expected_lvl else "  ⚠ esperado: " + expected_lvl
            print(f"       {action:<15}  {pct_v:5.1f}%{flag}")


def analyze_genome_action_correlation(data: dict) -> None:
    section("COHERENCIA GENOMA → ACCIÓN (correlaciones rasgo/comportamiento)")

    profiles = build_sphere_profiles(data)
    valid = [p for p in profiles.values() if p["genome"] and p["total_actions"] >= 5]

    if len(valid) < 10:
        print("  Datos insuficientes para correlaciones.")
        return

    # Definir pares (rasgo, acción esperada, dirección esperada, descripción)
    checks = [
        ("aggression",            "fight",        "+", "agresión alta → más fight"),
        ("bravery",               "flee",         "-", "valentía alta → menos flee"),
        ("sociability",           "follow_group", "+", "sociabilidad alta → más follow_group"),
        ("reproductive_appetite", "seek_mate",    "+", "apetito reproductivo alto → más seek_mate"),
        ("metabolism",            "seek_food",    "+", "metabolismo alto → más hambre → más seek_food"),
        ("vision",                "seek_food",    "+", "visión alta → detecta más plantas"),
    ]

    print(f"  {'Rasgo':<25}  {'→ Acción':<15}  {'Esperado'}  {'Observado'}")
    print(f"  {hline('-', 72)}")
    for trait, action, expected_dir, desc in checks:
        xs = [_trait(p, trait) for p in valid]
        ys = [p["action_pct"].get(action, 0.0) for p in valid]
        direction = _correlation_direction(xs, ys)
        ok = (expected_dir == "+" and "positiva" in direction) or \
             (expected_dir == "-" and "negativa" in direction)
        marker = "✓" if ok else "⚠"
        print(f"  {marker} {trait:<23}  {action:<15}  {'(+)' if expected_dir=='+' else '(-)'}"
              f"  {direction}")
        if not ok:
            # Mostrar medias por tercil para ver el patrón real
            lo_grp = [p["action_pct"].get(action, 0.0) for p in valid if _trait(p, trait) < 0.4]
            hi_grp = [p["action_pct"].get(action, 0.0) for p in valid if _trait(p, trait) > 0.6]
            if lo_grp and hi_grp:
                print(f"    → {trait}<0.4: media {action}={_mean(lo_grp)*100:.1f}%  "
                      f"{trait}>0.6: media {action}={_mean(hi_grp)*100:.1f}%")


def analyze_survival_factors(data: dict) -> None:
    section("FACTORES DE SUPERVIVENCIA (traits vs longevidad)")

    profiles = build_sphere_profiles(data)
    # Solo esferas que murieron (tenemos su edad exacta)
    dead = [p for p in profiles.values() if p["died"] and p["genome"] and p["age_final"] > 0]

    if len(dead) < 10:
        # Puede que el log sea antiguo y los death events no tengan id.
        has_old_log = not any(
            e["data"].get("id") for events in data.values() for e in events
            if e.get("kind") == "death"
        )
        if has_old_log:
            print("  Log antiguo: death events sin campo 'id'. Lanza una nueva partida para datos completos.")
        else:
            print("  Datos insuficientes.")
        return

    print(f"  N esferas muertas con datos: {len(dead)}")
    print()

    traits_to_check = [
        ("speed",        "velocidad: más rápida → encuentra comida antes"),
        ("vision",       "visión: rango mayor → detecta comida antes"),
        ("metabolism",   "metabolismo: alto → gasta más → muere antes"),
        ("size",         "tamaño: grande → más gasto → muere antes"),
        ("aggression",   "agresión: alta → ¿más conflictos → muere antes?"),
        ("bravery",      "valentía: alta → no huye → ¿vive más o menos?"),
    ]

    print(f"  {'Rasgo':<12}  {'bajo (<0.4 o <median)':<30}  {'alto (>0.6 o >median)':<30}  Dirección")
    print(f"  {hline('-', 78)}")
    for trait, desc in traits_to_check:
        vals = [_trait(p, trait) for p in dead]
        median_t = sorted(vals)[len(vals) // 2]
        lo_ages = [p["age_final"] for p in dead if _trait(p, trait) < median_t]
        hi_ages = [p["age_final"] for p in dead if _trait(p, trait) >= median_t]
        if not lo_ages or not hi_ages:
            continue
        lo_m = _mean(lo_ages)
        hi_m = _mean(hi_ages)
        diff = hi_m - lo_m
        direction = f"↑ +{diff:.1f}s" if diff > 2 else (f"↓ {diff:.1f}s" if diff < -2 else f"~ {diff:.1f}s")
        r_str = _correlation_direction(vals, [p["age_final"] for p in dead])
        print(f"  {trait:<12}  media_edad_bajo={lo_m:5.1f}s  {'':<9}  media_edad_alto={hi_m:5.1f}s  "
              f"{direction}  {r_str}")
    print()

    # Eats vs supervivencia (solo disponible en logs nuevos con id en eat events)
    if any(p["eats"] > 0 for p in dead):
        print("  Eats vs supervivencia (esferas muertas):")
        eat_vals = [p["eats"] for p in dead]
        age_vals = [p["age_final"] for p in dead]
        r_str = _correlation_direction(eat_vals, age_vals)
        groups = [(0, 0), (1, 1), (2, 3), (4, 99)]
        for lo, hi in groups:
            grp = [p["age_final"] for p in dead if lo <= p["eats"] <= hi]
            label = f"{lo}" if lo == hi else (f"{lo}-{hi}" if hi < 99 else f"{lo}+")
            if grp:
                print(f"    eats={label}: N={len(grp)}  media_edad={_mean(grp):.1f}s  "
                      f"max={max(grp):.1f}s")
        print(f"    Correlación eats→edad: {r_str}")


def analyze_action_coherence(data: dict) -> None:
    section("COHERENCIA DE ACCIONES (anomalías por individuo)")

    profiles = build_sphere_profiles(data)
    valid = [p for p in profiles.values() if p["genome"] and p["total_actions"] >= 5]

    anomalies: list[tuple[str, str, str]] = []  # (nivel, nombre, descripción)

    for p in valid:
        g = p["genome"]
        agg  = _trait(p, "aggression")
        brav = _trait(p, "bravery")
        soc  = _trait(p, "sociability")
        repro = _trait(p, "reproductive_appetite")
        fight_pct  = p["action_pct"].get("fight", 0.0)
        flee_pct   = p["action_pct"].get("flee", 0.0)
        group_pct  = p["action_pct"].get("follow_group", 0.0)
        mate_pct   = p["action_pct"].get("seek_mate", 0.0)
        name = p["name"]
        sp   = p["species"]

        # Muy agresivo pero nunca pelea
        if agg > 0.75 and fight_pct == 0.0:
            anomalies.append(("⚠", f"{name} ({sp})",
                f"agresión={agg:.2f} pero fight=0%"))

        # Muy cobarde pero casi no huye
        if brav < 0.25 and flee_pct < 0.05 and p["total_actions"] > 20:
            anomalies.append(("ℹ", f"{name} ({sp})",
                f"valentía={brav:.2f} (cobarde) pero flee solo {flee_pct*100:.1f}%"))

        # Muy sociable (sp B) pero no sigue grupos
        if soc > 0.75 and group_pct < 0.02 and p["total_actions"] > 20:
            anomalies.append(("ℹ", f"{name} ({sp})",
                f"sociabilidad={soc:.2f} pero follow_group={group_pct*100:.1f}%"))

        # Valentía muy alta pero huye mucho
        if brav > 0.75 and flee_pct > 0.30:
            anomalies.append(("⚠", f"{name} ({sp})",
                f"valentía={brav:.2f} pero flee={flee_pct*100:.0f}%"))

        # Vive mucho más que el teórico sin comer
        expected_starve = p["theoretical_starvation"]
        if p["age_final"] > expected_starve * 2.5 and not p["died"]:
            anomalies.append(("★", f"{name} ({sp})",
                f"sobrevive {p['age_final']:.0f}s (teórico inanición {expected_starve:.0f}s) — come bien"))

        # Muere antes de su teórico (con hambre)
        if p["cause"] == "hunger" and p["age_final"] < expected_starve * 0.6:
            anomalies.append(("ℹ", f"{name} ({sp})",
                f"muere hambre a {p['age_final']:.0f}s pero teórico era {expected_starve:.0f}s — ¿perdió energía por combate?"))

    if not anomalies:
        print("  Sin anomalías detectadas.")
        return

    # Agrupar por nivel
    for nivel in ("⚠", "ℹ", "★"):
        group = [(n, d) for lv, n, d in anomalies if lv == nivel]
        if not group:
            continue
        labels = {"⚠": "ADVERTENCIAS", "ℹ": "INFO", "★": "DESTACADOS"}
        print(f"\n  {nivel} {labels[nivel]} ({len(group)})")
        for name, desc in group[:15]:
            print(f"    {name:<25}  {desc}")
        if len(group) > 15:
            print(f"    ... y {len(group)-15} más")


def analyze_notable_individuals(data: dict) -> None:
    section("INDIVIDUOS NOTABLES")

    profiles = build_sphere_profiles(data)
    valid = [p for p in profiles.values() if p["genome"]]

    if not valid:
        print("  Sin datos.")
        return

    old_log = not any(p["died"] for p in valid)
    if old_log:
        print("  (Log antiguo: muertes/eats sin id — supervivencia y eats aproximados)\n")

    def show(label: str, p: dict) -> None:
        g = p["genome"]
        status = f"muerto({p['cause']})" if p["died"] else "vivo"
        print(f"  {label}")
        print(f"    {p['name']} ({p['species']}) gen{p['generation']}  "
              f"edad={p['age_final']:.1f}s  eats={p['eats']}  {status}")
        print(f"    agro={_trait(p,'aggression'):.2f}  val={_trait(p,'bravery'):.2f}  "
              f"soc={_trait(p,'sociability'):.2f}  vel={_trait(p,'speed'):.2f}  "
              f"vis={_trait(p,'vision'):.1f}  meta={_trait(p,'metabolism'):.2f}  "
              f"tam={_trait(p,'size'):.2f}")
        top_actions = p["actions"].most_common(3)
        total = p["total_actions"]
        action_str = "  ".join(f"{a}:{100*c/total:.0f}%" for a, c in top_actions)
        print(f"    acciones: {action_str}")

    # Más longevo (muerto con age_final mayor)
    dead_sorted = sorted((p for p in valid if p["died"]), key=lambda p: -p["age_final"])
    if dead_sorted:
        show("🔴 Más longevo (muerto):", dead_sorted[0])
    print()

    # Superviviente más activo
    alive_sorted = sorted((p for p in valid if not p["died"]), key=lambda p: -p["age_final"])
    if alive_sorted:
        show("🟢 Superviviente mayor:", alive_sorted[0])
    print()

    # Más combativo
    most_fights = sorted(valid, key=lambda p: -p["actions"].get("fight", 0))
    if most_fights[0]["actions"].get("fight", 0) > 0:
        show("⚔  Más combativo:", most_fights[0])
    print()

    # Más comilón
    most_eats = sorted(valid, key=lambda p: -p["eats"])
    if most_eats[0]["eats"] > 0:
        show("🌿 Más comilón:", most_eats[0])
    print()

    # Más miedoso (más flee)
    most_flee = sorted(valid, key=lambda p: -p["actions"].get("flee", 0))
    if most_flee[0]["actions"].get("flee", 0) > 0:
        show("💨 Más huidizo:", most_flee[0])


# ─── grupos ────────────────────────────────────────────────────────────────────

def analyze_groups(data: dict, profiles: dict) -> None:
    section("GRUPOS")

    group_events = data.get("groups", [])

    # ── Ciclo de vida (solo en sesiones con logging de grupos) ──
    if group_events:
        formed = [e for e in group_events if e["kind"] == "group_formed"]
        dissolved = [e for e in group_events if e["kind"] == "group_dissolved"]
        goal_changes = [e for e in group_events if e["kind"] == "goal_changed"]

        print(f"  Grupos formados : {len(formed)}")
        print(f"  Grupos disueltos: {len(dissolved)}")
        print(f"  Cambios de objetivo: {len(goal_changes)}")

        if goal_changes:
            goal_counter = collections.Counter(e["data"]["new_goal"] for e in goal_changes)
            total_gc = sum(goal_counter.values())
            print(f"\n  Distribución de objetivos (sobre cambios):")
            for goal, cnt in goal_counter.most_common():
                b = bar(cnt, max(1, total_gc // 30))
                print(f"    {goal:<10} {cnt:4d}  {pct(cnt, total_gc):>6}  {b}")

            forage_h = [e["data"]["avg_hunger"] for e in goal_changes
                        if e["data"].get("new_goal") == "forage" and "avg_hunger" in e["data"]]
            migrate_h = [e["data"]["avg_hunger"] for e in goal_changes
                         if e["data"].get("new_goal") == "migrate" and "avg_hunger" in e["data"]]
            if forage_h:
                print(f"\n  Hambre media grupo → FORAGE : {_mean(forage_h):.2f}")
            if migrate_h:
                print(f"  Hambre media grupo → MIGRATE: {_mean(migrate_h):.2f}")

            sizes = [e["data"]["size"] for e in goal_changes if "size" in e["data"]]
            if sizes:
                print(f"  Tamaño medio al reevaluar   : {_mean(sizes):.1f}")
    else:
        print("  Sin log de grupos (requiere sesión con la versión actualizada del juego).")

    # ── Análisis desde action_change.group_id (funciona en todos los logs) ──
    sphere_group_counts: dict = {}   # id -> [ticks_en_grupo, ticks_total]
    for cat, events in data.items():
        if not cat.startswith("sphere_"):
            continue
        for e in events:
            if e["kind"] != "action_change":
                continue
            sid = e["data"].get("id")
            if sid is None:
                continue
            if sid not in sphere_group_counts:
                sphere_group_counts[sid] = [0, 0]
            sphere_group_counts[sid][1] += 1
            if e["data"].get("group_id", -1) != -1:
                sphere_group_counts[sid][0] += 1

    GROUPED_THRESHOLD = 0.3   # >30 % del tiempo en grupo = esfera "agrupada"

    grouped_profiles: list = []
    solo_profiles: list = []
    for sid, p in profiles.items():
        counts = sphere_group_counts.get(sid)
        if counts is None:
            continue
        frac = counts[0] / counts[1] if counts[1] > 0 else 0.0
        if frac > GROUPED_THRESHOLD:
            grouped_profiles.append(p)
        else:
            solo_profiles.append(p)

    def _grp_stats(lst: list) -> dict:
        dead = [p for p in lst if p["died"]]
        alive = [p for p in lst if not p["died"]]
        return {
            "total": len(lst),
            "survived": len(alive),
            "mean_age_dead": _mean([p["age_final"] for p in dead]),
            "mean_eats": _mean([p["eats"] for p in lst]),
            "hunger_deaths": sum(1 for p in dead if p.get("cause") == "hunger"),
            "dead": len(dead),
        }

    sg = _grp_stats(grouped_profiles)
    ss = _grp_stats(solo_profiles)

    print(f"\n  ── Agrupadas (>{int(GROUPED_THRESHOLD*100)}% del tiempo en grupo) vs Solitarias")
    print(f"  {'':30}  {'Agrupadas':>10}  {'Solitarias':>10}")
    print(f"  {hline('-', 56)}")
    print(f"  {'Individuos':30}  {sg['total']:>10}  {ss['total']:>10}")
    print(f"  {'Tasa supervivencia':30}  {pct(sg['survived'], sg['total']):>10}  {pct(ss['survived'], ss['total']):>10}")
    if sg["mean_age_dead"] > 0 and ss["mean_age_dead"] > 0:
        print(f"  {'Edad media al morir':30}  {sg['mean_age_dead']:>9.1f}s  {ss['mean_age_dead']:>9.1f}s")
    print(f"  {'Eats por individuo':30}  {sg['mean_eats']:>10.1f}  {ss['mean_eats']:>10.1f}")
    if sg["dead"] > 0 and ss["dead"] > 0:
        print(f"  {'Muertes por hambre (% muertos)':30}  {pct(sg['hunger_deaths'], sg['dead']):>10}  {pct(ss['hunger_deaths'], ss['dead']):>10}")

    # Composición por especie
    sp_grouped = collections.Counter(p["species"] for p in grouped_profiles)
    sp_solo = collections.Counter(p["species"] for p in solo_profiles)
    all_sp = sorted(set(list(sp_grouped.keys()) + list(sp_solo.keys())))
    if all_sp:
        print(f"\n  Composición por especie:")
        g_tot = sum(sp_grouped.values())
        s_tot = sum(sp_solo.values())
        for sp in all_sp:
            g_cnt = sp_grouped.get(sp, 0)
            s_cnt = sp_solo.get(sp, 0)
            print(f"    Especie {sp}: agrupadas={g_cnt} ({pct(g_cnt, g_tot)})  "
                  f"solitarias={s_cnt} ({pct(s_cnt, s_tot)})")

    # Tamaño de grupos (miembros únicos que han compartido el mismo group_id)
    group_members: dict = collections.defaultdict(set)
    for cat, events in data.items():
        if not cat.startswith("sphere_"):
            continue
        for e in events:
            if e["kind"] == "action_change":
                gid = e["data"].get("group_id", -1)
                sid = e["data"].get("id")
                if gid != -1 and sid is not None:
                    group_members[gid].add(sid)

    if group_members:
        sizes = sorted(len(v) for v in group_members.values())
        median_s = sizes[len(sizes) // 2]
        print(f"\n  Grupos únicos detectados: {len(group_members)}")
        print(f"  Tamaño (miembros únicos): "
              f"mín={sizes[0]}  mediana={median_s}  máx={sizes[-1]}")
        size_counter = collections.Counter(sizes)
        for sz in sorted(size_counter):
            b = bar(size_counter[sz], max(1, len(group_members) // 20))
            print(f"    {sz:2d} miembros: {size_counter[sz]:3d}  {b}")


# ─── interespecie ────────────────────────────────────────────────────────────

def analyze_interspecies(data: dict) -> None:
    section("DINÁMICA INTERESPECIE (huida y combate: misma vs otra especie)")

    # name→especie a partir de cualquier action_change.
    name_species: dict = {}
    for cat, events in data.items():
        if not cat.startswith("sphere_"):
            continue
        sp = cat.replace("sphere_", "")
        for e in events:
            n = e["data"].get("name")
            if n:
                name_species[n] = sp

    for action, label in (("flee", "HUIDAS"), ("fight", "COMBATES")):
        pairs: collections.Counter = collections.Counter()
        unknown = 0
        for cat, events in data.items():
            if not cat.startswith("sphere_"):
                continue
            sp = cat.replace("sphere_", "")
            for e in events:
                d = e["data"]
                if (e["kind"] == "action_change"
                        and d.get("new_action") == action and d.get("target")):
                    tsp = name_species.get(d["target"])
                    if tsp is None:
                        unknown += 1
                        continue
                    pairs[(sp, tsp)] += 1
        total = sum(pairs.values())
        if total == 0:
            print(f"\n  {label}: sin datos.")
            continue
        same = sum(v for (a, b), v in pairs.items() if a == b)
        other = total - same
        print(f"\n  {label} (total {total}):")
        for (a, b), v in sorted(pairs.items()):
            tag = "misma" if a == b else "otra"
            print(f"    {a}→{b} ({tag:<5}) {v:5d}  {pct(v, total):>6}  "
                  f"{bar(v, max(1, total // 30))}")
        extra = f"  (target desconocido: {unknown})" if unknown else ""
        print(f"    → misma especie {pct(same, total)}  |  "
              f"otra especie {pct(other, total)}{extra}")


# ─── evolución genética ──────────────────────────────────────────────────────

def analyze_genetic_drift(data: dict, profiles: dict) -> None:
    section("EVOLUCIÓN GENÉTICA — DERIVA DE RASGOS POR GENERACIÓN")

    valid = [p for p in profiles.values() if p["genome"]]
    if len(valid) < 20:
        print("  Datos insuficientes para análisis genético.")
        return

    cohorts = [(1, 1), (2, 5), (6, 10), (11, 15), (16, 9999)]
    for sp in sorted({p["species"] for p in valid}):
        sp_p = [p for p in valid if p["species"] == sp]
        max_gen = max(p["generation"] for p in sp_p)
        print(f"\n  ── Especie {sp}  (gen_max={max_gen}, N={len(sp_p)})")
        print(f"  {'cohorte':<9}{'N':>5}   {'metab':>6}{'size':>7}{'speed':>7}"
              f"{'vision':>8}{'longev':>8}{'aggr':>7}{'soc':>6}")
        print(f"  {hline('-', 64)}")
        for lo, hi in cohorts:
            grp = [p for p in sp_p if lo <= p["generation"] <= hi]
            if not grp:
                continue

            def gm(k: str) -> float:
                return _mean([float(p["genome"].get(k, 0.0)) for p in grp])

            lbl = f"gen{lo}" if lo == hi else f"g{lo}-{'+' if hi > 1000 else hi}"
            print(f"  {lbl:<9}{len(grp):>5}   {gm('metabolism'):>6.2f}{gm('size'):>7.2f}"
                  f"{gm('speed'):>7.2f}{gm('vision'):>8.1f}{gm('longevity'):>8.0f}"
                  f"{gm('aggression'):>7.2f}{gm('sociability'):>6.2f}")
        # Tendencia direccional generación → rasgo.
        gens = [p["generation"] for p in sp_p]
        print(f"     Tendencia (correlación generación→rasgo):")
        for t in PHYS_KEYS:
            vals = [float(p["genome"].get(t, 0.0)) for p in sp_p]
            r = _pearson(gens, vals)
            fd = FITNESS_DIR.get(t, 0)
            arrow = "↑" if r > 0.10 else ("↓" if r < -0.10 else "~")
            verdict = ""
            if abs(r) > 0.10 and fd != 0:
                good = (r > 0 and fd > 0) or (r < 0 and fd < 0)
                verdict = "  ✓ hacia mejor fitness" if good else "  ⚠ hacia peor fitness"
            print(f"       {t:<12} r={r:+.2f} {arrow}{verdict}")


def analyze_genome_selection(data: dict, profiles: dict) -> None:
    section("EVOLUCIÓN GENÉTICA — FUNDADORES vs SUPERVIVIENTES vs MUERTOS-HAMBRE")

    valid = [p for p in profiles.values() if p["genome"]]
    founders = [p for p in valid if p["generation"] == 1]
    survivors = [p for p in valid if not p["died"]]
    hunger = [p for p in valid if p["cause"] == "hunger"]
    if not (founders and survivors):
        print("  Datos insuficientes (¿log antiguo sin id/genome?).")
        return

    print(f"  Fundadores N={len(founders)}  Supervivientes N={len(survivors)}  "
          f"Muertos-hambre N={len(hunger)}")
    print(f"\n  {'rasgo':<12}{'fundadores':>12}{'supervivientes':>16}"
          f"{'muertos-hambre':>16}   señal selección")
    print(f"  {hline('-', 76)}")
    for t in PHYS_KEYS:
        f = _mean([float(p["genome"].get(t, 0.0)) for p in founders])
        s = _mean([float(p["genome"].get(t, 0.0)) for p in survivors])
        h = _mean([float(p["genome"].get(t, 0.0)) for p in hunger]) if hunger else 0.0
        fd = FITNESS_DIR.get(t, 0)
        delta = s - f
        lo, hi = TRAIT_RANGES.get(t, (0.0, 1.0))
        rng = hi - lo
        sig = ""
        if fd and abs(delta) > 0.03 * rng:
            good = (delta > 0 and fd > 0) or (delta < 0 and fd < 0)
            sig = "✓ selección favorable" if good else "⚠ deriva adversa"
        print(f"  {t:<12}{f:>12.2f}{s:>16.2f}{h:>16.2f}   {sig}")


def analyze_mutations(data: dict, profiles: dict) -> None:
    section("EVOLUCIÓN GENÉTICA — MUTACIONES (cría vs media parental)")

    # name→genome para casar padres. El pool de nombres se repite, así que la
    # magnitud es indicativa, no exacta (colisiones de nombre inflan la desviación).
    name_genome: dict = {}
    for p in profiles.values():
        if p["genome"] and p["name"] not in name_genome:
            name_genome[p["name"]] = p["genome"]

    births = [e["data"] for cat, events in data.items()
              if cat.startswith("sphere_")
              for e in events if e["kind"] == "birth"]

    devs: dict = collections.defaultdict(list)
    direction: collections.Counter = collections.Counter()
    matched = 0
    for b in births:
        child = profiles.get(b.get("id"), {}).get("genome")
        pa = name_genome.get(b.get("parent_a"))
        pb = name_genome.get(b.get("parent_b"))
        if not (child and pa and pb):
            continue
        matched += 1
        for t in ALL_TRAIT_KEYS:
            mid = (float(pa.get(t, 0.0)) + float(pb.get(t, 0.0))) / 2.0
            d = float(child.get(t, 0.0)) - mid
            lo, hi = TRAIT_RANGES.get(t, (0.0, 1.0))
            rng = (hi - lo) if t in PHYS_KEYS else 1.0
            devs[t].append(abs(d) / rng)
            fd = FITNESS_DIR.get(t, 0)
            if fd and abs(d) / rng > 0.02:
                if (d > 0 and fd > 0) or (d < 0 and fd < 0):
                    direction["better"] += 1
                else:
                    direction["worse"] += 1

    print(f"  Nacimientos: {len(births)}  ·  con ambos padres casados por nombre: {matched}")
    if matched == 0:
        print("  Sin padres casables (¿log sin nombres en action_change?).")
        return
    print(f"  Modelo: cada cría muta los {len(ALL_TRAIT_KEYS)} rasgos con ruido "
          f"gaussiano N(0, σ), σ base {MUTATION_BASE_SIGMA}.")
    print(f"  Eventos de mutación ≈ {matched * len(ALL_TRAIT_KEYS)} (no hay 'mutación sí/no').")
    print(f"\n  {'rasgo':<22}{'|desv| media (norm)':>20}{'σ esperada':>14}")
    print(f"  {hline('-', 56)}")
    for t in ALL_TRAIT_KEYS:
        if not devs[t]:
            continue
        expected = MUTATION_BASE_SIGMA if t in PHYS_KEYS else MUTATION_BASE_SIGMA * 0.5
        print(f"  {t:<22}{_mean(devs[t]):>20.3f}{expected:>14.3f}")
    tot = direction["better"] + direction["worse"]
    if tot:
        print(f"\n  Dirección de las mutaciones apreciables (vs fitness empírico):")
        print(f"    A mejor : {direction['better']:5d}  ({pct(direction['better'], tot)})")
        print(f"    A peor  : {direction['worse']:5d}  ({pct(direction['worse'], tot)})")
        print(f"  Nota: la mutación es simétrica por diseño (~50/50). La mejora del")
        print(f"  acervo proviene de la SELECCIÓN, no de un sesgo mutacional.")


def analyze_territory(data: dict) -> None:
    section("TERRITORIO — DOMINIO Y FRONTERAS")

    snaps = [e for e in data.get("territory", []) if e["kind"] == "territory_snapshot"]
    if not snaps:
        print("  Sin datos de territorio (requiere sesión con la versión actualizada del juego).")
        return

    snaps.sort(key=lambda e: e.get("tick", 0))
    t0 = snaps[0].get("t_sim", 0.0)
    t1 = snaps[-1].get("t_sim", 0.0)
    print(f"  Snapshots: {len(snaps)}  ·  ventana sim: {t0:.0f}s → {t1:.0f}s")

    # Especies que dominaron alguna celda en algún momento.
    species = sorted({sp for e in snaps for sp in e["data"].get("species", {}).keys()})

    # ── Evolución: celdas dominadas por especie + zonas en disputa ──
    print(f"\n  Evolución (celdas dominadas por especie · disputa):")
    print("    t_sim   ocupadas  disputa  " + "  ".join(f"{sp:>5}" for sp in species))
    n = len(snaps)
    step = max(1, n // 10)
    for i in range(0, n, step):
        d = snaps[i]["data"]
        sp = d.get("species", {})
        cells = "  ".join(f"{sp.get(s, {}).get('cells', 0):>5}" for s in species)
        print(f"    {snaps[i].get('t_sim', 0):>5.0f}   {d.get('occupied_cells', 0):>7}  "
              f"{d.get('contested_cells', 0):>6}   {cells}")

    # ── Estado final: reparto, fuerza media, área ──
    last = snaps[-1]["data"]
    occ = last.get("occupied_cells", 0)
    area_cell = last.get("cell_size", 0.0) ** 2
    print(f"\n  Estado final (t={t1:.0f}s):")
    print(f"    Celdas ocupadas : {occ}  (~{occ * area_cell:.0f} u² de territorio)")
    print(f"    En disputa      : {last.get('contested_cells', 0)}  "
          f"({pct(last.get('contested_cells', 0), occ)} de las ocupadas)")
    for s in species:
        si = last.get("species", {}).get(s)
        if not si:
            continue
        print(f"    Especie {s:<3}    : {si.get('cells', 0):>4} celdas "
              f"({pct(si.get('cells', 0), occ)})  fuerza media {si.get('strength_avg', 0.0):.2f}")

    # ── Grupos con más territorio (último snapshot) ──
    tg = last.get("top_groups", [])
    if tg:
        print(f"\n  Grupos con más territorio (final):")
        for g in tg:
            print(f"    grupo {g.get('group'):>4}  ·  {g.get('cells', 0):>3} celdas  "
                  f"·  influencia {g.get('influence', 0.0):.1f}")


# ─── main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    log_dir = find_log_dir()

    if "--list" in sys.argv:
        sessions = list_sessions(log_dir)
        print("Sesiones disponibles:")
        for s in sessions:
            print(f"  {s}")
        return

    sessions = list_sessions(log_dir)
    if not sessions:
        sys.exit("No se encontraron sesiones en el directorio de logs.")

    # Seleccionar sesión
    if len(sys.argv) > 1 and not sys.argv[1].startswith("--"):
        prefix_arg = sys.argv[1]
        matches = [s for s in sessions if s.startswith(prefix_arg)]
        if not matches:
            sys.exit(f"No se encontró sesión con prefijo '{prefix_arg}'")
        session = matches[-1]
    else:
        session = sessions[-1]

    print(f"\n{'═' * 60}")
    print(f"  BioSphera — Análisis de sesión")
    print(f"  {session}")
    print(f"{'═' * 60}")

    data = load_session(log_dir, session)
    if not data:
        sys.exit("No se cargaron datos. Verifica el prefijo de sesión.")

    loaded = ", ".join(f"{k}({len(v)})" for k, v in sorted(data.items()))
    print(f"\n  Archivos cargados: {loaded}")

    profiles = build_sphere_profiles(data)

    analyze_population(data)
    analyze_gravity_bug(data)
    analyze_actions(data)
    analyze_eat_timeline(data)
    analyze_plants(data)
    analyze_combat(data)
    analyze_interspecies(data)
    analyze_flee_targets(data)
    analyze_deaths_detail(data)
    analyze_early_deaths(data, profiles=profiles)
    analyze_population_over_time(data)
    analyze_survivors(data)
    # ── Diagnóstico conductual ──
    analyze_species_behavior(data)
    analyze_genome_action_correlation(data)
    analyze_survival_factors(data)
    analyze_action_coherence(data)
    analyze_notable_individuals(data)
    analyze_groups(data, profiles)
    analyze_territory(data)
    # ── Evolución genética ──
    analyze_genetic_drift(data, profiles)
    analyze_genome_selection(data, profiles)
    analyze_mutations(data, profiles)

    print(f"\n{'═' * 60}\n")


if __name__ == "__main__":
    main()
