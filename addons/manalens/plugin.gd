@tool
extends EditorPlugin

## Adds the Manalens autoload when the plugin is enabled and removes it
## when the plugin is disabled. Adds the Manalens section of Project Settings
## and the Manalens dock.

const AUTOLOAD_NAME := "Manalens"
const Settings := preload("res://addons/manalens/settings.gd")
const Dock := preload("res://addons/manalens/dock.gd")

var _dock: Control


func _enable_plugin() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, "res://addons/manalens/manalens.gd")


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)


func _enter_tree() -> void:
	if Settings.register():
		ProjectSettings.save()
	_dock = Dock.new()
	_dock.editor_settings = get_editor_interface().get_editor_settings()
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)


func _exit_tree() -> void:
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
