extends "res://tests/test_single_player_ui.gd"
## 复用独占工程与用户目录，在生产控件上验证双人扩展，不预填库存或业务结果。

# 只有所有业务场景实际走到末尾才允许通过，脚本异常不能留下部分断言假通过。
var pair_suite_completed: bool = false


## 每个动作都通过实际按钮启动，选科、草稿、拒绝和生命周期分别检查。
func _test_interface() -> void:
	var ui := Control.new()
	root.add_child(ui)
	ui.set_script(load("res://scripts/ui/main.gd"))
	ui.set_process(false)
	ui._build_theme()
	ui._build_interface()
	var loaded := GameConfig.new()
	if not _result(loaded.load_file(), "加载双人界面正式配置", loaded.error_message):
		ui.free()
		return
	ui.configuration = loaded
	if not _reset_session(ui, 1):
		ui.free()
		return
	_check(ui._pair_action_ids().size() == 14, "扩展入口恰有14项已确定动作")
	_check("answer_challenge" not in ui._pair_action_ids(), "待确认抢答不进入玩家入口")
	if not await _test_pair_buttons(ui):
		ui.free()
		return
	if not await _test_pair_rejection(ui):
		ui.free()
		return
	await _test_pair_lifecycle(ui)
	await _test_pair_layout(ui)
	_test_pair_subject_names(ui)
	if not await _test_pair_terminal(ui):
		ui.free()
		return
	print("PAIR_EXPANSION_UI_TEST_USER_DIR=%s" % OS.get_user_data_dir())
	pair_suite_completed = true
	ui.free()


## 固定种子只用于获得真实课程奖励，未命中必须明确失败。
func _reset_pair_item(ui: Control, item_id: String, seconds: float) -> bool:
	for seed_value: int in [1, 2, 6, 3, 4, 5, 7, 8]:
		ui._close_player_dialogs()
		if not _reset_session(ui, seed_value, 1, seconds):
			return false
		if item_id.is_empty() or int(ui.simulation.students[0].inventory.get(item_id, 0)) > 0:
			return true
	return _check(false, "真实奖池未获得所需双人物品：" + item_id)


## 14项真实按钮固定发起者和目标，物品仅来自课程奖池且只在成功开始扣除。
func _test_pair_buttons(ui: Control) -> bool:
	var cases: Array[Dictionary] = [
		{"id": "remind_friend"}, {"id": "solve_together"},
		{"id": "invite_playground", "location": "playground"},
		{"id": "invite_canteen", "location": "canteen"},
		{"id": "borrow_notes"}, {"id": "encourage"},
		{"id": "pillow_fight", "seconds": 72000.0},
		{"id": "feed_snack", "item": "snack"},
		{"id": "use_eraser", "item": "eraser"},
		{"id": "give_comic_item", "item": "comic"},
		{"id": "give_candy_item", "item": "candy"},
		{"id": "swap_book", "subject": "math"},
		{"id": "swap_book_boost", "subject": "math", "item": "book_cover"},
		{"id": "arm_wrestle"},
	]
	for scenario: Dictionary in cases:
		var item_id: String = scenario.get("item", "")
		if not _reset_pair_item(ui, item_id, scenario.get("seconds", 28800.0)):
			return false
		ui._set_interaction_target(1)
		ui.note_input.text = "留给小林的草稿"
		ui.note_input.text_changed.emit(ui.note_input.text)
		var drafts: Dictionary = _drafts(ui)
		ui._select_student(3)
		var before: Dictionary = _authority(ui)
		ui._show_pair_actions(2)
		if not _choose(ui.pair_action_picker, scenario.id, "双人行动"):
			return false
		if scenario.has("subject") and not _choose(ui.pair_subject_picker, scenario.subject, "偷换课本科目"):
			return false
		_check(_authority(ui) == before and _drafts(ui) == drafts, "打开与选项只读，保留草稿和权威状态：" + scenario.id)
		_check(not ui.pair_action_button.disabled and ui.pair_action_reason.text.is_empty(), "真实前置满足后可开始：" + scenario.id)
		var previous_count: int = int(ui.simulation.students[0].inventory.get(item_id, 0))
		ui.pair_action_button.pressed.emit()
		_check(not ui.fatal_error and not ui.pair_action_dialog.visible, "成功启动后关闭选择器：" + scenario.id)
		_check(ui.pair_action_target_index == -1, "成功后使旧操作目标失效：" + scenario.id)
		var interaction: Dictionary = ui.simulation.interactions.back()
		_check(interaction.action_id == scenario.id and interaction.initiator_index == 0 and interaction.target_index == 2, "真实按钮固定本人和打开时的同学：" + scenario.id)
		_check(ui.simulation.students[3].current_action == before.students[3].current_action and _drafts(ui) == drafts, "查看对象和纸条收件人不被新互动接管")
		if not item_id.is_empty():
			_check(ui.simulation.students[0].inventory[item_id] == previous_count - 1, "按钮仅扣本人一件真实道具：" + item_id)
			_check(not _events(ui, "daily_items", 0).is_empty(), "使用物品有真实奖池来源")
		if scenario.has("subject"):
			_check(interaction.selected_subject_id == scenario.subject, "选科完整传入权威互动")
		if scenario.has("location"):
			_check(ui.simulation.student_location(0) == scenario.location and ui.simulation.student_location(2) == scenario.location, "邀请真实移动双方")
		var after_start: Dictionary = _authority(ui)
		ui.pair_action_button.pressed.emit()
		_check(_authority(ui) == after_start, "已关闭窗口的排队点击不重启互动")
		if not _result(ui.simulation.advance(interaction.duration_s), "双人动作真实完成：" + scenario.id, ui.simulation.error_message):
			return false
		ui._refresh_interface()
		_check(interaction.status == "completed", "真实完成后才产生完成记录")
		if scenario.has("subject"):
			ui._select_student(2)
			_check(ui.status_effects_text.text.contains("数学"), "目标状态列表显示实际换入科目")
		if scenario.id == "arm_wrestle":
			_check(interaction.result.outcome == "tie" and interaction.result.winner_index == -1, "相同初始体力得到真实平局")
	return true


