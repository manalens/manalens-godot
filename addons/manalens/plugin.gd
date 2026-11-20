@tool
extends EditorPlugin

## Adds the Manalens autoload when the plugin is enabled and removes it
## when the plugin is disabled.

const AUTOLOAD_NAME := "Manalens"


func _enable_plugin() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, "res://addons/manalens/manalens.gd")


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
