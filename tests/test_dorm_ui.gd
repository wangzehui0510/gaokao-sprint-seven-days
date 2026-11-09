extends "res://tests/test_single_player_ui.gd"
## 宿舍界面沿用独立工程与用户目录，只通过生产控件及实际时间产生业务收益。

const DORM_IDS: Array[String] = ["dorm_study", "dorm_practice", "dorm_game", "dorm_workout", "dorm_wash", "dorm_rest"]


## 复用隔离启动与断言工具，仅替换为宿舍真实业务场景。
func _test_interface() -> void:
	var ui := Control.new()
	root.add_child(ui)
	ui.set_script(load("res://scripts/ui/main.gd"))
	ui.set_process(false)
	ui._build_theme()
	ui._build_interface()
	var configuration := GameConfig.new()
	if not _result(configuration.load_file(), "读取宿舍正式配置", configuration.error_message):
		ui.free()
		return
	ui.configuration = configuration
	if not _reset_session(ui, 351, 1, 61200.0):
		ui.free()
		return
	_check(ui.inspector_tabs.get_tab_count() == 6, "宿舍收益沿用六页，不新增独立页")
	if not await _test_dorm_controls(ui):
		ui.free()
		return
	if not await _test_six_actions(ui):
		ui.free()
		return
	if not await _test_dorm_records(ui):
		ui.free()
		return
	if not await _test_context_lifecycle(ui):
		ui.free()
		return
	await _test_dorm_layout(ui)
	print("DORM_UI_TEST_USER_DIR=%s" % OS.get_user_data_dir())
	ui.free()


## 从真实宿舍入口选科启动，查看、预览和草稿都不能改变权威状态。
func _test_dorm_controls(ui: Control) -> bool:
	ui._set_interaction_target(3)
	ui.note_input.text = "宿舍学习不转移这份草稿"
	ui.note_input.text_changed.emit(ui.note_input.text)
	var drafts: Dictionary = _drafts(ui)
	ui._select_student(1)
	var before: Dictionary = _authority(ui)
	ui.personal_action_entry_button.pressed.emit()
	await process_frame
	_check(ui.personal_action_dialog.visible and ui.personal_action_dialog.title.contains("宿舍"), "行动窗口显示本人实际位于宿舍")
	for index in DORM_IDS.size():
		_check(ui.personal_action_picker.get_item_metadata(index) == DORM_IDS[index], "宿舍列表优先展示：" + DORM_IDS[index])
	if not _choose(ui.personal_action_picker, "dorm_study", "宿舍自习"):
		return false
	_check(ui.personal_subject_picker.visible and ui.personal_subject_picker.get_item_metadata(ui.personal_subject_picker.selected) == "", "自习默认未选科，不猜科目")
	_check(ui.personal_action_button.disabled and not ui.personal_action_reason.text.is_empty(), "未选科显示明确原因并禁用开始")
	if not _choose(ui.personal_subject_picker, "math", "宿舍自习选科"):
		return false
	_check(not ui.personal_action_button.disabled, "选择真实文化课后可开始")
	_check(ui.personal_action_text.get_parsed_text().contains("数学") and ui.personal_action_text.get_parsed_text().contains("基础速度"), "选科预览包含该科真实基础速度")
	_check(ui.personal_action_text.get_parsed_text().contains("休息10分钟"), "预览明确说明结束和耗尽后的休息规则")
	_check(_authority(ui) == before and _drafts(ui) == drafts, "打开列表、选动作和选科只预览，权威数据与草稿不变")
	ui.personal_action_button.pressed.emit()
	var action: Dictionary = ui.simulation.students[0].current_action
	_check(action.action_id == "dorm_study" and action.subject_id == "math", "查看同学时仍给本人提交真实数学自习")
	_check(ui.simulation.students.slice(1) == before.students.slice(1), "本人宿舍指令不替其他同学启动动作")
	_check(not ui.personal_action_dialog.visible and _drafts(ui) == drafts, "成功启动关闭窗口，保留聊天草稿")
	if not _result(ui.simulation.advance(60.0), "真实执行一分钟数学自习", ui.simulation.error_message):
		return false
	ui._select_student(0)
	ui._refresh_interface()
	action = ui.simulation.students[0].current_action
	_check(action.knowledge_gain > 0.0 and ui.simulation.students[0].knowledge.math > before.students[0].knowledge.math, "知识来自真实一分钟积分")
	_check(ui.selected_action.text.contains("数学") and ui.status_effects_text.get_parsed_text().contains("本段已获"), "人物页呈现实际选科与本段知识")
	_check(ui.room.visual_students[0].status.contains("数学"), "宿舍场景标签包含真实所选科目")
	_check(_events(ui, "daily_items", 0).is_empty(), "宿舍学习不领取首次上课物品")
	return not ui.fatal_error


