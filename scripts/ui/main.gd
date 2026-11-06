extends Control

const SAVE_PATH = "user://classroom_save.json"
const DEBUG_SAVE_PATH = "user://classroom_debug_save.json"
const CONFIG_PATH = "res://config/game_config.json"
const INK = Color("273f36")
const MUTED = Color("73877c")
const BLUE = Color("2683a1")

# 核心状态、共享树控制器和界面分开持有，画面不能自行结算收益。
var simulation: ClassroomSimulation
var configuration: GameConfig
var behavior: ClassroomBehaviorController
var room: ClassroomView
var selected_index: int = 0
var fatal_error: bool = false
var last_ticks: int = 0
var refresh_elapsed: float = 0.0
var save_elapsed: float = 0.0
var config_poll_elapsed: float = 0.0
var config_modified_at: int = 0
var rendered_log_count: int = 0

# 高频界面保留节点引用，只更新真实状态对应的文字和进度。
var clock_label: Label
var course_label: Label
var scene_caption: Label
var selected_name: Label
var selected_action: Label
var action_progress: ProgressBar
var focus_label: Label
var focus_bar: ProgressBar
var stamina_label: Label
var stamina_bar: ProgressBar
var knowledge_label: Label
var attributes_label: Label
var roster_buttons: Array[Button] = []
var log_text: RichTextLabel
var footer_label: Label
var status_label: Label
var error_dialog: AcceptDialog
var restart_dialog: ConfirmationDialog
var debug_dialog: AcceptDialog
var advance_input: LineEdit
var sleep_button: Button


# 建立界面后再加载配置与存档，任何初始化失败都明确显示。
func _ready() -> void:
	_build_theme()
	_build_interface()
	get_tree().auto_accept_quit = false
	var loaded = GameConfig.new()
	if loaded.load_file() != OK:
		_fail(loaded.error_message)
		return
	configuration = loaded
	config_modified_at = FileAccess.get_modified_time(CONFIG_PATH)
	_start_session(true)
	last_ticks = Time.get_ticks_usec()


# 用单调时钟计算真实执行时间，最小化或渲染卡顿不减少资源结算秒数。
func _process(_delta: float) -> void:
	var ticks = Time.get_ticks_usec()
	var elapsed = float(ticks - last_ticks) / 1000000.0
	last_ticks = ticks
	if simulation == null or fatal_error:
		return
	if simulation.advance(elapsed) != OK:
		_fail(simulation.error_message)
		return
	refresh_elapsed += elapsed
	save_elapsed += elapsed
	config_poll_elapsed += elapsed
	if refresh_elapsed >= 0.2:
		refresh_elapsed = 0.0
		_refresh_interface()
	if config_poll_elapsed >= 1.0:
		config_poll_elapsed = 0.0
		if FileAccess.get_modified_time(CONFIG_PATH) != config_modified_at:
			_reload_configuration()
	if save_elapsed >= 30.0:
		save_elapsed = 0.0
		_save_session(false)


# 正常关闭先保存，失败则保留窗口和错误，避免看起来已经安全退出。
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if simulation != null and not fatal_error:
			if not _save_session(false):
				return
		get_tree().quit()


