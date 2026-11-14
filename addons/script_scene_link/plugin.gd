@tool
extends EditorPlugin

const SceneIndex = preload("res://addons/script_scene_link/scene_index.gd")
const _DOMINANT_SCRIPT_SETTING := "text_editor/behavior/files/open_dominant_script_on_scene_change"
const _MAIN_SCREEN_NAMES: PackedStringArray = ["2D", "3D", "Script", "Game", "AssetLib"]
const _RECENT_LIMIT := 64

var _index = null
var _recent_scenes := PackedStringArray()
var _main_screen := ""
var _suppress_depth := 0
var _syncing_from_script := false
var _rebuild_queued := false
var _bindings: Array[Dictionary] = []
var _history_shortcuts: Array[Shortcut] = []
var _script_path_last_frame := ""


func _enter_tree() -> void:
	_index = SceneIndex.new()
	scene_changed.connect(_on_scene_changed)
	main_screen_changed.connect(_on_main_screen_changed)
	_connect_editor_signals()
	_detect_main_screen()
	_remember_current_scene()
	_queue_rebuild()
	_detect_main_screen.call_deferred()
	set_process(true)
	set_process_input(true)


func _exit_tree() -> void:
	_unbind_all()
	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)
	if main_screen_changed.is_connected(_on_main_screen_changed):
		main_screen_changed.disconnect(_on_main_screen_changed)
	_syncing_from_script = false
	_suppress_depth = 0
	_rebuild_queued = false
	_history_shortcuts.clear()
	set_process(false)
	set_process_input(false)


func _get_window_layout(configuration: ConfigFile) -> void:
	configuration.set_value("script_scene_link", "recent_scenes", _recent_scenes)


func _set_window_layout(configuration: ConfigFile) -> void:
	if configuration.has_section_key("script_scene_link", "recent_scenes"):
		var stored = configuration.get_value("script_scene_link", "recent_scenes")
		var loaded := PackedStringArray()
		if stored is PackedStringArray:
			loaded = stored
		elif stored is Array:
			for item in stored:
				if item is String and not str(item).is_empty():
					loaded.append(item)
		_recent_scenes = loaded
	_remember_current_scene()


func _connect_editor_signals() -> void:
	var interface := get_editor_interface()
	var filesystem = interface.get_resource_filesystem()
	if filesystem:
		_bind_signal(filesystem, "filesystem_changed", _on_filesystem_changed)
	var dock := interface.get_file_system_dock()
	if dock:
		_bind_signal(dock, "files_moved", _on_files_moved)
		_connect_filesystem_activation(dock)
	var script_editor := interface.get_script_editor()
	if script_editor:
		_connect_history_buttons(script_editor)
		_connect_script_files_panel(script_editor)


func _connect_filesystem_activation(node: Node) -> void:
	# Create-resource and dependency dialogs are parented to this dock and have
	# their own trees. Only the file list and directory tree open scripts.
	if not _is_dock_dialog(node):
		if node is ItemList:
			_bind_signal(node, "item_activated", _on_file_list_activated.bind(node))
		elif node is Tree:
			_bind_signal(node, "item_activated", _on_tree_activated.bind(node))
	for child in node.get_children():
		_connect_filesystem_activation(child)


func _is_dock_dialog(node: Node) -> bool:
	var dock := get_editor_interface().get_file_system_dock()
	var current := node.get_parent()
	while current and current != dock:
		if current is Window:
			return true
		current = current.get_parent()
	return false


func _connect_history_buttons(node: Node) -> void:
	if node is Button and _is_history_button(node):
		var history_button := node as Button
		if history_button.shortcut and history_button.shortcut not in _history_shortcuts:
			_history_shortcuts.append(history_button.shortcut)
		_bind_signal(history_button, "pressed", _on_history_pressed, CONNECT_DEFERRED)
	for child in node.get_children():
		_connect_history_buttons(child)


func _connect_script_files_panel(script_editor: Node) -> void:
	var script_list := _find_script_list(script_editor)
	if script_list == null:
		push_warning("Script Scene Link could not find the script editor Files panel.")
		return
	_bind_signal(script_list, "item_clicked", _on_script_list_clicked, CONNECT_DEFERRED)
	_bind_signal(script_list, "gui_input", _on_script_list_gui_input, CONNECT_DEFERRED)


func _find_script_list(node: Node) -> ItemList:
	if node is VSplitContainer and node.get_child_count() > 0:
		var top := node.get_child(0)
		if top is VBoxContainer:
			var list := _script_list_in_box(top)
			if list:
				return list
	for child in node.get_children():
		var found := _find_script_list(child)
		if found:
			return found
	return null


