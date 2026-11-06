class_name BeehaveDebuggerMessages


# Godot独立运行和无头测试没有调试连接，只有活动连接才能发送调试协议消息。
static func can_send_message() -> bool:
	return not Engine.is_editor_hint() and OS.has_feature("editor") and EngineDebugger.is_active()


static func register_tree(beehave_tree: Dictionary) -> void:
	if can_send_message():
		EngineDebugger.send_message("beehave:register_tree", [beehave_tree])


static func unregister_tree(instance_id: int) -> void:
	if can_send_message():
		EngineDebugger.send_message("beehave:unregister_tree", [instance_id])


static func process_tick(instance_id: int, status: int, blackboard: Dictionary = {}) -> void:
	if can_send_message():
		EngineDebugger.send_message("beehave:process_tick", [instance_id, status, blackboard])

static func process_interrupt(instance_id: int, blackboard: Dictionary = {}) -> void:
	if can_send_message():
		EngineDebugger.send_message("beehave:process_interrupt", [instance_id, blackboard])

static func process_begin(instance_id: int, blackboard: Dictionary = {}) -> void:
	if can_send_message():
		EngineDebugger.send_message("beehave:process_begin", [instance_id, blackboard])


static func process_end(instance_id: int, blackboard: Dictionary = {}) -> void:
	if can_send_message():
		EngineDebugger.send_message("beehave:process_end", [instance_id, blackboard])