# 整体使用适合长时间观察的浅色界面，像素场景保持最近邻采样。
func _build_theme() -> void:
	var interface_theme = Theme.new()
	var font = SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei"])
	interface_theme.default_font = font
	interface_theme.default_font_size = 15
	interface_theme.set_color("font_color", "Label", INK)
	interface_theme.set_color("font_color", "Button", INK)
	interface_theme.set_color("font_focus_color", "Button", INK)
	interface_theme.set_color("font_pressed_color", "Button", INK)
	interface_theme.set_color("font_hover_pressed_color", "Button", Color("155a72"))
	interface_theme.set_color("font_hover_color", "Button", Color("155a72"))
	interface_theme.set_color("font_disabled_color", "Button", Color("96a59e"))
	interface_theme.set_stylebox("normal", "Button", _box(Color("f5f8f6"), Color("c7d5cd")))
	interface_theme.set_stylebox("hover", "Button", _box(Color("e8f3f5"), Color("83b7c7")))
	interface_theme.set_stylebox("pressed", "Button", _box(Color("d3eaf0"), BLUE))
	interface_theme.set_stylebox("disabled", "Button", _box(Color("edf1ee"), Color("d9e1db")))
	interface_theme.set_stylebox("focus", "Button", _box(Color(0, 0, 0, 0), BLUE))
	# 弹窗与主界面使用同一浅色底，避免引擎默认深色面板降低文字对比度。
	interface_theme.set_stylebox("panel", "AcceptDialog", _box(Color("edf3ef"), Color("a8bbb0")))
	interface_theme.set_stylebox("panel", "PopupMenu", _box(Color("edf3ef"), Color("a8bbb0")))
	interface_theme.set_color("font_color", "PopupMenu", INK)
	interface_theme.set_color("font_hover_color", "PopupMenu", Color("155a72"))
	interface_theme.set_stylebox("normal", "LineEdit", _box(Color("ffffff"), Color("a8bbb0")))
	interface_theme.set_stylebox("focus", "LineEdit", _box(Color(0, 0, 0, 0), BLUE))
	interface_theme.set_color("font_color", "LineEdit", INK)
	interface_theme.set_color("caret_color", "LineEdit", INK)
	theme = interface_theme
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


# 通用边框只用于控件，不把页面分区堆叠成装饰卡片。
func _box(background: Color, border: Color) -> StyleBoxFlat:
	var style = StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	return style


# 创建会自动跟随横屏窗口排布的主界面。
func _build_interface() -> void:
	var background = ColorRect.new()
	background.color = Color("edf3ef")
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var margins = MarginContainer.new()
	margins.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge in ["left", "right", "top", "bottom"]:
		margins.add_theme_constant_override("margin_" + edge, 16)
	add_child(margins)
	var page = VBoxContainer.new()
	page.add_theme_constant_override("separation", 10)
	margins.add_child(page)
	_build_header(page)
	var main = HBoxContainer.new()
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_theme_constant_override("separation", 20)
	page.add_child(main)
	var stage = VBoxContainer.new()
	stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stage.add_theme_constant_override("separation", 4)
	main.add_child(stage)
	var scene_row = HBoxContainer.new()
	stage.add_child(scene_row)
	scene_row.add_child(_label("教室", 18))
	scene_caption = _label("", 13, MUTED)
	scene_caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scene_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	scene_row.add_child(scene_caption)
	room = ClassroomView.new()
	room.custom_minimum_size = Vector2(768, 512)
	room.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	room.size_flags_vertical = Control.SIZE_EXPAND_FILL
	room.student_selected.connect(_select_student)
	stage.add_child(room)
	_build_inspector(main)
	_build_log(page)
	var footer = HBoxContainer.new()
	page.add_child(footer)
	footer_label = _label("", 12, MUTED)
	footer_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(footer_label)
	status_label = _label("", 12, MUTED)
	footer.add_child(status_label)
	_build_dialogs()


# 顶栏呈现游戏时间和当前课程；保存与更多操作均为实际命令。
func _build_header(page: VBoxContainer) -> void:
	var header = HBoxContainer.new()
	header.custom_minimum_size.y = 40
	header.add_theme_constant_override("separation", 18)
	page.add_child(header)
	header.add_child(_label("高考冲刺七天", 24))
	var divider = VSeparator.new()
	header.add_child(divider)
	course_label = _label("", 16)
	course_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(course_label)
	clock_label = _label("", 16, MUTED)
	header.add_child(clock_label)
	var save_button = _button("保存", "保存当前进度")
	save_button.pressed.connect(_save_session.bind(true))
	header.add_child(save_button)
	var menu = MenuButton.new()
	menu.text = "···"
	menu.tooltip_text = "更多选项"
	menu.custom_minimum_size = Vector2(42, 34)
	header.add_child(menu)
	menu.get_popup().add_item("重新读取配表", 0)
	menu.get_popup().add_item("重新开始", 1)
	menu.get_popup().add_separator()
	menu.get_popup().add_item("开发工具", 2)
	menu.get_popup().id_pressed.connect(_on_menu)


