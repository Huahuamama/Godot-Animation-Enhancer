@tool
extends EditorPlugin

## Animation Enhancer —— 只增强编辑体验，保留原生 Animation 面板与原生动画数据。
##
## 自动 K 帧开关的规则：
## - 编辑器启动时默认 OFF；
## - **每个场景各自记住自己的开关状态**，切换场景标签页时互不影响；
## - 关闭某个场景会忘掉它的状态，重新打开该场景回到 OFF（默认值）。
##
## 场景切换检测用两个公开 API（不轮询、不用内部节点路径）：
## - EditorSelection.selection_changed（切场景时编辑器会 clear 选中）；
## - 自动 K 帧模块的 before_event 钩子（每次属性编辑 / action 提交前再核对一次场景），
##   保证「切场景后第一次编辑」也不会写进新场景。

const AutoKeyScript := preload("res://addons/animation_enhancer/core/auto_key.gd")
const SceneStateScript := preload("res://addons/animation_enhancer/core/scene_state.gd")
const PasteMergeScript := preload("res://addons/animation_enhancer/core/paste_merge.gd")
const SelectionGuardScript := preload("res://addons/animation_enhancer/core/selection_guard.gd")

var _auto_key: Node
var _paste_merge: Node
var _guard: Node
var _button: Button
var _guard_button: Button
## 按场景记忆开关状态的策略对象（纯数据，见 core/scene_state.gd）。
## 故意不标注静态类型：RefCounted 上没有 enter()/prune()，标注后会被判为解析错误。
var _scene_state


func _enter_tree() -> void:
	_scene_state = SceneStateScript.new()

	_auto_key = AutoKeyScript.new()
	_auto_key.name = "AnimEnhancerAutoKey"
	add_child(_auto_key)
	_auto_key.status_changed.connect(_on_status)

	# 阶段 C：重复轨道合并（与自动 K 帧开关无关，始终生效）
	_paste_merge = PasteMergeScript.new()
	_paste_merge.name = "AnimEnhancerPasteMerge"
	add_child(_paste_merge)
	_paste_merge.setup(get_editor_interface(), get_undo_redo())
	_paste_merge.merged.connect(_on_merged)

	# 阶段 D：筛选下的选中保持（默认关闭，见 core/selection_guard.gd 里的取舍说明）
	_guard = SelectionGuardScript.new()
	_guard.name = "AnimEnhancerSelectionGuard"
	add_child(_guard)
	_guard.setup(get_editor_interface())
	_guard.restored.connect(_on_selection_restored)

	_button = Button.new()
	_button.toggle_mode = true
	_button.text = "自动K帧 OFF"
	_button.tooltip_text = "Animation Enhancer：在 Inspector 修改 position / rotation / scale / visible / modulate / self_modulate / z_index，\n或在 2D / 3D 视口用 gizmo 拖动后松手时，自动创建轨道并补全 RESET。\n开关状态按场景分别记住；关闭场景后重新打开会回到 OFF。"
	_button.toggled.connect(_on_toggled)
	add_control_to_container(CONTAINER_TOOLBAR, _button)

	_guard_button = Button.new()
	_guard_button.toggle_mode = true
	_guard_button.text = "保持选中 OFF"
	_guard_button.tooltip_text = "点击关键帧时，引擎会清空节点选中，导致「只显示选中节点的动画轨道」下时间轴变空。\n开启本项后，插件会在这种情况下把选中恢复回去，时间轴保持可见。\n\n代价：Inspector 会从关键帧编辑器切回节点属性（引擎行为，插件无法两全）。\n默认关闭，按需开启。"
	_guard_button.toggled.connect(_on_guard_toggled)
	add_control_to_container(CONTAINER_TOOLBAR, _guard_button)

	_auto_key.setup(get_editor_interface(), get_undo_redo())
	_auto_key.before_event = _check_scene_changed

	var selection := get_editor_interface().get_selection()
	if selection != null and not selection.selection_changed.is_connected(_check_scene_changed):
		selection.selection_changed.connect(_check_scene_changed)

	# 启动时默认关闭
	_set_enabled(false)
	_scene_state.enter(_scene_key(), false)
	print("[AnimationEnhancer] 插件已加载（自动 K 帧默认关闭）")


func _exit_tree() -> void:
	var selection := get_editor_interface().get_selection()
	if selection != null and selection.selection_changed.is_connected(_check_scene_changed):
		selection.selection_changed.disconnect(_check_scene_changed)

	if _auto_key != null:
		_auto_key.cleanup()
		_auto_key.queue_free()
		_auto_key = null

	if _paste_merge != null:
		_paste_merge.cleanup()
		_paste_merge.queue_free()
		_paste_merge = null

	if _guard != null:
		_guard.cleanup()
		_guard.queue_free()
		_guard = null

	if _guard_button != null:
		remove_control_from_container(CONTAINER_TOOLBAR, _guard_button)
		_guard_button.queue_free()
		_guard_button = null

	if _button != null:
		remove_control_from_container(CONTAINER_TOOLBAR, _button)
		_button.queue_free()
		_button = null

	print("[AnimationEnhancer] 插件已卸载")


## 编辑器保存 / 运行 / 切换场景前调用：把还在等 settle 的关键帧立刻写掉。
func _apply_changes() -> void:
	if _auto_key != null:
		_auto_key.flush_now()


# ---------------------------------------------------------------- 场景切换

## 场景标识：优先用文件路径（同一场景重开也能记住），未保存场景用实例 id。
func _scene_key() -> String:
	return _scene_state.key_for(get_editor_interface().get_edited_scene_root())


func _check_scene_changed() -> void:
	var key := _scene_key()
	if key == _scene_state.current_key:
		return

	var current: bool = _auto_key.enabled if _auto_key != null else false
	var want: bool = _scene_state.enter(key, current)
	_scene_state.prune(get_editor_interface().get_open_scenes())

	if _auto_key == null:
		return

	# 旧场景的节点已失效，快照与待写队列必须丢弃
	_auto_key.reset_context()
	if _paste_merge != null:
		_paste_merge.reset_context()
	if _guard != null:
		_guard.reset_context()

	if _auto_key.enabled != want:
		_set_enabled(want)
		if want:
			print("[AnimationEnhancer] 已恢复该场景的自动 K 帧：ON")


func _set_enabled(on: bool) -> void:
	if _auto_key != null:
		_auto_key.enabled = on
	if _button != null:
		_button.set_pressed_no_signal(on)
		_button.text = "自动K帧 ON" if on else "自动K帧 OFF"


func _on_toggled(pressed: bool) -> void:
	_set_enabled(pressed)
	print("[AnimationEnhancer] 自动 K 帧 %s" % ("开启" if pressed else "关闭"))


func _on_status(text: String, ok: bool) -> void:
	print("[AnimationEnhancer] %s" % text)


func _on_merged(count: int, keys: int) -> void:
	print("[AnimationEnhancer] 已合并 %d 条重复轨道（并入 %d 个关键帧），可撤销" % [count, keys])


func _on_guard_toggled(pressed: bool) -> void:
	if _guard != null:
		_guard.enabled = pressed
	if _guard_button != null:
		_guard_button.set_pressed_no_signal(pressed)
		_guard_button.text = "保持选中 ON" if pressed else "保持选中 OFF"
	print("[AnimationEnhancer] 保持选中 %s" % ("开启（点击关键帧后时间轴不再变空，但 Inspector 会切回节点）" if pressed else "关闭"))


func _on_selection_restored(count: int) -> void:
	print("[AnimationEnhancer] 已恢复 %d 个节点的选中，时间轴保持可见" % count)
