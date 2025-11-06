package piecetable

import runtime "base:runtime"
import fmt "core:fmt"
import mem "core:mem"
import spall "core:prof/spall"
import simd "core:simd"
import slice "core:slice"
import strings "core:strings"
import sync "core:sync"
import time "core:time"

TIME_GROUPING_WINDOW :: 1000

RBColor :: enum {
	RED,
	BLACK,
}

Piece :: struct {
	buffer_type:    Buffer_Type,
	start:          int,
	length:         int,
	linefeed_count: int,
}

Buffer_Type :: enum {
	ORIGINAL,
	ADD,
}


Command_Type :: enum {
	INSERT,
	DELETE,
}

Command :: struct {
	type:      Command_Type,
	position:  int,
	text:      string,
	timestamp: i64,
}

RB_Node :: struct {
	piece:         Piece,
	parent:        ^RB_Node,
	left:          ^RB_Node,
	right:         ^RB_Node,
	color:         RBColor,
	subtree_size:  int,
	subtree_lines: int,
}

Piece_Table :: struct {
	original_buffer:      []u8,
	add_buffer:           [dynamic]u8,
	line_starts_original: [dynamic]int,
	line_starts_add:      [dynamic]int, // Positions of '\n' in add_buffer
	root:                 ^RB_Node,
	allocator:            mem.Allocator,
	history:              [dynamic]Command,
	history_index:        int,
	max_history:          int,
	grouping_time:        i64,
}


piece_table_init :: proc(text: string, allocator := context.allocator) -> Piece_Table {
	text_bytes := transmute([]u8)text
	original_copy := make([]u8, len(text_bytes), allocator)
	copy(original_copy, text_bytes)
	line_starts := make([dynamic]int, allocator)
	append(&line_starts, 0)
	for i in 0 ..< len(original_copy) {
		if original_copy[i] == '\n' {
			append(&line_starts, i + 1)
		}
	}


	pt := Piece_Table {
		original_buffer      = original_copy,
		add_buffer           = make([dynamic]u8, allocator),
		line_starts_original = line_starts,
		line_starts_add      = make([dynamic]int, allocator),
		allocator            = allocator,
		history              = make([dynamic]Command),
		max_history          = 1000,
		history_index        = -1,
		grouping_time        = 1000,
	}
	if len(text_bytes) > 0 {
		piece := Piece {
			buffer_type = .ORIGINAL,
			start       = 0,
			length      = len(text_bytes),
		}
		count_newlines_fast(&pt, &piece)
		pt.root = rb_node_create(&pt, piece, allocator)
		pt.root.color = .BLACK
	}
	append(&pt.line_starts_add, 0) // add-buffer start is considered a line start
	update_metadata(pt.root)
	return pt
}

piece_table_destroy :: proc(pt: ^Piece_Table) {
	rb_tree_destroy(pt.root, pt.allocator)
	delete(pt.history)
	delete(pt.line_starts_original)
	delete(pt.line_starts_add)
	delete(pt.original_buffer, pt.allocator)
	delete(pt.add_buffer)
}


rb_tree_destroy :: proc(node: ^RB_Node, allocator: mem.Allocator) {
	if node == nil do return
	rb_tree_destroy(node.left, allocator)
	rb_tree_destroy(node.right, allocator)
	free(node, allocator)
}

rb_node_create :: proc(pt: ^Piece_Table, piece: Piece, allocator: mem.Allocator) -> ^RB_Node {
	node := new(RB_Node, allocator)
	node.piece = piece
	node.color = .RED
	node.subtree_size = node.piece.length
	node.subtree_lines = node.piece.linefeed_count
	return node
}


// update_metadata :: proc(node: ^RB_Node) {
// 	if node == nil do return

// 	node.subtree_size = node.piece.length
// 	if node.left != nil do node.subtree_size += node.left.subtree_size
// 	if node.right != nil do node.subtree_size += node.right.subtree_size