## 窗口先显示明确原因，过期点击重新校验，失败保留原动作和真实草稿。
func _test_pair_rejection(ui: Control) -> bool:
	if not _reset_without_items(ui, ["snack"]):
		return false
	ui._show_pair_actions(1)
	if not _choose(ui.pair_action_picker, "feed_snack", "缺零食投喂"):
		return false
	if not _check(int(ui.simulation.students[0].inventory.get("snack", 0)) == 0, "缺物由真实抽奖结果形成"):
		return false
	_check(ui.pair_action_button.disabled and ui.pair_action_reason.text.contains("零食不足"), "缺物禁用并明确提示")
	var reason: String = ui.simulation.interaction_unavailable_reason(0, 1, "feed_snack")
	var before: Dictionary = _authority(ui)
	ui.pair_action_button.pressed.emit()
	await _acknowledge_error(ui, reason)
	_check(_authority(ui) == before and not ui.fatal_error, "缺物原子拒绝，健康局继续")
	ui._show_pair_actions(1)
	if not _choose(ui.pair_action_picker, "swap_book", "缺少选科"):
		return false
	_choose(ui.pair_subject_picker, "", "清除已有选科")
	_check(ui.pair_action_button.disabled and ui.pair_action_reason.text.contains("请选择"), "偷书不默认代选科目")
	_choose(ui.pair_subject_picker, "chinese", "当前科目不可偷换")
	_check(ui.pair_subject_picker.is_item_disabled(ui.pair_subject_picker.selected) and ui.pair_action_button.disabled, "当前授课科目禁用且权威入口同样拒绝")
	_choose(ui.pair_subject_picker, "math", "另一文化科目")
	_check(not ui.pair_action_button.disabled, "显式选择另一科目才可启动")
	ui.pair_action_dialog.hide()
	return true