# 侧栏先列出全班状态，再查看选中角色；主动按钮始终作用于自己。
func _build_inspector(parent: HBoxContainer) -> void:
	var panel = VBoxContainer.new()
	panel.custom_minimum_size.x = 326
	panel.size_flags_horizontal = Control.SIZE_SHRINK_END
	panel.add_theme_constant_override("separation", 8)
	parent.add_child(panel)
	panel.add_child(_label("同班同学", 18))
	for index in 4:
		var button = _button("", "查看这位同学的状态")
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.custom_minimum_size.y = 34
		button.pressed.connect(_select_student.bind(index))
		panel.add_child(button)
		roster_buttons.append(button)
	panel.add_child(HSeparator.new())
	selected_name = _label("", 19)
	panel.add_child(selected_name)
	selected_action = _label("", 14, MUTED)
	panel.add_child(selected_action)
	action_progress = _progress(Color("a9bbb0"), 4)
	panel.add_child(action_progress)
	focus_label = _label("", 14)
	panel.add_child(focus_label)
	focus_bar = _progress(BLUE, 8)
	panel.add_child(focus_bar)
	stamina_label = _label("", 14)
	panel.add_child(stamina_label)
	stamina_bar = _progress(Color("78964d"), 8)
	panel.add_child(stamina_bar)
	knowledge_label = _label("", 13)
	panel.add_child(knowledge_label)
	attributes_label = _label("", 12, MUTED)
	panel.add_child(attributes_label)
	var space = Control.new()
	space.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(space)
	panel.add_child(HSeparator.new())
	panel.add_child(_label("我的行动", 15))
	var actions = HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	panel.add_child(actions)
	var focus = _button("专注", "对自己使用专注指令")
	focus.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	focus.custom_minimum_size.y = 42
	focus.add_theme_stylebox_override("normal", _box(Color("d8edf2"), Color("93becb")))
	focus.pressed.connect(_focus_player)
	actions.add_child(focus)
	var rest = _button("休息", "对自己发动基础休息")
	rest.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rest.pressed.connect(_manual_action.bind("rest"))
	actions.add_child(rest)
	sleep_button = _button("睡觉", "对自己发动趴桌睡觉")
	sleep_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sleep_button.pressed.connect(_manual_action.bind("sleep"))
	actions.add_child(sleep_button)


# 记录区只显示执行器真实产生的事件，不生成装饰性同学消息。
func _build_log(page: VBoxContainer) -> void:
	var log_area = VBoxContainer.new()
	log_area.custom_minimum_size.y = 86
	log_area.add_theme_constant_override("separation", 4)
	page.add_child(log_area)
	log_area.add_child(HSeparator.new())
	log_area.add_child(_label("班级记录", 14))
	log_text = RichTextLabel.new()
	log_text.custom_minimum_size.y = 56
	log_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_text.bbcode_enabled = false
	log_text.scroll_following = true
	log_text.selection_enabled = true
	log_text.add_theme_font_size_override("normal_font_size", 13)
	log_text.add_theme_color_override("default_color", Color("63796b"))
	log_area.add_child(log_text)