// 	node.subtree_lines = node.piece.linefeed_count
// 	if node.left != nil do node.subtree_lines += node.left.subtree_lines
// 	if node.right != nil do node.subtree_lines += node.right.subtree_lines
// }

update_metadata :: proc(node: ^RB_Node) {
	if node == nil do return

	left_size := node.left != nil ? node.left.subtree_size : 0
	right_size := node.right != nil ? node.right.subtree_size : 0
	left_lines := node.left != nil ? node.left.subtree_lines : 0
	right_lines := node.right != nil ? node.right.subtree_lines : 0

	node.subtree_size = left_size + node.piece.length + right_size
	node.subtree_lines = left_lines + node.piece.linefeed_count + right_lines
}


update_metadata_to_root :: proc(node: ^RB_Node) {
	node := node
	for node != nil {
		update_metadata(node)
		node = node.parent
	}
}

count_newlines_fast :: proc(pt: ^Piece_Table, piece: ^Piece) {
	if piece.length == 0 {
		piece.linefeed_count = 0
		return
	}

	line_starts: []int
	switch piece.buffer_type {
	case .ORIGINAL:
		line_starts = pt.line_starts_original[:]
	case .ADD:
		line_starts = pt.line_starts_add[:]
	}

	start := piece.start
	end := piece.start + piece.length

	start_idx := binary_search_first_ge(line_starts, start + 1)
	end_idx := binary_search_first_ge(line_starts, end + 1)

	piece.linefeed_count = end_idx - start_idx
}


rotate_left :: proc(pt: ^Piece_Table, x: ^RB_Node) {
	y := x.right
	x.right = y.left

	if y.left != nil do y.left.parent = x
	y.parent = x.parent

	if x.parent == nil {
		pt.root = y
	} else if x == x.parent.left {
		x.parent.left = y
	} else {
		x.parent.right = y
	}

	y.left = x
	x.parent = y

	update_metadata(x)
	update_metadata(y)
}

rotate_right :: proc(pt: ^Piece_Table, y: ^RB_Node) {
	x := y.left
	y.left = x.right

	if x.right != nil do x.right.parent = y
	x.parent = y.parent

	if y.parent == nil {
		pt.root = x
	} else if y == y.parent.left {
		y.parent.left = x
	} else {
		y.parent.right = x
	}

	x.right = y
	y.parent = x

	update_metadata(y)
	update_metadata(x)
}

rb_insert_fixup :: proc(pt: ^Piece_Table, z: ^RB_Node) {
	z := z
	for z.parent != nil && z.parent.color == .RED {
		if z.parent == z.parent.parent.left {
			y := z.parent.parent.right
			if y != nil && y.color == .RED {
				z.parent.color = .BLACK
				y.color = .BLACK
				z.parent.parent.color = .RED
				z = z.parent.parent
			} else {
				if z == z.parent.right {
					z = z.parent
					rotate_left(pt, z)
				}
				z.parent.color = .BLACK
				z.parent.parent.color = .RED
				rotate_right(pt, z.parent.parent)
			}
		} else {
			y := z.parent.parent.left
			if y != nil && y.color == .RED {
				z.parent.color = .BLACK
				y.color = .BLACK
				z.parent.parent.color = .RED
				z = z.parent.parent
			} else {
				if z == z.parent.left {
					z = z.parent
					rotate_right(pt, z)
				}
				z.parent.color = .BLACK
				z.parent.parent.color = .RED
				rotate_left(pt, z.parent.parent)
			}
		}
	}
	pt.root.color = .BLACK
}

find_insert_position :: proc(pt: ^Piece_Table, offset: int) -> (^RB_Node, int) {
	if pt.root == nil {
		assert(false)
		return nil, -1
	}

	node := pt.root
	current_offset := 0

	for {
		left_size := 0
		if node.left != nil do left_size = node.left.subtree_size

		piece_start := current_offset + left_size
		piece_end := piece_start + node.piece.length

		if offset < piece_start {
			if node.left == nil do return node, -1
			node = node.left
		} else if offset <= piece_end {
			return node, offset - piece_start
		} else {
			current_offset = piece_end
			if node.right == nil do return node, -1
			node = node.right
		}
	}
}