func _script_list_in_box(box: VBoxContainer) -> ItemList:
	var has_filter := false
	var list: ItemList = null
	for child in box.get_children():
		if child is LineEdit:
			has_filter = true
		elif child is ItemList and child.theme_type_variation == "ItemListSecondary" and list == null:
			list = child
	if has_filter and list:
		return list
	return null


func _bind_signal(source: Object, signal_name: String, callback: Callable, flags: int = 0) -> void:
	var editor_signal := Signal(source, signal_name)
	if editor_signal.is_connected(callback):
		return
	editor_signal.connect(callback, flags)
	_bindings.append({
		"source": source,
		"signal": signal_name,
		"callback": callback,
	})


func _unbind_all() -> void:
	for binding in _bindings:
		var source = binding["source"]
		if not is_instance_valid(source):
			continue
		var editor_signal := Signal(source, binding["signal"])
		var callback: Callable = binding["callback"]
		if editor_signal.is_connected(callback):
			editor_signal.disconnect(callback)
	_bindings.clear()


func _on_filesystem_changed() -> void:
	_queue_rebuild()


func _on_files_moved(old_file: String, new_file: String) -> void:
	if _index:
		_index.note_file_moved(old_file, new_file)
	for index in _recent_scenes.size():
		if _recent_scenes[index] == old_file:
			_recent_scenes[index] = new_file


func _queue_rebuild() -> void:
	if _rebuild_queued:
		return
	_rebuild_queued = true
	_rebuild_index.call_deferred()


func _rebuild_index() -> void:
	_rebuild_queued = false
	if not is_inside_tree() or _index == null:
		return
	var filesystem = get_editor_interface().get_resource_filesystem()
	if filesystem == null or filesystem.is_scanning():
		return
	_index.rebuild(filesystem)


func _on_file_list_activated(index: int, file_list: ItemList) -> void:
	var metadata = file_list.get_item_metadata(index)
	if metadata is String:
		_on_filesystem_path_activated(metadata)


func _on_tree_activated(tree: Tree) -> void:
	var selected := tree.get_selected()
	if selected == null:
		return
	var metadata = selected.get_metadata(0)
	if metadata is String:
		_on_filesystem_path_activated(metadata)


func _on_filesystem_path_activated(path: String) -> void:
	if _sync_blocked():
		return
	if path.ends_with(".gd"):
		var script = load(path)
		if script is GDScript:
			_sync_scene_for_script(script)
		return
	# Opening a scene from the FileSystem does not leave the Script screen, and
	# the dominant-script setting will not select a tab while the scene is changing.
	if _main_screen == "Script" and (path.ends_with(".tscn") or path.ends_with(".scn")):
		_open_script_for_scene_file.call_deferred(path)


func _process(_delta: float) -> void:
	if not is_inside_tree():
		return
	var script_editor := get_editor_interface().get_script_editor()
	var current_script := script_editor.get_current_script() if script_editor else null
	_script_path_last_frame = current_script.resource_path if current_script else ""


func _on_script_list_clicked(_index: int, _at_position: Vector2, mouse_button: int) -> void:
	if mouse_button != MOUSE_BUTTON_LEFT:
		return
	_sync_current_script()


func _on_script_list_gui_input(event: InputEvent) -> void:
	if _is_script_list_navigation(event):
		_sync_current_script()


func _open_script_for_scene_file(scene_path: String) -> void:
	if _sync_blocked() or not is_inside_tree() or _main_screen != "Script":
		return
	var script := _root_gdscript(scene_path)
	if script == null:
		return
	var current := get_editor_interface().get_script_editor().get_current_script()
	if current and current.resource_path == script.resource_path:
		return
	# This script may belong to other scenes. Keep the scene that was just opened.
	_suppress_depth += 1
	get_editor_interface().edit_script(script, -1, 0, true)
	get_editor_interface().set_main_screen_editor("Script")
	_release_suppress()


func _root_gdscript(scene_path: String) -> GDScript:
	var root := get_editor_interface().get_edited_scene_root()
	if root == null or root.scene_file_path != scene_path:
		return null
	var attached = root.get_script()
	if not attached is GDScript:
		return null
	var script := attached as GDScript
	var script_path := script.resource_path
	if script_path.begins_with("res://") and script_path.ends_with(".gd"):
		return script
	return null


func _sync_current_script() -> void:
	if _sync_blocked() or not is_inside_tree():
		return
	var script := get_editor_interface().get_script_editor().get_current_script()
	if script is GDScript:
		_sync_scene_for_script(script)


func _on_history_pressed() -> void:
	_sync_current_script()


func _input(event: InputEvent) -> void:
	if not _is_history_navigation_event(event):
		return
	var script_editor := get_editor_interface().get_script_editor()
	if script_editor == null or not script_editor.is_visible_in_tree():
		return
	# Captured before this frame's history step. Input order between this plugin
	# and the script editor is not fixed, so the live current script may already
	# be the destination.
	_sync_if_script_changed.call_deferred(_script_path_last_frame)