# 开发时钟入口明确标记，推进仍经过相同的行为树和数值结算。
func _build_dialogs() -> void:
	error_dialog = AcceptDialog.new()
	error_dialog.title = "运行错误"
	error_dialog.ok_button_text = "确定"
	error_dialog.min_size = Vector2i(560, 180)
	add_child(error_dialog)
	restart_dialog = ConfirmationDialog.new()
	restart_dialog.title = "重新开始"
	restart_dialog.ok_button_text = "重新开始"
	restart_dialog.cancel_button_text = "取消"
	restart_dialog.dialog_text = "重新创建本地班级，将替换当前进度。"
	restart_dialog.confirmed.connect(_restart_session)
	add_child(restart_dialog)
	debug_dialog = AcceptDialog.new()
	debug_dialog.title = "开发工具"
	debug_dialog.ok_button_text = "关闭"
	debug_dialog.min_size = Vector2i(460, 220)
	add_child(debug_dialog)
	var content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	debug_dialog.add_child(content)
	var morning = _button("开发时钟：第1天 08:00", "进入独立的开发存档，使用正常课表与动作规则")
	morning.pressed.connect(_enter_debug_morning)
	content.add_child(morning)
	var row = HBoxContainer.new()
	content.add_child(row)
	row.add_child(_label("推进分钟", 14))
	advance_input = LineEdit.new()
	advance_input.text = "10"
	advance_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(advance_input)
	var advance = _button("推进", "推进开发时钟并执行全部真实事件")
	advance.pressed.connect(_advance_debug_time)
	row.add_child(advance)
	var computer = _button("回到电脑时间", "恢复正式本地存档并对齐当前课表")
	computer.pressed.connect(_return_to_computer_time)
	content.add_child(computer)


# 保持字体和控件高度稳定，动态内容不会改变固定工具尺寸。
func _label(text_value: String, font_size: int, color: Color = INK) -> Label:
	var label = Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


# 按钮文字对应明确操作，补充鼠标提示方便理解作用对象。
func _button(text_value: String, tooltip: String) -> Button:
	var button = Button.new()
	button.text = text_value
	button.tooltip_text = tooltip
	button.custom_minimum_size.y = 32
	return button


# 进度条只负责显示状态，不持有独立的资源数值。
func _progress(color: Color, height: float) -> ProgressBar:
	var progress = ProgressBar.new()
	progress.custom_minimum_size.y = height
	progress.show_percentage = false
	var background_style = _box(Color("dae4dc"), Color("dae4dc"))
	var fill_style = _box(color, color)
	# 进度条不继承按钮留白，确保小窗口仍容纳完整状态栏。
	for style in [background_style, fill_style]:
		style.content_margin_top = 0
		style.content_margin_bottom = 0
	progress.add_theme_stylebox_override("background", background_style)
	progress.add_theme_stylebox_override("fill", fill_style)
	return progress


# 新建或读取状态后创建四棵共享蓝图实例，再开放自主决策。
func _start_session(read_save: bool) -> void:
	if is_instance_valid(behavior):
		remove_child(behavior)
		behavior.queue_free()
	# 只有完整通过初始化和读档的状态才能成为当前游戏，失败后重试必须重新读档。
	simulation = null
	if configuration == null:
		_fail("请先修复并重新读取配表，再开始游戏。")
		return
	var next_simulation = ClassroomSimulation.new()
	if next_simulation.setup(configuration) != OK:
		_fail(next_simulation.error_message)
		return
	if read_save and FileAccess.file_exists(SAVE_PATH):
		if next_simulation.load_file(SAVE_PATH) != OK:
			_fail(next_simulation.error_message)
			return
	simulation = next_simulation
	_attach_behavior()


# 绑定运行状态与树回调；角色原先的在途动作不会被重新开始。
func _attach_behavior() -> void:
	behavior = ClassroomBehaviorController.new()
	add_child(behavior)
	behavior.setup(simulation)
	simulation.decision_handler = behavior.decide
	if simulation.advance(0.0) != OK:
		_fail(simulation.error_message)
		# 首轮决策也属于初始化，失败状态不能被重读配表误认为有效游戏。
		simulation = null
		return
	fatal_error = false
	room.bind_game(simulation)
	selected_index = 0
	room.selected_index = 0
	rendered_log_count = 0
	log_text.clear()
	last_ticks = Time.get_ticks_usec()
	_refresh_interface()


# 明确确认后的重新开始才替换旧存档。
func _restart_session() -> void:
	_start_session(false)
	if not fatal_error:
		_save_session(true)