Affected_Piece :: struct {
	node:           ^RB_Node,
	absolute_start: int,
}

collect_affected_pieces_for_deletion :: proc(
	node: ^RB_Node,
	start, end: int,
	affected: ^[dynamic]Affected_Piece,
	offset: int,
) {
	if node == nil do return

	left_size := 0
	if node.left != nil do left_size = node.left.subtree_size

	piece_start := offset + left_size
	piece_end := piece_start + node.piece.length

	if offset >= end do return

	subtree_end := offset + node.subtree_size
	if subtree_end <= start do return

	if piece_start > start {
		collect_affected_pieces_for_deletion(node.left, start, end, affected, offset)
	}

	if start < piece_end && end > piece_start {
		piece_info := Affected_Piece {
			node           = node,
			absolute_start = piece_start,
		}
		append(affected, piece_info)
	}

	if piece_end < end {
		collect_affected_pieces_for_deletion(
			node.right,
			start,
			end,
			affected,
			offset + left_size + node.piece.length,
		)
	}
}

@(private)
replace_node :: proc(pt: ^Piece_Table, old_node, new_node: ^RB_Node) {
	if old_node.parent == nil {
		pt.root = new_node
	} else if old_node == old_node.parent.left {
		old_node.parent.left = new_node
	} else {
		old_node.parent.right = new_node
	}

	if new_node != nil {
		new_node.parent = old_node.parent
	}
}
@(private)
rb_delete_fixup :: proc(pt: ^Piece_Table, x: ^RB_Node, x_parent: ^RB_Node) {
	x := x
	x_parent := x_parent
	for x != pt.root && (x == nil || x.color == .BLACK) {
		if x == x_parent.left {
			sibling := x_parent.right

			// Case 1: Sibling is red
			if sibling != nil && sibling.color == .RED {
				sibling.color = .BLACK
				x_parent.color = .RED
				rotate_left(pt, x_parent)
				sibling = x_parent.right // Update sibling after rotation
			}

			// Case 2: Sibling is black with two black children
			if (sibling == nil ||
				   (sibling.left == nil || sibling.left.color == .BLACK) &&
					   (sibling.right == nil || sibling.right.color == .BLACK)) {

				if sibling != nil {
					sibling.color = .RED
				}
				x = x_parent
				x_parent = x.parent
			} else {
				// Case 3: Sibling is black with red left child and black right child
				if sibling != nil && (sibling.right == nil || sibling.right.color == .BLACK) {
					if sibling.left != nil {
						sibling.left.color = .BLACK
					}
					sibling.color = .RED
					rotate_right(pt, sibling)
					sibling = x_parent.right
				}

				// Case 4: Sibling is black with red right child
				if sibling != nil {
					sibling.color = x_parent.color
					x_parent.color = .BLACK
					if sibling.right != nil {
						sibling.right.color = .BLACK
					}
					rotate_left(pt, x_parent)
				}
				x = pt.root // Terminate loop
			}
		} else {
			// Mirror cases: x is right child
			sibling := x_parent.left

			// Case 1: Sibling is red
			if sibling != nil && sibling.color == .RED {
				sibling.color = .BLACK
				x_parent.color = .RED
				rotate_right(pt, x_parent)
				sibling = x_parent.left // Update sibling after rotation
			}

			// Case 2: Sibling is black with two black children
			if (sibling == nil ||
				   (sibling.right == nil || sibling.right.color == .BLACK) &&
					   (sibling.left == nil || sibling.left.color == .BLACK)) {

				if sibling != nil {
					sibling.color = .RED
				}
				x = x_parent
				x_parent = x.parent
			} else {
				// Case 3: Sibling is black with red right child and black left child
				if sibling != nil && (sibling.left == nil || sibling.left.color == .BLACK) {
					if sibling.right != nil {
						sibling.right.color = .BLACK
					}
					sibling.color = .RED
					rotate_left(pt, sibling)
					sibling = x_parent.left
				}

				// Case 4: Sibling is black with red left child
				if sibling != nil {
					sibling.color = x_parent.color
					x_parent.color = .BLACK
					if sibling.left != nil {
						sibling.left.color = .BLACK
					}
					rotate_right(pt, x_parent)
				}
				x = pt.root // Terminate loop
			}
		}
	}
	if x != nil {
		x.color = .BLACK
	}
}
@(private)
rb_delete_node :: proc(pt: ^Piece_Table, node_to_delete: ^RB_Node) {
	if node_to_delete == nil do return

	y := node_to_delete
	y_original_color := y.color
	x: ^RB_Node = nil
	x_parent: ^RB_Node = nil

	if node_to_delete.left == nil {
		x = node_to_delete.right
		x_parent = node_to_delete.parent
		transplant(pt, node_to_delete, node_to_delete.right)
	} else if node_to_delete.right == nil {
		x = node_to_delete.left
		x_parent = node_to_delete.parent
		transplant(pt, node_to_delete, node_to_delete.left)
	} else {
		y = find_min_node(node_to_delete.right)
		y_original_color = y.color
		x = y.right

		if y.parent == node_to_delete {
			x_parent = y
		} else {
			x_parent = y.parent
			transplant(pt, y, y.right)
			y.right = node_to_delete.right
			y.right.parent = y
		}

		transplant(pt, node_to_delete, y)
		y.left = node_to_delete.left
		y.left.parent = y
		y.color = node_to_delete.color
	}

	if x_parent != nil {
		update_metadata_to_root(x_parent)
	}

	if y_original_color == .BLACK {
		rb_delete_fixup(pt, x, x_parent)
	}

	free(node_to_delete, pt.allocator)
}

