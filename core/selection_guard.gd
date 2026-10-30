@tool
extends Node

## 阶段 D：缓解「只显示选中节点的动画轨道」在点击关键帧后清空时间轴的问题。
##
## ## 根因（Godot 4.3 源码，已逐行核对）
##
## 1. 点击关键帧 → `AnimationTrackEditor::_update_key_edit()`（animation_track_editor.cpp:5469）
##    → `EditorNode::push_item(key_edit)`。`AnimationTrackKeyEdit` 继承自 **Object**
##    （animation_track_editor.h:56），既不是 Node 也不是 Resource。
## 2. → `EditorNode::_edit_current()`（editor_node.cpp:2431）走到最后的 else 分支：
##    ```cpp
##    InspectorDock::...->edit(current_obj);
##    SceneTreeDock::get_singleton()->set_selected(selected_node);   // nullptr
##    SceneTreeDock::get_singleton()->set_selection(multi_nodes);    // 空数组
##    ```
## 3. → `SceneTreeDock::set_selection({})`（scene_tree_dock.cpp:3164）→ `editor_selection->clear()`
##    → 发出 `selection_changed`。
## 4. → `AnimationTrackEditor::_selection_changed()`（:7017）在筛选按钮按下时调用 `_update_tracks()`；
##    `_update_tracks()`（:4601）对每条轨道判 `EditorSelection::is_selected(node)`，
##    当前没有任何节点被选中 → 所有轨道被 `continue` 跳过 → **时间轴变空**。
##
## ## 为什么插件不能「真正修好」
##
## 唯一能碰的公开入口是 `EditorSelection`。把节点重新加回去确实能让轨道回来，
## 但 `SceneTreeDock::_selection_changed()`（:2750）在 size==1 时会走
## `_handle_select(node)` → `_push_item(node)` → `EditorNode::push_node_item()`
## → `push_item(node)` → `_edit_current()`，**Inspector 会被换回节点属性**，
## 刚打开的「关键帧编辑器」被顶掉。
## 而 `EditorInspector.edit()` 没有绑定到脚本（editor_inspector.cpp 只绑了
## `get_edited_object` 等），`EditorInterface.inspect_object()` 又是走 `push_item`
## → 会再次清空选中 → 变成死循环。所以「恢复选中 + 把关键帧面板推回去」做不到。
##
## 上游 4.4-stable / 4.5-stable 的 `_edit_current()` 里这一行**仍然存在**，未被修复。
##
## ## 因此本模块的定位
##
## 一个**默认关闭**的可选缓解：开启后，在检测到「引擎为了显示非 Node 对象而清空选中」
## 时把上一次的选中恢复回去，让时间轴保持可见。
## **代价是 Inspector 会从关键帧编辑器切回节点属性**，所以必须由用户自己决定要不要开。
##
## 真正的修复需要改引擎（editor_node.cpp `_edit_current()` 的 else 分支）：
##
## ```cpp
## - SceneTreeDock::get_singleton()->set_selection(multi_nodes);
## + if (!multi_nodes.is_empty()) {
## +     SceneTreeDock::get_singleton()->set_selection(multi_nodes);
## + }
## ```

signal restored(count: int)

var enabled := false

var _editor_interface: EditorInterface
var _selection: EditorSelection
var _inspector: EditorInspector
var _busy := false
## 最近一次「非空选中」的节点，用于恢复
var _last_nodes: Array = []


## 纯判定：这次选中被清空，是不是该恢复？
## 抽成静态函数是为了能在 headless 下把全部分支跑一遍（GUI 里很难稳定复现）。
static func should_restore(p_enabled: bool, p_had_nodes: bool, p_now_empty: bool, p_edited: Object) -> bool:
	if not p_enabled or not p_had_nodes or not p_now_empty:
		return false
	# 编辑对象为空 = 用户主动取消选中，不该插手
	if p_edited == null:
		return false
	# 正在编辑节点 = 正常流程，不该插手
	if p_edited is Node:
		return false
	# 非 Node / 非空 → 引擎为了显示关键帧编辑器之类的对象清掉了选中
	return true


func setup(editor_interface: EditorInterface) -> void:
	_editor_interface = editor_interface
	_selection = editor_interface.get_selection()
	_inspector = editor_interface.get_inspector()
	if _selection != null and not _selection.selection_changed.is_connected(_on_selection_changed):
		_selection.selection_changed.connect(_on_selection_changed)


func cleanup() -> void:
	if _selection != null and _selection.selection_changed.is_connected(_on_selection_changed):
		_selection.selection_changed.disconnect(_on_selection_changed)
	_last_nodes.clear()


func reset_context() -> void:
	_last_nodes.clear()


func _on_selection_changed() -> void:
	if _busy or not enabled or _selection == null:
		return

	var nodes := _selection.get_selected_nodes()
	if not nodes.is_empty():
		_last_nodes = nodes.duplicate()
		return

	var edited: Object = _inspector.get_edited_object() if _inspector != null else null
	if not should_restore(enabled, not _last_nodes.is_empty(), true, edited):
		return
	if not _any_still_valid():
		_last_nodes.clear()
		return

	# 必须延迟：此刻正处在 editor_selection->clear() 的 signal 派发中，
	# 同步 add_node 会重入 _edit_current()。
	_restore.call_deferred()


func _any_still_valid() -> bool:
	for n in _last_nodes:
		if is_instance_valid(n) and n.is_inside_tree():
			return true
	return false


func _restore() -> void:
	if _selection == null or not enabled:
		return
	_busy = true
	var count := 0
	for n in _last_nodes:
		if not is_instance_valid(n) or not n.is_inside_tree():
			continue
		if _selection.get_selected_nodes().has(n):
			continue
		_selection.add_node(n)
		count += 1
	_busy = false
	if count > 0:
		restored.emit(count)
