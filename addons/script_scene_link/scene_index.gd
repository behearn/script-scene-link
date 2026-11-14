@tool
extends RefCounted

var _scenes_by_script: Dictionary = {}

var _ext_resource := RegEx.new()
var _script_assignment := RegEx.new()
var _quoted_attribute := RegEx.new()
var _bare_attribute := RegEx.new()


func _init() -> void:
	_compile(_ext_resource, "\\[ext_resource\\s+([^\\]]+)\\]")
	_compile(_script_assignment, "(?m)^[ \\t]*script[ \\t]*=[ \\t]*ExtResource\\([ \\t]*\"?([^\"\\)\\s]+)\"?[ \\t]*\\)")
	_compile(_quoted_attribute, "(\\w+)\\s*=\\s*\"([^\"]*)\"")
	_compile(_bare_attribute, "(\\w+)\\s*=\\s*([^\\s\"\\]]+)")


func rebuild(filesystem) -> void:
	_scenes_by_script.clear()
	if filesystem == null:
		return
	var root = filesystem.get_filesystem()
	if root == null:
		return
	_walk(root)


func index_scene(scene_path: String) -> void:
	if scene_path.ends_with(".tscn"):
		_index_tscn(scene_path)
	elif scene_path.ends_with(".scn"):
		_index_binary(scene_path)


func scenes_for_script(script_path: String) -> PackedStringArray:
	var ordered: Array[String] = []
	var seen := {}
	_append_unique(ordered, seen, script_path)
	if script_path.begins_with("res://"):
		var uid := ResourceLoader.get_resource_uid(script_path)
		if uid != ResourceUID.INVALID_ID:
			_append_unique(ordered, seen, ResourceUID.id_to_text(uid))
	return PackedStringArray(ordered)


func choose_scene(scenes: PackedStringArray, recent_scenes: PackedStringArray) -> String:
	for recent in recent_scenes:
		if scenes.has(recent):
			return recent
	var best := ""
	var best_time := -1
	for scene_path in scenes:
		var modified := int(FileAccess.get_modified_time(scene_path))
		if modified > best_time:
			best_time = modified
			best = scene_path
	return best


func note_file_moved(old_path: String, new_path: String) -> void:
	if _scenes_by_script.has(old_path):
		var merged: Array = _scenes_by_script.get(new_path, [])
		for scene_path in _scenes_by_script[old_path]:
			if scene_path not in merged:
				merged.append(scene_path)
		_scenes_by_script[new_path] = merged
		_scenes_by_script.erase(old_path)
	for key in _scenes_by_script.keys():
		var scenes: Array = _scenes_by_script[key]
		for index in scenes.size():
			if scenes[index] == old_path:
				scenes[index] = new_path


func attached_scripts_in_text(text: String) -> PackedStringArray:
	var ordered: Array[String] = []
	var seen := {}
	for info in _attached_in_text(text):
		var script_path: String = info["path"]
		if seen.has(script_path):
			continue
		seen[script_path] = true
		ordered.append(script_path)
	return PackedStringArray(ordered)


func script_from_dependency(dependency: String) -> Dictionary:
	var slices := dependency.split("::")
	var type := ""
	var path := ""
	var uid_text := ""
	if slices.size() >= 3:
		uid_text = slices[0]
		type = slices[1]
		path = slices[2]
	elif slices.size() == 2:
		if slices[1].begins_with("res://") or slices[1].begins_with("uid://"):
			uid_text = slices[0]
			path = slices[1]
		else:
			path = slices[0]
			type = slices[1]
	elif slices.size() == 1:
		path = slices[0]
	if not type.is_empty() and type != "Script":
		return {}
	if path.begins_with("uid://"):
		uid_text = path
		path = ""
	if not uid_text.begins_with("uid://"):
		uid_text = ""
	var resolved := _resolve_script_path(path, uid_text)
	if type != "Script" and not resolved.ends_with(".gd"):
		return {}
	if not resolved.ends_with(".gd"):
		return {}
	return {"path": resolved, "uid": uid_text}


func _walk(directory) -> void:
	for index in directory.get_file_count():
		index_scene(directory.get_file_path(index))
	for index in directory.get_subdir_count():
		_walk(directory.get_subdir(index))


func _index_tscn(scene_path: String) -> void:
	var text := FileAccess.get_file_as_string(scene_path)
	if text.is_empty():
		return
	var seen := {}
	for info in _attached_in_text(text):
		var script_path: String = info["path"]
		if seen.has(script_path):
			continue
		seen[script_path] = true
		_remember_attachment(script_path, str(info["uid"]), scene_path)


func _index_binary(scene_path: String) -> void:
	var seen := {}
	for dependency in ResourceLoader.get_dependencies(scene_path):
		var info := script_from_dependency(dependency)
		if info.is_empty():
			continue
		var script_path: String = info["path"]
		if seen.has(script_path):
			continue
		seen[script_path] = true
		_remember_attachment(script_path, str(info["uid"]), scene_path)


func _attached_in_text(text: String) -> Array:
	var id_to_script := {}
	for ext_match in _ext_resource.search_all(text):
		var attributes := _attributes(ext_match.get_string(1))
		if str(attributes.get("type", "")) != "Script":
			continue
		var id := str(attributes.get("id", ""))
		if id.is_empty():
			continue
		var path := str(attributes.get("path", ""))
		var uid_text := str(attributes.get("uid", ""))
		var resolved := _resolve_script_path(path, uid_text)
		if not resolved.ends_with(".gd"):
			continue
		id_to_script[id] = {"path": resolved, "uid": uid_text}
	var attached: Array = []
	for assign_match in _script_assignment.search_all(text):
		var id := assign_match.get_string(1)
		if not id_to_script.has(id):
			continue
		attached.append(id_to_script[id])
	return attached


func _attributes(body: String) -> Dictionary:
	var attributes := {}
	for matched in _quoted_attribute.search_all(body):
		attributes[matched.get_string(1)] = matched.get_string(2)
	for matched in _bare_attribute.search_all(body):
		var key := matched.get_string(1)
		if not attributes.has(key):
			attributes[key] = matched.get_string(2)
	return attributes


func _resolve_script_path(path: String, uid_text: String) -> String:
	if uid_text.begins_with("uid://"):
		var uid := ResourceUID.text_to_id(uid_text)
		if uid != ResourceUID.INVALID_ID and ResourceUID.has_id(uid):
			var resolved := ResourceUID.get_id_path(uid)
			if resolved.ends_with(".gd"):
				return resolved
	return path


func _remember_attachment(script_path: String, uid_text: String, scene_path: String) -> void:
	_add(script_path, scene_path)
	if uid_text.begins_with("uid://"):
		_add(uid_text, scene_path)


func _add(script_key: String, scene_path: String) -> void:
	if script_key.is_empty():
		return
	var scenes: Array = _scenes_by_script.get(script_key, [])
	if scene_path not in scenes:
		scenes.append(scene_path)
		_scenes_by_script[script_key] = scenes


func _append_unique(ordered: Array, seen: Dictionary, key: String) -> void:
	if key.is_empty():
		return
	for scene_path in _scenes_by_script.get(key, []):
		var path := str(scene_path)
		if seen.has(path):
			continue
		seen[path] = true
		ordered.append(path)


func _compile(expression: RegEx, pattern: String) -> void:
	if expression.compile(pattern) != OK:
		push_error("Script Scene Link failed to compile a scene scan expression.")