@(private)
transplant :: proc(pt: ^Piece_Table, u, v: ^RB_Node) {
	if u.parent == nil {
		pt.root = v
	} else if u == u.parent.left {
		u.parent.left = v
	} else {
		u.parent.right = v
	}

	if v != nil {
		v.parent = u.parent
	}
}

@(private)
process_piece_deletion :: proc(
	pt: ^Piece_Table,
	piece_info: Affected_Piece,
	del_start, del_end: int,
) {
	node := piece_info.node
	piece_start := piece_info.absolute_start
	piece_end := piece_start + node.piece.length

	intersect_start := max(piece_start, del_start)
	intersect_end := min(piece_end, del_end)

	if intersect_start >= intersect_end do return

	left_node: ^RB_Node = nil
	if intersect_start > piece_start {
		left_length := intersect_start - piece_start
		left_piece := Piece {
			buffer_type = node.piece.buffer_type,
			start       = node.piece.start,
			length      = left_length,
		}
		left_node = rb_node_create(pt, left_piece, pt.allocator)
		count_newlines_fast(pt, &left_node.piece)
	}
	right_node: ^RB_Node = nil
	if intersect_end < piece_end {
		right_offset := intersect_end - piece_start
		right_length := piece_end - intersect_end
		right_piece := Piece {
			buffer_type = node.piece.buffer_type,
			start       = node.piece.start + right_offset,
			length      = right_length,
		}
		right_node = rb_node_create(pt, right_piece, pt.allocator)
		count_newlines_fast(pt, &right_node.piece)
	}

	rb_delete_node(pt, node)

	if left_node != nil {
		rb_insert_node_at_position(pt, left_node, piece_start)
	}
	if right_node != nil {
		insert_pos := piece_start
		if left_node != nil do insert_pos += left_node.piece.length
		rb_insert_node_at_position(pt, right_node, insert_pos)
	}
}

