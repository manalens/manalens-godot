@tool
extends EditorPlugin

## Adds the UntitledAnalytics autoload when the plugin is enabled and removes it
## when the plugin is disabled.

const AUTOLOAD_NAME := "UntitledAnalytics"


func _enable_plugin() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, "res://addons/untitled_analytics/untitled_analytics.gd")


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