# 查看任何同学都不会修改唯一的玩家控制索引。
func _select_student(index: int) -> void:
	selected_index = index
	room.selected_index = index
	_refresh_interface()


# 专注指令每次点击直接提交，不加冷却、次数限制或手动保护状态。
func _focus_player() -> void:
	if simulation == null or fatal_error:
		return
	if simulation.focus_command(0) != OK:
		_fail(simulation.error_message)
		return
	_refresh_interface()


# 自己的持续动作复用统一执行入口，与自主动作保持同一费用和结算语义。
func _manual_action(action_id: String) -> void:
	if simulation == null or fatal_error:
		return
	if simulation.start_action(0, action_id, true) != OK:
		_fail(simulation.error_message)
		return
	_refresh_interface()


# 界面只读取已初始化的权威状态，不能用默认资源伪装初始化成功。
func _refresh_interface() -> void:
	if simulation == null or fatal_error:
		return
	var context = simulation.course_context()
	var subject_name = String(context.subject_name)
	course_label.text = String(context.period_name) + (" · " + subject_name if not subject_name.is_empty() else "")
	clock_label.text = "第%d天  %s%s" % [simulation.day, _clock(simulation.clock_seconds), "  [开发时钟]" if simulation.is_debug_time else ""]
	scene_caption.text = "%d / 4 在教室" % _count_in_classroom()
	for index in roster_buttons.size():
		var member: Dictionary = simulation.students[index]
		roster_buttons[index].text = "%s%s    %s" % [member.name, "（我）" if index == 0 and member.name != "我" else "", _action_name(member)]
		roster_buttons[index].add_theme_stylebox_override("normal", _box(Color("e2eff1") if selected_index == index else Color("f4f8f5"), Color("91b6c0") if selected_index == index else Color("c8d6cd")))
	var student: Dictionary = simulation.students[selected_index]
	selected_name.text = String(student.name) + (" · 我" if selected_index == 0 and student.name != "我" else "")
	var action: Dictionary = student.current_action
	selected_action.text = _action_name(student)
	if not action.is_empty():
		var remaining = maxf(0.0, float(action.ends_at) - simulation.elapsed_s)
		selected_action.text += "   剩余 " + _duration(remaining)
		action_progress.value = 100.0 * (1.0 - remaining / float(action.duration_s))
	else:
		action_progress.value = 0
	var max_focus = simulation.get_resource_max(selected_index, "focus")
	var max_stamina = simulation.get_resource_max(selected_index, "stamina")
	focus_label.text = "专注    %.1f / %.0f" % [student.focus, max_focus]
	stamina_label.text = "体力    %.1f / %.0f" % [student.stamina, max_stamina]
	focus_bar.max_value = max_focus
	focus_bar.value = student.focus
	stamina_bar.max_value = max_stamina
	stamina_bar.value = student.stamina
	knowledge_label.text = "语文 %.1f   数学 %.1f\n英语 %.1f   体育 %.1f" % [student.knowledge.chinese, student.knowledge.math, student.knowledge.english, student.knowledge.physical]
	var attributes: Dictionary = student.attributes
	attributes_label.text = "专注力 %.0f · 自律性 %.0f · 健康 %.0f · 智力 %.0f\n待分配属性点 %d" % [attributes.attention, attributes.discipline, attributes.health, attributes.intelligence, student.unspent_points]
	sleep_button.disabled = not simulation.can_start_action(0, "sleep")
	while rendered_log_count < simulation.logs.size():
		var entry: Dictionary = simulation.logs[rendered_log_count]
		log_text.add_text("%s  %s  %s\n" % [_clock(entry.clock_seconds), entry.name, entry.message])
		rendered_log_count += 1
	footer_label.text = "我的专注 %.1f / %.0f   ·   体力 %.1f / %.0f" % [simulation.students[0].focus, simulation.get_resource_max(0, "focus"), simulation.students[0].stamina, simulation.get_resource_max(0, "stamina")]


# 以真实动作场景统计在教室的人数。
func _count_in_classroom() -> int:
	var total = 0
	for student in simulation.students:
		if room._is_in_room(student):
			total += 1
	return total