@(private)
piece_table_delete_internal :: proc(pt: ^Piece_Table, position: int, length: int) {

	if length <= 0 || pt.root == nil do return
	if position < 0 || position >= pt.root.subtree_size do return

	end_position := min(position + length, pt.root.subtree_size)
	actual_length := end_position - position

	if actual_length <= 0 do return

	affected_pieces := make([dynamic]Affected_Piece, pt.allocator)
	defer delete(affected_pieces)

	collect_affected_pieces_for_deletion(pt.root, position, end_position, &affected_pieces, 0)
	slice.sort_by(affected_pieces[:], sort_)
	sort_ :: proc(a, b: Affected_Piece) -> bool {
		return a.absolute_start < b.absolute_start
	}

	for i := len(affected_pieces) - 1; i >= 0; i -= 1 {
		piece_info := affected_pieces[i]
		process_piece_deletion(pt, piece_info, position, end_position)
	}
}

@(private)
find_min_node :: proc(node: ^RB_Node) -> ^RB_Node {
	node := node
	for node.left != nil {
		node = node.left
	}
	return node
}

@(private)
rb_insert_node_at_position :: proc(pt: ^Piece_Table, new_node: ^RB_Node, target_position: int) {
	if pt.root == nil {
		pt.root = new_node
		new_node.color = .BLACK
		update_metadata(new_node)
		return
	}

	current := pt.root
	current_offset := 0

	for {
		left_size := 0
		if current.left != nil do left_size = current.left.subtree_size

		node_start := current_offset + left_size
		node_end := node_start + current.piece.length

		if target_position <= node_start {
			if current.left == nil {
				current.left = new_node
				new_node.parent = current
				break
			} else {
				current = current.left
			}
		} else {
			current_offset = node_end
			if current.right == nil {
				current.right = new_node
				new_node.parent = current
				break
			} else {
				current = current.right
			}
		}
	}

	new_node.color = .RED
	rb_insert_fixup(pt, new_node)

	update_metadata_to_root(new_node)
}

find_node_at_position :: proc(pt: ^Piece_Table, position: int) -> (^RB_Node, int) {
	if pt.root == nil do return nil, 0

	node := pt.root
	current_offset := 0

	for node != nil {
		left_size := 0
		if node.left != nil do left_size = node.left.subtree_size

		node_start := current_offset + left_size
		node_end := node_start + node.piece.length

		if position < node_start {
			node = node.left
		} else if position < node_end {
			return node, position - node_start
		} else {
			current_offset = node_end
			node = node.right
		}
	}

	return nil, 0
}

@(private)
copy_piece_batch :: proc(
	node: ^RB_Node,
	start_offset: int,
	builder: ^strings.Builder,
	pt: ^Piece_Table,
) {
	piece := node.piece
	piece_start := piece.start + start_offset
	piece_end := piece_start + piece.length - start_offset

	switch piece.buffer_type {
	case .ORIGINAL:
		original_bytes := transmute([]u8)pt.original_buffer
		if piece_end <= len(original_bytes) {
			strings.write_bytes(builder, original_bytes[piece_start:piece_end])
		}
	case .ADD:
		if piece_end <= len(pt.add_buffer) {
			strings.write_bytes(builder, pt.add_buffer[piece_start:piece_end])
		}
	}
}


piece_table_insert :: proc(pt: ^Piece_Table, position: int, text: string) {
	// Record for undo
	cmd := Command {
		type      = .INSERT,
		position  = position,
		text      = text,
		timestamp = get_current_time(),
	}
	add_command(pt, cmd)
	piece_table_insert_internal(pt, position, text)
}


piece_table_delete :: proc(pt: ^Piece_Table, position: int, length: int) {
	if length <= 0 do return

	deleted_text := piece_table_substring(pt, position, length)
	defer delete(deleted_text)
	// Record for undo
	cmd := Command {
		type      = .DELETE,
		position  = position,
		text      = deleted_text,
		timestamp = get_current_time(),
	}
	add_command(pt, cmd)
	piece_table_delete_internal(pt, position, length)
}


piece_table_undo :: proc(pt: ^Piece_Table) -> bool {
	if pt.history_index < 0 do return false

	cmd := &pt.history[pt.history_index]

	switch cmd.type {
	case .INSERT:
		piece_table_delete_internal(pt, cmd.position, len(cmd.text))
	case .DELETE:
		piece_table_insert_internal(pt, cmd.position, cmd.text)
	}
	pt.history_index -= 1
	return true
}


