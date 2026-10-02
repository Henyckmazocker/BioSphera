class_name Main
extends Node
## Entry point del juego.
##
## El escenario de partida se elige en `StartScreen` (selector de presets, Fase
## 3.8), que vuelca el `SimPreset` elegido a `SimConfig` antes de cargar esta
## escena. Auto-cargar "Génesis" al abrir el juego es Fase 4.2.