## 六项入口均用真实控件启动，消耗和收益不由测试预填。
func _test_six_actions(ui: Control) -> bool:
	for index in DORM_IDS.size():
		if not _reset_session(ui, 500 + index, 1, 61200.0):
			return false
		var action_id: String = DORM_IDS[index]
		ui.personal_action_entry_button.pressed.emit()
		if not _choose(ui.personal_action_picker, action_id, "宿舍六项"):
			return false
		if action_id in ["dorm_study", "dorm_practice"]:
			if not _choose(ui.personal_subject_picker, "english", "宿舍六项选科"):
				return false
		else:
			_check(not ui.personal_subject_picker.visible, "非选科活动隐藏科目控件：" + action_id)
		_check(not ui.personal_action_button.disabled, "真实前置满足时可开始：" + action_id)
		var knowledge: Dictionary = ui.simulation.students[0].knowledge.duplicate(true)
		ui.personal_action_button.pressed.emit()
		_check(ui.simulation.students[0].current_action.action_id == action_id, "控件接通真实动作：" + action_id)
		if not _result(ui.simulation.advance(30.0), "实际执行宿舍动作：" + action_id, ui.simulation.error_message):
			return false
		ui._refresh_interface()
		var gains: Dictionary = ui.simulation.get_dorm_summary(1, 0).totals
		if action_id in ["dorm_study", "dorm_practice"]:
			_check(ui.simulation.students[0].knowledge.english > knowledge.english and gains.english > 0.0, "选科动作有实际英语收益：" + action_id)
		elif action_id == "dorm_workout":
			_check(ui.simulation.students[0].knowledge.physical > knowledge.physical and gains.physical > 0.0, "健身实际增加体育知识")
			_check(ui.simulation.students[0].attributes.health == 0.0, "健身不增加永久健康属性")
		else:
			_check(ui.simulation.students[0].knowledge == knowledge, "娱乐与恢复不伪造知识：" + action_id)
	return not ui.fatal_error