func _sync_if_script_changed(previous_path: String) -> void:
	if _sync_blocked() or not is_inside_tree():
		return
	var script := get_editor_interface().get_script_editor().get_current_script()
	if script == null or not script is GDScript or script.resource_path == previous_path:
		return
	_sync_scene_for_script(script)


func _is_history_navigation_event(event: InputEvent) -> bool:
	if not event.is_pressed() or event.is_echo():
		return false
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		return mouse_event.button_index == MOUSE_BUTTON_XBUTTON1 or mouse_event.button_index == MOUSE_BUTTON_XBUTTON2
	for shortcut in _history_shortcuts:
		if shortcut and shortcut.matches_event(event):
			return true
	return false


func _is_script_list_navigation(event: InputEvent) -> bool:
	return event.is_action_pressed("ui_up") \
		or event.is_action_pressed("ui_down") \
		or event.is_action_pressed("ui_page_up") \
		or event.is_action_pressed("ui_page_down") \
		or event.is_action_pressed("ui_home") \
		or event.is_action_pressed("ui_end") \
		or event.is_action_pressed("ui_accept")


func _sync_blocked() -> bool:
	return _suppress_depth > 0 or _syncing_from_script


func _sync_scene_for_script(script: Script) -> void:
	if _sync_blocked() or _index == null:
		return
	var script_path := script.resource_path
	if script_path.is_empty() or not script_path.ends_with(".gd"):
		return
	var scenes: PackedStringArray = _index.scenes_for_script(script_path)
	if scenes.is_empty():
		return
	var chosen: String = _index.choose_scene(scenes, _recent_scenes)
	if chosen.is_empty():
		return
	var root := get_editor_interface().get_edited_scene_root()
	if root and root.scene_file_path == chosen:
		return
	_show_scene_for_script(chosen, script)


func _show_scene_for_script(scene_path: String, script: Script) -> void:
	# Scene changes read the dominant-script setting immediately. Hold it off so
	# the script the user just opened is not replaced, and so this scene change
	# does not open that root script through the 2D/3D path.
	_syncing_from_script = true
	var settings := get_editor_interface().get_editor_settings()
	var had_setting := settings.has_setting(_DOMINANT_SCRIPT_SETTING)
	var previous = false
	if had_setting:
		previous = settings.get_setting(_DOMINANT_SCRIPT_SETTING)
		settings.set_setting(_DOMINANT_SCRIPT_SETTING, false)
	_activate_scene(scene_path)
	if had_setting:
		settings.set_setting(_DOMINANT_SCRIPT_SETTING, previous)
	_finish_script_sync.call_deferred(script)


func _activate_scene(scene_path: String) -> void:
	var interface := get_editor_interface()
	var root := interface.get_edited_scene_root()
	if root and root.scene_file_path == scene_path:
		return
	# open_scene_from_path selects an already-open scene. Guessing the TabBar
	# index does not: another bar can have the same tab count, so a later visit
	# to a script left the previous scene current.
	interface.open_scene_from_path(scene_path)
	root = interface.get_edited_scene_root()
	if root and root.scene_file_path == scene_path:
		return
	var open_scenes := interface.get_open_scenes()
	var scene_index := open_scenes.find(scene_path)
	if scene_index == -1:
		return
	var tab_bar := _find_scene_tab_bar()
	if tab_bar and scene_index < tab_bar.tab_count and tab_bar.current_tab != scene_index:
		tab_bar.current_tab = scene_index


func _finish_script_sync(script: Script) -> void:
	if not is_inside_tree():
		_syncing_from_script = false
		return
	if is_instance_valid(script):
		var current := get_editor_interface().get_script_editor().get_current_script()
		if current == null or current.resource_path != script.resource_path:
			_suppress_depth += 1
			get_editor_interface().edit_script(script, -1, 0, false)
			_suppress_depth -= 1
	get_editor_interface().set_main_screen_editor("Script")
	await get_tree().process_frame
	if is_inside_tree():
		get_editor_interface().set_main_screen_editor("Script")
	_syncing_from_script = false


func _on_scene_changed(root: Node) -> void:
	if root and not root.scene_file_path.is_empty():
		_remember_scene(root.scene_file_path)
	if _syncing_from_script or (_main_screen != "2D" and _main_screen != "3D"):
		return
	if root == null:
		return
	var attached = root.get_script()
	if not attached is GDScript:
		return
	var script := attached as GDScript
	var script_path := script.resource_path
	if not script_path.begins_with("res://") or not script_path.ends_with(".gd"):
		return
	var current := get_editor_interface().get_script_editor().get_current_script()
	if current and current.resource_path == script_path:
		return
	# edit_script ignores an already-open tab while a scene change is in progress.
	_suppress_depth += 1
	_open_root_script.call_deferred(script, _main_screen)


