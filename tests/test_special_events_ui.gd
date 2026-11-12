extends "res://tests/test_single_player_ui.gd"
## 特殊事件界面：弹窗不暂停挂机、选项真实结算、稍后处理与记录页历史。

## 复用隔离启动与断言工具，替换为事件真实业务场景。
func _test_interface() -> void:
	var ui := Control.new()
	root.add_child(ui)
	ui.set_script(load("res://scripts/ui/main.gd"))
	ui.set_process(false)
	ui._build_theme()
	ui._build_interface()
	var configuration := GameConfig.new()
	if not _result(configuration.load_file(), "读取正式配置", configuration.error_message):
		ui.free()
		return
	# 事件组保留事件开启：本组正是验收事件界面。
	configuration.globals["event_chance"] = 1.0
	ui.configuration = configuration
	var pending_ui: Control = null
	var pending_seed: int = -1
	for seed_value in range(41501, 41541):
		if not _reset_session(ui, seed_value, 2, 28790.0):
			ui.free()
			return
		ui.simulation.event_auto.handled_key = ""
		ui.simulation.event_auto.fired_day = 0
		if not _result(ui.simulation.advance(20.0), "推进跨过第2天早晨 seed=%d" % seed_value, ui.simulation.error_message):
			ui.free()
			return
		if not ui.simulation.pending_event_for_player().is_empty():
			pending_ui = ui
			pending_seed = seed_value
			break
	if pending_ui == null:
		_check(false, "40个种子中未找到玩家归属事件局")
		ui.free()
		return
	if not await _test_event_dialog(ui):
		ui.free()
		return
	ui.free()


## 弹窗不暂停挂机：选项真实结算并写记录页；关闭可稍后处理。
func _test_event_dialog(ui: Control) -> bool:
	var ok: bool = true
	ok = _check(ui.event_dialog != null and ui.event_options_box != null, "事件弹窗与选项容器已构建") and ok
	# 非玩家归属时先推进到出现待选；_test_interface已保证pending存在。
	var pending: Dictionary = ui.simulation.pending_event_for_player()
	if pending.is_empty():
		return _check(false, "界面局没有玩家待选事件")
	# 先让刷新逻辑弹出待选弹窗，再走"稍后处理"关闭路径。
	ui._refresh_event_interface()
	ok = _check(ui.event_dialog.visible, "刷新后待选弹窗自动出现") and ok
	ui.event_dialog.hide()
	ok = _check(String(ui.dismissed_event_id) == String(pending.event_id), "稍后处理记录已阅事件") and ok
	ui._refresh_event_interface()
	ok = _check(not ui.event_dialog.visible, "稍后处理后不自动重新弹出") and ok
	# 工具栏入口重新打开弹窗。
	ui._show_events()
	ok = _check(ui.event_dialog.visible, "入口重新打开待选弹窗") and ok
	# 待选期间挂机推进不被弹窗阻塞。
	var before_elapsed: float = ui.simulation.elapsed_s
	if not _result(ui.simulation.advance(30.0), "待选期间挂机照常推进", ui.simulation.error_message):
		return false
	ok = _check(ui.simulation.elapsed_s > before_elapsed, "弹窗不暂停模拟推进") and ok
	# 选择真实结算：弹窗关闭、事件历史写入记录页。
	# queue_free的旧子节点在本帧仍计入children，按排队删除过滤后校验真实选项按钮。
	var option_count: int = 0
	for child in ui.event_options_box.get_children():
		if not child.is_queued_for_deletion():
			option_count += 1
	ok = _check(option_count == 3, "弹窗渲染三个选项按钮") and ok
	var option_button: Button = ui.event_options_box.get_child(0)
	var option_id: String = String(pending.options[0].id)
	option_button.pressed.emit()
	ok = _check(ui.simulation.pending_event_for_player().is_empty(), "选择后待选状态清空") and ok
	ok = _check(ui.simulation.events_log.size() == 1 and String(ui.simulation.events_log[0].option_id) == option_id, "选择真实写入事件历史") and ok
	ok = _check(not ui.event_dialog.visible, "结算后弹窗收起") and ok
	ui._refresh_event_interface()
	# RichTextLabel在headless下.text可能为空，用get_parsed_text读取真实已渲染内容。
	ok = _check(ui.log_text.get_parsed_text().contains("特殊事件结算"), "记录页渲染事件结算小节") and ok
	# 重复选择由核心明确拒绝，界面提示真实原因。
	var repeat: Error = ui.simulation.resolve_pending_event(option_id)
	ok = _check(repeat != OK, "重复选择被核心拒绝") and ok
	return ok
