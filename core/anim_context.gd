@tool
extends RefCounted

## 解析「当前正在编辑的 AnimationPlayer / Animation / 播放头时间」。
##
## 依据（Godot 4.3 源码 editor/plugins/animation_player_editor_plugin.cpp:333）：
## 面板切换动画时会调用 player.set_assigned_animation(name)，
## 因此 assigned_animation 就是「面板正在编辑的动画」。
## 拖动时间轴会调用 player.seek_internal()，因此 current_animation_position 就是播放头位置。

const TRACK_3D := {
	"position": Animation.TYPE_POSITION_3D,
	"rotation": Animation.TYPE_ROTATION_3D,
	"scale": Animation.TYPE_SCALE_3D,
}

const TRACK_2D := ["position", "rotation", "scale"]


static func resolve(editor_interface: EditorInterface, node: Node) -> Dictionary:
	var ctx := {
		"player": null,
		"animation": null,
		"anim_name": "",
		"time": 0.0,
		"root": null,
		"message": "",
	}

	var player := find_player(editor_interface, node)
	if player == null:
		ctx.message = "未找到 AnimationPlayer"
		return ctx

	var anim_name := String(player.assigned_animation)
	if anim_name.is_empty():
		anim_name = String(player.current_animation)

	ctx.player = player
	if anim_name.is_empty() or not player.has_animation(anim_name):
		ctx.message = "没有正在编辑的动画（请先在 Animation 面板选择动画）"
		return ctx

	ctx.anim_name = anim_name
	ctx.animation = player.get_animation(anim_name)
	ctx.time = player.current_animation_position
	ctx.root = player.get_node_or_null(player.root_node)
	return ctx


static func find_player(editor_interface: EditorInterface, node: Node) -> AnimationPlayer:
	# 1) 选中节点的祖先链
	var n := node
	while n != null:
		if n is AnimationPlayer:
			return n
		n = n.get_parent()

	var scene_root := editor_interface.get_edited_scene_root()
	if scene_root == null:
		return null

	# 2) 编辑场景中 assigned_animation 非空的播放器 —— 即面板正在编辑的那个
	var players: Array[AnimationPlayer] = []
	_collect_players(scene_root, players)
	var first: AnimationPlayer = null
	for p in players:
		if first == null:
			first = p
		if not String(p.assigned_animation).is_empty():
			return p
	return first


static func _collect_players(node: Node, out: Array[AnimationPlayer]) -> void:
	if node is AnimationPlayer:
		out.append(node as AnimationPlayer)
	for child in node.get_children():
		_collect_players(child, out)
