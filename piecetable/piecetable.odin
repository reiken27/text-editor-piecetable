package piecetable

import runtime "base:runtime"
import fmt "core:fmt"
import mem "core:mem"
import spall "core:prof/spall"
import slice "core:slice"
import strings "core:strings"
import sync "core:sync"
import time "core:time"

//TODO add line_cache
//TODO get_line
//TODO remember cursor position on undo/redo
//maybe add cursors here?

TIME_GROUPING_WINDOW :: 1000 //ms

RBColor :: enum {
	RED,
	BLACK,
}

Piece :: struct {
	buffer_type: Buffer_Type,
	start:       int,
	length:      int,
}

Buffer_Type :: enum {
	ORIGINAL,
	ADD,
}

RB_Node :: struct {
	using piece:  Piece,
	parent:       ^RB_Node,
	left:         ^RB_Node,
	right:        ^RB_Node,
	color:        RBColor,
	subtree_size: int,
	/*
	line_starts:   [dynamic]int, //line byte starts (0 is always start??)
	line_count:    int, //this piece line count
	subtree_lines: int, //subtree lines
	*/
}

Piece_Table :: struct {
	root:            ^RB_Node,
	original_buffer: []u8,
	add_buffer:      [dynamic]u8,
	allocator:       mem.Allocator,
	history:         [dynamic]Command,
	history_index:   int,
	max_history:     int,
	grouping_time:   i64,
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

piece_table_init :: proc(text: string, allocator := context.allocator) -> Piece_Table {
	text_bytes := transmute([]u8)text
	original_copy := make([]u8, len(text_bytes), allocator)
	copy(original_copy, text_bytes)

	pt := Piece_Table {
		original_buffer = original_copy,
		add_buffer      = make([dynamic]u8, allocator),
		allocator       = allocator,
		grouping_time   = 1000,
		history_index   = -1,
		history         = make([dynamic]Command),
		max_history     = 1000,
	}

	if len(text_bytes) > 0 {
		piece := Piece {
			buffer_type = .ORIGINAL,
			start       = 0,
			length      = len(text_bytes),
		}
		pt.root = rb_node_create(&pt, piece, allocator)
		pt.root.color = .BLACK
	}

	return pt
}


piece_table_destroy :: proc(pt: ^Piece_Table) {
	rb_tree_destroy(pt.root, pt.allocator)
	delete(pt.history)
	delete(pt.original_buffer, pt.allocator)
	delete(pt.add_buffer)
}


rb_node_create :: proc(pt: ^Piece_Table, piece: Piece, allocator: mem.Allocator) -> ^RB_Node {
	node := new(RB_Node, allocator)
	node.piece = piece
	node.color = .RED
	node.subtree_size = piece.length
	return node
}


rb_tree_destroy :: proc(node: ^RB_Node, allocator: mem.Allocator) {
	if node == nil do return
	rb_tree_destroy(node.left, allocator)
	rb_tree_destroy(node.right, allocator)
	free(node, allocator)
}


update_metadata :: proc(node: ^RB_Node) {
	if node == nil do return

	// Update subtree_size (byte count)
	node.subtree_size = node.piece.length
	if node.left != nil do node.subtree_size += node.left.subtree_size
	if node.right != nil do node.subtree_size += node.right.subtree_size
}

update_metadata_to_root :: proc(node: ^RB_Node) {
	node := node
	for node != nil {
		update_metadata(node)
		node = node.parent
	}
}

/*
Before rotate_left(x):     After:
      x                      y
     / \                    / \
    a   y        -->       x   c
       / \                / \
      b   c              a   b
*/
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


find_min_node :: proc(node: ^RB_Node) -> ^RB_Node {
	node := node
	for node.left != nil {
		node = node.left
	}
	return node
}

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


piece_table_insert_internal :: proc(pt: ^Piece_Table, position: int, text: string) {
	if len(text) == 0 do return

	start_pos := len(pt.add_buffer)
	text_bytes := transmute([]u8)text
	append(&pt.add_buffer, ..text_bytes)

	new_piece := Piece {
		buffer_type = .ADD,
		start       = start_pos,
		length      = len(text_bytes),
	}

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
		insert_node.piece.length = split_offset

		// Create nodes
		new_node := rb_node_create(pt, new_piece, pt.allocator)
		right_node := rb_node_create(pt, right_piece, pt.allocator)

		rb_insert_node_at_position(pt, new_node, position)

		rb_insert_node_at_position(pt, right_node, position + len(text_bytes))
		//TODO this is probably overkill?
		update_metadata_to_root(insert_node)
		update_metadata_to_root(new_node)
		update_metadata_to_root(right_node)
	} else {
		new_node := rb_node_create(pt, new_piece, pt.allocator)
		rb_insert_node_at_position(pt, new_node, position)
		update_metadata_to_root(new_node)
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
	free_all(context.allocator)
	piece_table_delete_internal(pt, position, length)
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

	result := make([dynamic]u8, allocator)

	remaining := length
	pos := start

	for remaining > 0 {
		node, offset := find_node_at_position(pt, pos)
		if node == nil {
			break
		}

		available := node.length - offset
		to_read := min(remaining, available)

		buffer: []u8
		switch node.buffer_type {
		case .ORIGINAL:
			buffer = pt.original_buffer
		case .ADD:
			buffer = pt.add_buffer[:]
		}

		piece_start := node.start + offset
		piece_end := piece_start + to_read
		append(&result, ..buffer[piece_start:piece_end])

		remaining -= to_read
		pos += to_read
	}
	return string(result[:])
}


//undo redo
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

get_current_time :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1000000
}

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
	defer delete(cmd_copy.text)
	append(&pt.history, cmd_copy)
	pt.history_index = len(pt.history) - 1

	if len(pt.history) > pt.max_history {
		ordered_remove(&pt.history, 0)
		pt.history_index -= 1
	}
}

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