piece_table_redo :: proc(pt: ^Piece_Table) -> bool {
	if pt.history_index >= len(pt.history) - 1 do return false

	pt.history_index += 1
	cmd := &pt.history[pt.history_index]

	switch cmd.type {
	case .INSERT:
		piece_table_insert_internal(pt, cmd.position, cmd.text)

	case .DELETE:
		piece_table_delete_internal(pt, cmd.position, len(cmd.text))
	}

	return true
}
@(private)
get_current_time :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1000000
}
@(private)
add_command :: proc(pt: ^Piece_Table, cmd: Command) {
	cmd := cmd

	if pt.history_index < len(pt.history) - 1 {
		resize(&pt.history, pt.history_index + 1)
	}

	if len(pt.history) > 0 && can_group_commands(&pt.history[len(pt.history) - 1], &cmd) {
		prev := &pt.history[len(pt.history) - 1]
		if cmd.type == .INSERT && prev.type == .INSERT {
			if cmd.position == prev.position + len(prev.text) {
				new_text := strings.concatenate({prev.text, cmd.text}, pt.allocator)
				defer delete(prev.text, pt.allocator)
				prev.text = new_text
				prev.timestamp = cmd.timestamp
				return
			}
		}
	}

	// Add new command
	cmd_copy := Command {
		type      = cmd.type,
		position  = cmd.position,
		text      = strings.clone(cmd.text, pt.allocator),
		timestamp = cmd.timestamp,
	}
	append(&pt.history, cmd_copy)
	pt.history_index = len(pt.history) - 1

	if len(pt.history) > pt.max_history {
		ordered_remove(&pt.history, 0)
		pt.history_index -= 1
	}
}
@(private)
can_group_commands :: proc(prev, curr: ^Command) -> bool {
	if prev.type != curr.type do return false
	if curr.timestamp - prev.timestamp > TIME_GROUPING_WINDOW do return false // 1 second grouping window

	switch prev.type {
	case .INSERT:
		return curr.position == prev.position + len(prev.text) && len(curr.text) == 1
	case .DELETE:
		return curr.position == prev.position - len(curr.text) || curr.position == prev.position
	}

	return false
}


piece_table_substring :: proc(
	pt: ^Piece_Table,
	start: int,
	length: int,
	allocator := context.allocator,
) -> string {
	if length <= 0 || start < 0 {
		return ""
	}

	result := make_dynamic_array([dynamic]u8, allocator)

	remaining := length
	pos := start

	for remaining > 0 {
		node, offset := find_node_at_position(pt, pos)
		if node == nil {
			break
		}

		available := node.piece.length - offset
		to_read := min(remaining, available)

		buffer: []u8
		switch node.piece.buffer_type {
		case .ORIGINAL:
			buffer = pt.original_buffer
		case .ADD:
			buffer = pt.add_buffer[:]
		}

		piece_start := node.piece.start + offset
		piece_end := piece_start + to_read
		append(&result, ..buffer[piece_start:piece_end])

		remaining -= to_read
		pos += to_read
	}
	return string(result[:])
}