## 独立日期和科目筛选读取唯一账本，既有日榜不因宿舍积分被回写。
func _test_dorm_records(ui: Control) -> bool:
	if not _reset_session(ui, 601, 1, 61200.0):
		return false
	var daily: Dictionary = ui.simulation.get_daily_board(1, "math")
	ui.personal_action_entry_button.pressed.emit()
	if not _choose(ui.personal_action_picker, "dorm_practice", "明细刷题") or not _choose(ui.personal_subject_picker, "math", "明细选科"):
		return false
	ui.personal_action_button.pressed.emit()
	if not _result(ui.simulation.advance(60.0), "以真实刷题产生宿舍明细", ui.simulation.error_message):
		return false
	ui._refresh_interface()
	var summary: Dictionary = ui.simulation.get_dorm_summary(1, 0)
	_check(summary.totals.math > 0.0 and summary.rows.any(func(row: Dictionary): return row.action_id == "dorm_practice" and row.subject_id == "math"), "账本拥有真实日期、动作和科目明细")
	_check(ui.simulation.get_daily_board(1, "math") == daily, "宿舍知识不回写已经发布或缺史的日榜")
	ui._select_student(0)
	ui._show_round_boards()
	var before: Dictionary = _authority(ui)
	ui.round_type_picker.select(3)
	ui.round_type_picker.item_selected.emit(3)
	if not _choose(ui.round_subject_picker, "math", "宿舍记录筛选"):
		return false
	await process_frame
	var content: String = ui.round_board_text.get_parsed_text()
	_check(content.contains("第1天") and content.contains("宿舍记录") and content.contains("数学"), "宿舍明细显示所选日期和科目")
	_check(content.contains(ui.configuration.actions.dorm_practice.name), "明细展示真实来源动作")
	_check(content.contains("不加入在校日榜"), "来源说明明确宿舍与在校分开")
	ui.round_day_picker.select(ui.round_day_picker.get_item_index(2))
	ui.round_day_picker.item_selected.emit(ui.round_day_picker.selected)
	_check(ui.round_board_text.get_parsed_text().contains("第2天"), "可查看其他日期宿舍记录")
	ui.round_type_picker.select(0)
	ui.round_type_picker.item_selected.emit(0)
	_check(ui.round_board_text.get_parsed_text().contains("在校知识榜"), "新日榜明确标记在校统计口径")
	_check(_authority(ui) == before, "日期、科目、类型筛选均不改变知识、随机流或账本")
	return true


## 隐藏、布局、换课及重新打开会撤销旧选择，排队点击不能偷偷启动动作。
func _test_context_lifecycle(ui: Control) -> bool:
	if not _reset_session(ui, 701, 1, 61200.0):
		return false
	ui.personal_action_entry_button.pressed.emit()
	if not _choose(ui.personal_action_picker, "dorm_study", "生命周期") or not _choose(ui.personal_subject_picker, "chinese", "生命周期选科"):
		return false
	ui._close_player_dialogs()
	var before: Dictionary = _authority(ui)
	ui.personal_action_button.pressed.emit()
	_check(_authority(ui) == before, "窗口关闭后的排队点击不发动宿舍学习")
	ui.personal_action_entry_button.pressed.emit()
	_check(ui.personal_subject_picker.get_item_metadata(ui.personal_subject_picker.selected) == "", "重新打开需要再次明确选科")
	if not _choose(ui.personal_subject_picker, "math", "布局前选科"):
		return false
	ui._set_window_scale(2)
	_check(not ui.personal_action_dialog.visible, "缩放关闭原操作窗口")
	before = _authority(ui)
	ui.personal_action_button.pressed.emit()
	_check(_authority(ui) == before, "缩放后的旧点击不启动动作")
	if not _reset_session(ui, 702, 2, 28740.0):
		return false
	ui.personal_action_entry_button.pressed.emit()
	if not _choose(ui.personal_action_picker, "dorm_study", "上课前预览") or not _choose(ui.personal_subject_picker, "chinese", "上课前选科"):
		return false
	if not _result(ui.simulation.advance(60.0), "真实推进至次日上课", ui.simulation.error_message):
		return false
	ui._refresh_interface()
	_check(not ui.personal_action_dialog.visible, "上课时撤销宿舍旧窗口")
	before = _authority(ui)
	ui.personal_action_button.pressed.emit()
	_check(_authority(ui) == before, "课表切换后旧点击不改为发动列表中新动作")
	var ids: Array[String] = ui._personal_action_ids()
	_check(not ids.has("dorm_study") and not ids.has("dorm_rest"), "课堂不提供宿舍活动或随意搬回宿舍入口")
	return not ui.fatal_error