# 持续动作的名称统一来自配表，不在界面维护第二套名称映射。
func _action_name(student: Dictionary) -> String:
	var action: Dictionary = student.current_action
	return "等待活动" if action.is_empty() else String(configuration.actions[String(action.action_id)].name)


# 格式化一天内时间，不使用宿主时区覆盖玩家本地时钟。
func _clock(seconds: float) -> String:
	var total = int(seconds)
	return "%02d:%02d:%02d" % [total / 3600, (total % 3600) / 60, total % 60]


# 剩余时间向上显示到秒，显示归零不作为动作完成的触发条件。
func _duration(seconds: float) -> String:
	var total = int(ceil(seconds))
	return "%02d:%02d" % [total / 60, total % 60]


# 保存分别写入正式或开发存档；开发时间不会覆盖正式进度。
func _save_session(show_status: bool) -> bool:
	if simulation == null or fatal_error:
		return false
	var destination = DEBUG_SAVE_PATH if simulation.is_debug_time else SAVE_PATH
	if simulation.save_file(destination) != OK:
		_fail(simulation.error_message)
		return false
	if show_status:
		status_label.text = "已保存 " + _clock(simulation.clock_seconds)
	return true


# 配表导出后原地应用新费率，抽出的时长和已经发生的结果保持原值。
func _reload_configuration() -> void:
	var replacement = GameConfig.new()
	if replacement.load_file() != OK:
		_fail(replacement.error_message)
		return
	if simulation == null:
		configuration = replacement
		_start_session(true)
		# 初始化失败必须保留停止状态，不能继续显示配表更新成功。
		if fatal_error:
			return
	elif simulation.apply_config(replacement) != OK:
		_fail(simulation.error_message)
		return
	configuration = replacement
	config_modified_at = FileAccess.get_modified_time(CONFIG_PATH)
	fatal_error = false
	last_ticks = Time.get_ticks_usec()
	status_label.text = "配表已更新"
	_refresh_interface()


# 更多菜单集中保存之外的低频操作。
func _on_menu(id: int) -> void:
	match id:
		0:
			_reload_configuration()
		1:
			restart_dialog.popup_centered()
		2:
			debug_dialog.popup_centered()


# 进入开发时钟前保存正式进度，然后建立独立的真实规则测试局。
func _enter_debug_morning() -> void:
	if simulation == null or fatal_error:
		return
	if not _save_session(false):
		return
	_start_session(false)
	if fatal_error:
		return
	if simulation.set_debug_time(1, 28800.0) != OK:
		_fail(simulation.error_message)
		return
	_refresh_interface()
	debug_dialog.hide()


# 开发工具只改变显式测试时钟，真实结算和随机动作仍由同一执行器完成。
func _advance_debug_time() -> void:
	if simulation == null or fatal_error:
		return
	if not simulation.is_debug_time:
		error_dialog.dialog_text = "请先选择开发时钟，再推进时间。"
		error_dialog.popup_centered()
		return
	if not advance_input.text.is_valid_float() or float(advance_input.text) <= 0:
		error_dialog.dialog_text = "推进分钟必须为大于0的数字。"
		error_dialog.popup_centered()
		return
	if simulation.advance_for_test(float(advance_input.text) * 60.0) != OK:
		_fail(simulation.error_message)
		return
	last_ticks = Time.get_ticks_usec()
	_refresh_interface()


# 恢复正式存档时重新对齐电脑课表，关闭和测试期间不补收益。
func _return_to_computer_time() -> void:
	if simulation != null and not fatal_error:
		if not _save_session(false):
			return
	_start_session(true)
	debug_dialog.hide()


# 错误会停止结算并保留现场，用户可从菜单明确重新读取修正后的配置。
func _fail(message: String) -> void:
	fatal_error = true
	push_error(message)
	status_label.text = "运行已停止"
	error_dialog.dialog_text = message
	error_dialog.popup_centered()