@(private)
piece_table_insert_internal :: proc(pt: ^Piece_Table, position: int, text: string) {
	if len(text) == 0 do return

	start_pos := len(pt.add_buffer)
	text_bytes := transmute([]u8)text

	for i := 0; i < len(text_bytes); i += 1 {
		if text_bytes[i] == '\n' {
			append(&pt.line_starts_add, start_pos + i + 1)
		}
	}

	append(&pt.add_buffer, ..text_bytes)


	new_piece := Piece {
		buffer_type = .ADD,
		start       = start_pos,
		length      = len(text_bytes),
	}
	count_newlines_fast(pt, &new_piece)

	if pt.root == nil {
		pt.root = rb_node_create(pt, new_piece, pt.allocator)
		pt.root.color = .BLACK
		return
	}

	insert_node, split_offset := find_insert_position(pt, position)
	if split_offset > 0 && split_offset < insert_node.piece.length {
		old_piece := insert_node.piece
		right_piece := Piece {
			buffer_type = old_piece.buffer_type,
			start       = old_piece.start + split_offset,
			length      = old_piece.length - split_offset,
		}
		count_newlines_fast(pt, &right_piece)

		insert_node.piece.length = split_offset

		count_newlines_fast(pt, &insert_node.piece)
		count_newlines_fast(pt, &right_piece)

		new_node := rb_node_create(pt, new_piece, pt.allocator)
		right_node := rb_node_create(pt, right_piece, pt.allocator)

		rb_insert_node_at_position(pt, new_node, position)
		rb_insert_node_at_position(pt, right_node, position + len(text_bytes))

		update_metadata_to_root(insert_node)
	} else {
		new_node := rb_node_create(pt, new_piece, pt.allocator)
		rb_insert_node_at_position(pt, new_node, position)
	}
}

find_piece_at_position :: proc(
	table: ^Piece_Table,
	pos: int,
) -> (
	node: ^RB_Node,
	offset_in_piece: int,
	ok: bool,
) {
	if table.root == nil {
		return nil, 0, false
	}

	current := table.root
	pos_before := 0

	for current != nil {
		left_size := current.left != nil ? current.left.subtree_size : 0
		node_start := pos_before + left_size
		node_end := node_start + current.piece.length

		if pos < node_start {
			current = current.left
		} else if pos >= node_end {
			pos_before = node_end
			current = current.right
		} else {
			// Found it
			return current, pos - node_start, true
		}
	}

	return nil, 0, false
}

get_successor :: proc(node: ^RB_Node) -> ^RB_Node {
	if node == nil {
		return nil
	}
	if node.right != nil {
		current := node.right
		for current.left != nil {
			current = current.left
		}
		return current
	}
	current := node
	parent := current.parent
	for parent != nil && current == parent.right {
		current = parent
		parent = parent.parent
	}

	return parent
}

read_until_newline :: proc(
	table: ^Piece_Table,
	start_pos: int,
	allocator := context.allocator,
) -> (
	line: string,
	line_end_pos: int,
) {
	if table.root == nil {
		return "", start_pos
	}

	builder := strings.builder_make(allocator)

	current_pos := start_pos
	node, offset_in_piece, ok := find_piece_at_position(table, start_pos)

	if !ok {
		strings.builder_destroy(&builder)
		return "", start_pos
	}

	for node != nil {
		buffer := node.piece.buffer_type == .ORIGINAL ? table.original_buffer : table.add_buffer[:]

		start_in_buffer := node.piece.start + offset_in_piece
		end_in_buffer := node.piece.start + node.piece.length

		found_newline := false
		newline_pos := start_in_buffer

		for i := start_in_buffer; i < end_in_buffer; i += 1 {
			if buffer[i] == '\n' {
				newline_pos = i + 1
				found_newline = true
				break
			}
		}

		if found_newline {
			strings.write_bytes(&builder, buffer[start_in_buffer:newline_pos])
			bytes_read := newline_pos - start_in_buffer
			return strings.to_string(builder), current_pos + bytes_read
		} else {
			strings.write_bytes(&builder, buffer[start_in_buffer:end_in_buffer])
			bytes_read := end_in_buffer - start_in_buffer
			current_pos += bytes_read
		}

		node = get_successor(node)
		offset_in_piece = 0
	}

	return strings.to_string(builder), current_pos
}