## 两种既定窗口尺寸中验证新增科目控件和明细页均完整位于边界内。
func _test_dorm_layout(ui: Control) -> void:
	if not _reset_session(ui, 801, 1, 61200.0):
		return
	ui.personal_action_entry_button.pressed.emit()
	if not _choose(ui.personal_action_picker, "dorm_study", "布局前真实自习") or not _choose(ui.personal_subject_picker, "math", "布局前真实选科"):
		return
	ui.personal_action_button.pressed.emit()
	if not _result(ui.simulation.advance(60.0), "以真实自习建立布局中的知识明细", ui.simulation.error_message):
		return
	ui._refresh_interface()
	var before: Dictionary = _authority(ui)
	for scale_value in [1, 2]:
		ui._set_window_scale(scale_value)
		ui._set_panel_visible(true)
		ui._refresh_interface()
		root.size = ui._get_layout_size()
		ui.inspector_tabs.current_tab = 0
		await process_frame
		await process_frame
		_check_control_bounds(ui, Rect2(ui.global_position, ui.size).grow(1.0), "%d倍宿舍人物页" % scale_value)
		await _capture_gpu(root, "%dx_dorm_character" % scale_value)
		ui.personal_action_entry_button.pressed.emit()
		if not _choose(ui.personal_action_picker, "dorm_study", "布局宿舍自习") or not _choose(ui.personal_subject_picker, "english", "布局选科"):
			return
		await process_frame
		await process_frame
		_check_dialog(ui.personal_action_dialog, "%d倍宿舍选科窗口" % scale_value)
		_check(ui.personal_subject_picker.is_visible_in_tree(), "%d倍实际显示选科控件" % scale_value)
		await _capture_gpu(ui.personal_action_dialog, "%dx_dorm_subject" % scale_value)
		ui.personal_action_dialog.hide()
		ui.inspector_tabs.current_tab = 5
		ui.round_type_picker.select(3)
		ui.round_type_picker.item_selected.emit(3)
		_choose(ui.round_subject_picker, "math", "截图明细科目")
		await process_frame
		await process_frame
		_check_control_bounds(ui, Rect2(ui.global_position, ui.size).grow(1.0), "%d倍宿舍明细页" % scale_value)
		await _capture_gpu(root, "%dx_dorm_records" % scale_value)
	_check(_authority(ui) == before, "宿舍布局、弹窗和明细查看保持权威状态只读")


## 仅真实GPU运行时保存实际视口；无头运行不生成截图或冒称显示验收通过。
func _capture_gpu(viewport: Viewport, filename: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	# 指针离开人物，避免真实悬停提示遮挡本次要核对的静态布局。
	Input.warp_mouse(Vector2(2, 2))
	await process_frame
	# 低功耗模式在静态窗口中可能不再重绘，显式绘制后读取真实GPU视口。
	RenderingServer.force_draw(false)
	var image: Image = viewport.get_texture().get_image()
	var output_directory: String = ProjectSettings.globalize_path("res://.artifacts/dorm_ui_gpu")
	if not _result(DirAccess.make_dir_recursive_absolute(output_directory), "建立隔离GPU截图目录"):
		return
	if not _result(image.save_png(output_directory.path_join(filename + ".png")), "保存真实GPU截图：" + filename):
		return
	var colored: int = 0
	var colors: Dictionary = {}
	for y in range(0, image.get_height(), 13):
		for x in range(0, image.get_width(), 13):
			var pixel: Color = image.get_pixel(x, y)
			if pixel.a > 0.0:
				colored += 1
				colors[pixel.to_rgba32()] = true
	_check(colored > 20 and colors.size() > 10, "实际视口像素非空且存在场景与文字：" + filename)
	print("DORM_UI_GPU_CAPTURE=%s" % output_directory.path_join(filename + ".png"))


## 独立输出宿舍完整断言结果，不用既有套件标记冒充本次通过。
func _finish() -> void:
	if failures.is_empty():
		print("DORM_UI_TEST_PASS checks=%d real_controls_real_knowledge native_tray_not_tested" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("DORM_UI_TEST_FAIL checks=%d failures=%d" % [checks, failures.size()])
		quit(1)