## 关闭、缩放、隐藏和换局都撤销旧操作目标，右键入口保持原会话收件人。
func _test_pair_lifecycle(ui: Control) -> void:
	if not _reset_session(ui, 1):
		return
	ui._set_interaction_target(1)
	var before: Dictionary = _authority(ui)
	ui._show_student_context(2, Vector2(200, 100))
	ui.context_pair_button.pressed.emit()
	_check(ui.pair_action_dialog.visible and ui.pair_action_target_index == 2 and ui.interaction_target_index == 1, "右键更多绑定右键对象，不切换聊天收件人")
	ui.pair_action_dialog.hide()
	_check(ui.pair_action_target_index == -1, "取消后立即失效旧目标")
	ui.pair_action_button.pressed.emit()
	_check(_authority(ui) == before, "取消后过期点击无副作用")
	for mode: String in ["scale", "hidden", "session"]:
		ui._show_pair_actions(1)
		if mode == "scale":
			ui._set_window_scale(2 if ui.window_scale == 1 else 1)
		elif mode == "hidden":
			ui._on_window_hidden()
		else:
			ui._start_session(false)
		_check(not ui.pair_action_dialog.visible and ui.pair_action_target_index == -1, "生命周期变化使旧互动窗口失效：" + mode)


## 两种整数尺寸及原六页保持边界，固定弹窗滚动说明不会扩大主窗口。
func _test_pair_layout(ui: Control) -> void:
	if not _reset_session(ui, 1):
		return
	var before: Dictionary = _authority(ui)
	for scale_value: int in [1, 2]:
		ui._set_window_scale(scale_value)
		ui._show_interactions()
		root.size = ui._get_layout_size()
		await process_frame
		await process_frame
		_check_control_bounds(ui, Rect2(ui.global_position, ui.size).grow(1.0), "%d倍双人互动页" % scale_value)
		ui.pair_action_entry_button.pressed.emit()
		for action_id: String in ["solve_together", "swap_book", "arm_wrestle"]:
			_choose(ui.pair_action_picker, action_id, "布局动作")
			await process_frame
			await process_frame
			_check_dialog(ui.pair_action_dialog, "%d倍%s窗口" % [scale_value, action_id])
		ui.pair_action_dialog.hide()
	_check(_authority(ui) == before, "布局与动作选择不修改真实状态")


## 合法科目名称热改即时反映，已有显式选科保持同一身份。
func _test_pair_subject_names(ui: Control) -> void:
	if not _reset_session(ui, 1):
		return
	ui._show_pair_actions(1)
	_choose(ui.pair_action_picker, "swap_book", "热改科目名")
	_choose(ui.pair_subject_picker, "math", "热改前选科")
	var previous: String = ui.configuration.subjects.math.name
	ui.configuration.subjects.math.name = "数学改名验收"
	ui._refresh_interface()
	_check(ui.pair_subject_picker.get_item_text(ui.pair_subject_picker.selected) == "数学改名验收" and ui.pair_subject_picker.get_item_metadata(ui.pair_subject_picker.selected) == "math", "有效配表名称变化立即刷新但不改选科身份")
	ui.configuration.subjects.math.name = previous
	ui.pair_action_dialog.hide()


## 终局保持只读，先前打开的窗口不能在七天结束后提交新互动。
func _test_pair_terminal(ui: Control) -> bool:
	if not _reset_session(ui, 1, 7, 59995.0):
		return false
	ui._show_pair_actions(1)
	if not _result(ui.simulation.advance(5.0), "推进到真实终局", ui.simulation.error_message):
		return false
	ui._refresh_interface()
	_check(ui.simulation.is_round_finished() and ui.pair_action_entry_button.disabled and not ui.pair_action_dialog.visible, "终局关闭扩展入口与操作窗口")
	var before: Dictionary = _authority(ui)
	ui.pair_action_button.pressed.emit()
	ui.pair_action_entry_button.pressed.emit()
	_check(_authority(ui) == before and not ui.pair_action_dialog.visible and not ui.fatal_error, "终局过期点击不发动也不停止有效查阅")
	return true


## 独立报告双人界面断言，不将原生鼠标操作纳入无头结果。
func _finish() -> void:
	_check(pair_suite_completed, "双人界面的所有业务场景实际运行到末尾")
	if failures.is_empty():
		print("PAIR_EXPANSION_UI_TEST_PASS checks=%d real_controls_real_items native_tray_not_tested" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("PAIR_EXPANSION_UI_TEST_FAIL checks=%d failures=%d" % [checks, failures.size()])
		quit(1)