find_nth_newline_position :: proc(table: ^Piece_Table, n: int) -> int {
	if n < 0 || table.root == nil {
		return -1
	}

	node := table.root
	newlines_before := 0
	pos_before := 0

	for node != nil {
		left_newlines := node.left != nil ? node.left.subtree_lines : 0
		left_size := node.left != nil ? node.left.subtree_size : 0

		if n < newlines_before + left_newlines {
			node = node.left
		} else if n < newlines_before + left_newlines + node.piece.linefeed_count {
			newline_offset := n - (newlines_before + left_newlines)

			line_starts :=
				node.piece.buffer_type == .ORIGINAL ? table.line_starts_original[:] : table.line_starts_add[:]

			first_idx := binary_search_first_ge(line_starts, node.piece.start + 1)
			target_idx := first_idx + newline_offset

			if target_idx >= len(line_starts) {
				return -1
			}

			buffer_pos := line_starts[target_idx]

			offset_in_piece := buffer_pos - node.piece.start
			doc_position := pos_before + left_size + offset_in_piece

			return doc_position
		} else {
			newlines_before += left_newlines + node.piece.linefeed_count
			pos_before += left_size + node.piece.length
			node = node.right
		}
	}

	return -1
}

get_line_number_from_offset :: proc(table: ^Piece_Table, offset: int) -> int {
	if table.root == nil || offset < 0 {
		return -1
	}
	node := table.root
	pos_before := 0
	lines_before := 0

	for node != nil {
		left_lines := node.left != nil ? node.left.subtree_lines : 0
		left_size := node.left != nil ? node.left.subtree_size : 0
		piece_start := pos_before + left_size
		piece_end := piece_start + node.piece.length

		if offset < piece_start {
			node = node.left
		} else if offset < piece_end {
			buffer :=
				node.piece.buffer_type == .ORIGINAL ? table.original_buffer : table.add_buffer[:]
			piece_offset := offset - piece_start
			buffer_start := node.piece.start
			buffer_end := node.piece.start + piece_offset

			line_count_in_piece := 0
			for i := node.piece.start; i < buffer_end; i += 1 {
				if buffer[i] == '\n' {
					line_count_in_piece += 1
				}
			}

			return lines_before + left_lines + line_count_in_piece
		} else {
			lines_before += left_lines + node.piece.linefeed_count
			pos_before += left_size + node.piece.length
			node = node.right
		}
	}


	total_lines := table.root.subtree_lines
	return total_lines
}


get_line_offset_range :: proc(
	table: ^Piece_Table,
	line_number: int,
) -> (
	start_pos: int,
	end_pos: int,
	ok: bool,
) {
	if line_number < 0 || table.root == nil {
		return 0, 0, false
	}

	if line_number == 0 {
		start_pos = 0
	} else {
		start_pos = find_nth_newline_position(table, line_number - 1)
		if start_pos < 0 {
			return 0, 0, false
		}
	}

	next_newline_pos := find_nth_newline_position(table, line_number)
	if next_newline_pos < 0 {
		total_size := table.root.subtree_size
		return start_pos, total_size, true
	}

	// The newline itself is not part of the line content, so exclude it
	return start_pos, next_newline_pos, true
}


get_line :: proc(
	table: ^Piece_Table,
	line_number: int,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	if line_number < 0 || table.root == nil {
		return "", false
	}

	start_pos: int

	if line_number == 0 {
		start_pos = 0
	} else {
		start_pos = find_nth_newline_position(table, line_number - 1)
		if start_pos < 0 {
			return "", false
		}
	}

	line, _ := read_until_newline(table, start_pos, allocator)
	return line, true
}

get_line_count :: proc(table: ^Piece_Table) -> int {
	if table.root == nil {
		return 0
	}
	return table.root.subtree_lines + 1
}


binary_search_first_ge :: proc(a: []int, x: int) -> int {
	lo, hi := 0, len(a)
	#no_bounds_check for lo < hi {
		mid := (lo + hi) / 2
		if a[mid] < x {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}


get_piece_text :: proc(table: ^Piece_Table, piece: ^Piece) -> []u8 {
	if piece.buffer_type == .ORIGINAL {
		return table.original_buffer[piece.start:piece.start + piece.length]
	} else {
		return table.add_buffer[piece.start:piece.start + piece.length]
	}
}

main :: proc() {
	pt := piece_table_init(#load("text_test_file.txt"))
	defer piece_table_destroy(&pt)
	run_all_tests()
	run_all_benchmarks()
}