get_line :: proc(table: ^Piece_Table, line_number: int) -> (line: string, ok: bool) {
	if line_number < 0 {
		return "", false
	}

	current_line := 0
	builder := strings.builder_make(table.allocator)
	defer if current_line != line_number do strings.builder_destroy(&builder)

	node := table.root
	stack: [dynamic]^RB_Node
	defer delete(stack)

	for node != nil || len(stack) > 0 {
		for node != nil {
			append(&stack, node)
			node = node.left
		}

		node = pop(&stack)

		text := get_piece_text(table, &node.piece)

		for b in text {
			if current_line == line_number {
				strings.write_byte(&builder, b)

				if b == '\n' {
					return strings.to_string(builder), true
				}
			} else if b == '\n' {
				current_line += 1

				if current_line > line_number {
					return "", false
				}
			}
		}

		node = node.right
	}

	if current_line == line_number && strings.builder_len(builder) > 0 {
		return strings.to_string(builder), true
	}

	return "", false
}

get_piece_text :: proc(table: ^Piece_Table, piece: ^Piece) -> []u8 {
	if piece.buffer_type == .ORIGINAL {
		return table.original_buffer[piece.start:piece.start + piece.length]
	} else {
		return table.add_buffer[piece.start:piece.start + piece.length]
	}
}

main :: proc() {
	table := piece_table_init(#load("../test_files/unicode_test.odin"))
	defer piece_table_destroy(&table)
	piece_table_insert(&table, 0, "a")
	piece_table_insert(&table, 1, "b")
	piece_table_insert(&table, 2, "c")
	piece_table_insert(&table, 3, "d")
	piece_table_insert(&table, 4, "e")
	piece_table_insert(&table, 5, "f\n\n")
	piece_table_insert(&table, 7, "g")

	fmt.print("*************\n")
	fmt.println(piece_table_substring(&table, 0, table.root.subtree_size))
	fmt.println("*************")
}
