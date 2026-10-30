@tool
extends Node

## 阶段 C 的触发器：粘贴 / 新增轨道产生的重复轨道自动合并。
##
## ## 为什么不用 action 名字判断
##
## 原生粘贴用的是 `undo_redo->create_action(TTR("Paste Tracks"))`
## （editor/animation_track_editor.cpp:6260）。这里的 `TTR` 是**可翻译**的
## （不同于 `TTRC`，TTRC 只是给提取工具看的标记，运行时返回原文），
## 中文编辑器里名字会变成「粘贴轨道」，按字符串匹配完全不可靠。
## 因此改为**结构判定**：只看「同类型 + 同路径」的重复轨道是否存在。
##
## ## 为什么按「轨道数增加」触发，且撤销时绝不合并
##
## `EditorUndoRedoManager` 的两个信号互斥（editor/editor_undo_redo_manager.cpp）：
## - `commit_action()` 只发 `history_changed`（:269）；
## - `undo()` / `redo()` 只发 `version_changed`（:298 / :351）。
##
## 于是：提交时若轨道数增加（= 粘贴 / 手动加轨）就合并；
## 撤销/重做时**只同步轨道数、不合并**。
## 否则撤销这次合并会把重复轨道还原，紧接着的任何一次提交又把它合并回去，
## 用户永远撤销不掉。

signal merged(count: int, keys: int)

const Context := preload("res://addons/animation_enhancer/core/anim_context.gd")
const TrackMerge := preload("res://addons/animation_enhancer/core/track_merge.gd")

var enabled := true
var verbose := false

var _editor_interface: EditorInterface
var _undo_redo: Object
var _busy := false
## 合并执行体（必须是常驻 Node，见 track_merge.gd 文件头）
var _merger: Node
## 动画实例 id -> 上次看到的轨道数量
var _counts: Dictionary = {}


func setup(editor_interface: EditorInterface, undo_redo: Object) -> void:
	_editor_interface = editor_interface
	_undo_redo = undo_redo

	_merger = TrackMerge.new()
	_merger.name = "Merger"
	add_child(_merger)

	if _undo_redo is EditorUndoRedoManager:
		var urm := _undo_redo as EditorUndoRedoManager
		if not urm.history_changed.is_connected(_on_history_changed):
			urm.history_changed.connect(_on_history_changed)
		if not urm.version_changed.is_connected(_on_version_changed):
			urm.version_changed.connect(_on_version_changed)


func cleanup() -> void:
	if _undo_redo is EditorUndoRedoManager:
		var urm := _undo_redo as EditorUndoRedoManager
		if urm.history_changed.is_connected(_on_history_changed):
			urm.history_changed.disconnect(_on_history_changed)
		if urm.version_changed.is_connected(_on_version_changed):
			urm.version_changed.disconnect(_on_version_changed)
	_counts.clear()


## 切换 / 关闭场景时清空（旧动画的实例 id 已经没意义）。
func reset_context() -> void:
	_counts.clear()


# ---------------------------------------------------------------- 事件

func _on_history_changed() -> void:
	if _busy or not enabled or _editor_interface == null:
		return

	var root := _editor_interface.get_edited_scene_root()
	if root == null:
		return

	var ctx := Context.resolve(_editor_interface, root)
	var anim: Animation = ctx.get("animation")
	if anim == null:
		return

	consider(anim, ctx.get("player"))


func _on_version_changed() -> void:
	# 撤销 / 重做：只同步轨道数，绝不合并
	if _editor_interface == null:
		return
	var root := _editor_interface.get_edited_scene_root()
	if root == null:
		return
	var ctx := Context.resolve(_editor_interface, root)
	var anim: Animation = ctx.get("animation")
	if anim != null:
		sync_counts(anim)


## 只同步轨道数，不做合并判定。撤销 / 重做后调用。
func sync_counts(anim: Animation) -> void:
	if anim == null:
		return
	_counts[anim.get_instance_id()] = anim.get_track_count()


# ---------------------------------------------------------------- 合并判定

## 按「轨道数是否增加」决定要不要合并，返回合并的重复轨道条数（0 = 没动）。
## 公开是为了让编辑器内自测能直接驱动同一段逻辑（自测的播放器不在编辑场景里，
## 走不到 _on_history_changed 的自动解析）。
func consider(anim: Animation, player: AnimationPlayer) -> int:
	if not enabled or anim == null:
		return 0

	var aid := anim.get_instance_id()
	var cur := anim.get_track_count()
	var prev: int = _counts.get(aid, cur)
	_counts[aid] = cur

	if cur <= prev:
		if verbose:
			print("[AnimationEnhancer] 合并检查跳过：轨道数未增加（%d）" % cur)
		return 0

	return _merge(anim, player)


func _merge(anim: Animation, player: AnimationPlayer) -> int:
	# merge 内部会 commit_action，同步再发一次 history_changed，必须挡住重入
	_busy = true
	var res: Dictionary = _merger.merge(_undo_redo, anim, player)
	_busy = false

	var count := int(res.get("merged", 0))
	if count > 0:
		_counts[anim.get_instance_id()] = anim.get_track_count()
		merged.emit(count, int(res.get("keys_added", 0)))
	return count