func _open_root_script(script: Script, screen: String) -> void:
	if not is_inside_tree():
		_release_suppress()
		return
	if is_instance_valid(script):
		var current := get_editor_interface().get_script_editor().get_current_script()
		if current == null or current.resource_path != script.resource_path:
			get_editor_interface().edit_script(script, -1, 0, true)
	if screen == "2D" or screen == "3D":
		get_editor_interface().set_main_screen_editor(screen)
	await get_tree().process_frame
	if is_inside_tree() and (screen == "2D" or screen == "3D") and _main_screen != screen:
		get_editor_interface().set_main_screen_editor(screen)
	_release_suppress()


func _release_suppress() -> void:
	_suppress_depth = maxi(_suppress_depth - 1, 0)


func _on_main_screen_changed(screen_name: String) -> void:
	_main_screen = screen_name


func _detect_main_screen() -> void:
	if not is_inside_tree():
		return
	var pressed := _find_pressed_main_screen(get_editor_interface().get_base_control())
	if not pressed.is_empty():
		_main_screen = pressed
		return
	var interface := get_editor_interface()
	if interface.get_script_editor() and interface.get_script_editor().is_visible_in_tree():
		_main_screen = "Script"
	elif _is_editor_view_visible(interface.get_editor_viewport_2d()):
		_main_screen = "2D"
	elif _is_editor_view_visible(interface.get_editor_viewport_3d()):
		_main_screen = "3D"


func _find_pressed_main_screen(node: Node) -> String:
	if node is Button and (node as Button).toggle_mode and (node as Button).button_pressed:
		var screen_name := _screen_name_from_button(node)
		if not screen_name.is_empty():
			return screen_name
	for child in node.get_children():
		var found := _find_pressed_main_screen(child)
		if not found.is_empty():
			return found
	return ""


func _screen_name_from_button(button: Button) -> String:
	if button.theme_type_variation != "MainScreenButton":
		return ""
	if _MAIN_SCREEN_NAMES.has(button.text):
		return button.text
	if _MAIN_SCREEN_NAMES.has(String(button.name)):
		return String(button.name)
	return ""


func _is_history_button(button: Button) -> bool:
	if button.shortcut == null or not button.text.is_empty():
		return false
	var alt_left := false
	var alt_right := false
	for event in button.shortcut.events:
		if not event is InputEventKey:
			continue
		var key_event := event as InputEventKey
		if key_event.ctrl_pressed or key_event.meta_pressed or key_event.shift_pressed or not key_event.alt_pressed:
			continue
		var keycode := key_event.keycode if key_event.keycode != KEY_NONE else key_event.physical_keycode
		if keycode == KEY_LEFT:
			alt_left = true
		elif keycode == KEY_RIGHT:
			alt_right = true
	return alt_left or alt_right


func _find_scene_tab_bar() -> TabBar:
	var matches: Array[TabBar] = []
	_collect_scene_tab_bars(get_editor_interface().get_base_control(), matches)
	if matches.is_empty():
		return null
	var open_count := get_editor_interface().get_open_scenes().size()
	for tab_bar in matches:
		if tab_bar.tab_count == open_count:
			return tab_bar
	return matches[0]


func _collect_scene_tab_bars(node: Node, matches: Array[TabBar]) -> void:
	if node is TabBar and _is_scene_tab_bar(node):
		matches.append(node)
	for child in node.get_children():
		_collect_scene_tab_bars(child, matches)


func _is_scene_tab_bar(tab_bar: TabBar) -> bool:
	if not _has_child_button(tab_bar):
		return false
	var parent := tab_bar.get_parent()
	return parent is HBoxContainer and _has_child_menu_button(parent)


func _has_child_button(node: Node) -> bool:
	for child in node.get_children():
		if child is Button:
			return true
	return false


func _has_child_menu_button(node: Node) -> bool:
	for child in node.get_children():
		if child is MenuButton:
			return true
	return false


func _remember_current_scene() -> void:
	if not is_inside_tree():
		return
	var root := get_editor_interface().get_edited_scene_root()
	if root:
		_remember_scene(root.scene_file_path)


func _remember_scene(scene_path: String) -> void:
	if scene_path.is_empty() or not scene_path.begins_with("res://"):
		return
	var updated := PackedStringArray()
	updated.append(scene_path)
	for existing in _recent_scenes:
		if existing == scene_path:
			continue
		updated.append(existing)
		if updated.size() >= _RECENT_LIMIT:
			break
	_recent_scenes = updated


func _is_editor_view_visible(node: Node) -> bool:
	var current := node
	while current:
		if current is CanvasItem:
			return (current as CanvasItem).is_visible_in_tree()
		current = current.get_parent()
	return false
