package main

import fmt "core:fmt"
import os2 "core:os/os2"
import strings "core:strings"
import utf8 "core:unicode/utf8"
import ptree "piecetable"
import rl "vendor:raylib"

get_selection_range :: proc(editor: ^Editor) -> (min: int, max: int) {
	if !editor.selection_active {
		return editor.position, editor.position
	}
	if editor.selection_start < editor.position {
		return editor.selection_start, editor.position
	}
	return editor.position, editor.selection_start
}

clear_selection :: proc(editor: ^Editor) {
	editor.selection_active = false
	editor.selection_start = editor.position
}

start_selection :: proc(editor: ^Editor) {
	if !editor.selection_active {
		editor.selection_start = editor.position
		editor.selection_active = true
	}
}

is_word_boundary :: proc(r: rune) -> bool {
	return r == ' ' || r == '\n' || r == '\t' || r == '\r'
}

get_line_start_end :: proc(editor: ^Editor, line: int) -> (start: int, end: int, ok: bool) {
	start, end, ok = ptree.get_line_offset_range(&editor.table, line)
	return
}

move_left :: proc(editor: ^Editor, extend_selection: bool = false) {
	if !extend_selection && editor.selection_active {
		min_pos, _ := get_selection_range(editor)
		editor.position = min_pos
		clear_selection(editor)

		line, col := line_col_from_cursor(editor)
		editor.desired_col_runes = col
		editor.has_desired_col = false
		return
	}
	if extend_selection {
		start_selection(editor)
	}
	if editor.position > 0 {
		backtrack := min(editor.position, 4)
		text := ptree.piece_table_substring(&editor.table, editor.position - backtrack, backtrack)
		defer delete(text)

		if len(text) > 0 {
			r, size := utf8.decode_last_rune_in_string(text)
			if r != utf8.RUNE_ERROR {
				editor.position -= size
			} else {
				editor.position -= 1
			}
		}
	}

	line, col := line_col_from_cursor(editor)
	editor.desired_col_runes = col
	editor.has_desired_col = false
	if !extend_selection {
		clear_selection(editor)
	}
}

move_right :: proc(editor: ^Editor, extend_selection: bool = false) {
	// If not extending and we have a selection, move to max
	if !extend_selection && editor.selection_active {
		_, max_pos := get_selection_range(editor)
		editor.position = max_pos
		clear_selection(editor)

		line, col := line_col_from_cursor(editor)
		editor.desired_col_runes = col
		editor.has_desired_col = false
		return
	}
	if extend_selection {
		start_selection(editor)
	}
	if editor.position < editor.table.root.subtree_size {
		remaining := editor.table.root.subtree_size - editor.position
		if remaining > 0 {
			text := ptree.piece_table_substring(&editor.table, editor.position, min(remaining, 4))
			defer delete(text)

			if len(text) > 0 {
				r, size := utf8.decode_rune_in_string(text)
				if r != utf8.RUNE_ERROR {
					editor.position += size
				} else {
					editor.position += 1
				}
			}
		}
	}

	line, col := line_col_from_cursor(editor)
	editor.desired_col_runes = col
	editor.has_desired_col = false

	if !extend_selection {
		clear_selection(editor)
	}
}

move_up :: proc(editor: ^Editor, extend_selection: bool = false) {
	if extend_selection {
		start_selection(editor)
	}

	line, col := line_col_from_cursor(editor)

	if line == 0 {
		editor.position = 0
		if !extend_selection {
			clear_selection(editor)
		}
		return
	}

	prev_line, ok := ptree.get_line(&editor.table, line - 1)
	if !ok {
		return
	}
	defer delete(prev_line)

	start_pos, end_pos, off_ok := ptree.get_line_offset_range(&editor.table, line - 1)
	if !off_ok {
		return
	}

	if !editor.has_desired_col {
		editor.desired_col_runes = col
		editor.has_desired_col = true
	}

	target_col := editor.desired_col_runes
	rune_count := utf8.rune_count(prev_line)

	if target_col > rune_count {
		target_col = rune_count
	}

	byte_offset := 0
	if target_col > 0 {
		byte_offset = utf8.rune_offset(prev_line, target_col)
	}

	editor.position = start_pos + byte_offset

	if !extend_selection {
		clear_selection(editor)
	}
}

move_down :: proc(editor: ^Editor, extend_selection: bool = false) {
	if extend_selection {
		start_selection(editor)
	}

	line, col := line_col_from_cursor(editor)

	next_line, ok := ptree.get_line(&editor.table, line + 1)
	if !ok {
		return
	}
	defer delete(next_line)

	start_pos, end_pos, off_ok := ptree.get_line_offset_range(&editor.table, line + 1)
	if !off_ok {
		return
	}

	if !editor.has_desired_col {
		editor.desired_col_runes = col
		editor.has_desired_col = true
	}

	target_col := editor.desired_col_runes
	rune_count := utf8.rune_count(next_line)

	if target_col >= rune_count {
		target_col = rune_count - 1
		if target_col < 0 {
			target_col = 0
		}
	}

	byte_offset := utf8.rune_offset(next_line, target_col)
	if byte_offset < 0 {
		byte_offset = 0
	}

	editor.position = start_pos + byte_offset

	if !extend_selection {
		clear_selection(editor)
	}
}

move_word_backward :: proc(editor: ^Editor, extend_selection: bool = false) {
	if extend_selection {
		start_selection(editor)
	}

	if editor.position == 0 {
		if !extend_selection {
			clear_selection(editor)
		}
		return
	}

	pos := editor.position
	step := 32
	skipped_initial_whitespace := false
	found_word := false

	loop: for pos > 0 {
		backtrack := min(pos, step)
		text := ptree.piece_table_substring(
			&editor.table,
			pos - backtrack,
			backtrack,
			context.temp_allocator,
		)
		i := len(text)

		for i > 0 {
			r, size := utf8.decode_last_rune_in_string(text[:i])
			i -= size

			is_space := (r == ' ' || r == '\n' || r == '\t' || r == '\r')

			if !skipped_initial_whitespace {
				if is_space {
					pos = (pos - backtrack) + i
					continue
				} else {
					skipped_initial_whitespace = true
					found_word = true
				}
			}

			if skipped_initial_whitespace {
				if is_space {
					pos = (pos - backtrack) + (i + size)
					break loop
				}
			}
		}

		pos -= backtrack
		if found_word && pos == 0 {
			break
		}
	}

	editor.position = clamp(pos, 0, editor.table.root.subtree_size)
	line, col := line_col_from_cursor(editor)
	editor.desired_col_runes = col
	editor.has_desired_col = false

	if !extend_selection {
		clear_selection(editor)
	}
}

move_word_forward :: proc(editor: ^Editor, extend_selection: bool = false) {
	if extend_selection {
		start_selection(editor)
	}

	total_size := editor.table.root.subtree_size
	if editor.position >= total_size {
		if !extend_selection {
			clear_selection(editor)
		}
		return
	}

	pos := editor.position
	step := 32
	skipped_initial_whitespace := false

	loop: for pos < total_size {
		remaining := total_size - pos
		read_len := min(remaining, step)
		text := ptree.piece_table_substring(&editor.table, pos, read_len, context.temp_allocator)

		i := 0
		for i < len(text) {
			r, size := utf8.decode_rune_in_string(text[i:])
			is_space := (r == ' ' || r == '\n' || r == '\t' || r == '\r')

			if !skipped_initial_whitespace {
				// Skip initial whitespace
				if is_space {
					pos += size
					i += size
					continue
				} else {
					skipped_initial_whitespace = true
				}
			}
			if skipped_initial_whitespace && is_space {
				break loop
			}

			pos += size
			i += size
		}
	}

	editor.position = clamp(pos, 0, total_size)
	line, col := line_col_from_cursor(editor)
	editor.desired_col_runes = col
	editor.has_desired_col = false

	if !extend_selection {
		clear_selection(editor)
	}
}

move_to_line_start :: proc(editor: ^Editor, extend_selection: bool = false) {
	if extend_selection {
		start_selection(editor)
	}

	line, _ := line_col_from_cursor(editor)
	start_pos, _, ok := ptree.get_line_offset_range(&editor.table, line)

	if ok {
		editor.position = start_pos
		editor.has_desired_col = false
	}

	if !extend_selection {
		clear_selection(editor)
	}
}

move_to_line_end :: proc(editor: ^Editor, extend_selection: bool = false) {
	if extend_selection {
		start_selection(editor)
	}

	line, _ := line_col_from_cursor(editor)
	_, end_pos, ok := ptree.get_line_offset_range(&editor.table, line)

	if ok {
		editor.position = end_pos

		if editor.position > 0 {
			text := ptree.piece_table_substring(&editor.table, editor.position - 1, 1)
			defer delete(text)
			if len(text) > 0 && text[0] == '\n' {
				editor.position -= 1
			}
		}

		editor.has_desired_col = false
	}

	if !extend_selection {
		clear_selection(editor)
	}
}

insert_text :: proc(editor: ^Editor, text: string) {
	if len(text) == 0 do return

	if editor.selection_active {
		min_pos, max_pos := get_selection_range(editor)
		ptree.piece_table_delete(&editor.table, min_pos, max_pos - min_pos)
		editor.position = min_pos
		clear_selection(editor)
	}

	ptree.piece_table_insert(&editor.table, editor.position, text)
	editor.position += len(text)
	editor.has_desired_col = false
}

delete_text :: proc(editor: ^Editor, forward: bool) {
	if editor.selection_active {
		min_pos, max_pos := get_selection_range(editor)
		ptree.piece_table_delete(&editor.table, min_pos, max_pos - min_pos)
		editor.position = min_pos
		clear_selection(editor)
		editor.has_desired_col = false
		return
	}
	if forward {
		if editor.position < editor.table.root.subtree_size {
			remaining := editor.table.root.subtree_size - editor.position
			text := ptree.piece_table_substring(&editor.table, editor.position, min(remaining, 4))
			defer delete(text)

			if len(text) > 0 {
				r, size := utf8.decode_rune_in_string(text)
				if r != utf8.RUNE_ERROR {
					ptree.piece_table_delete(&editor.table, editor.position, size)
				}
			}
		}
	} else {
		if editor.position > 0 {
			text := ptree.piece_table_substring(&editor.table, 0, editor.position)
			defer delete(text)

			if len(text) > 0 {
				last_rune_start := 0
				last_rune_size := 0

				byte_pos := 0
				for r in text {
					last_rune_start = byte_pos
					last_rune_size = utf8.rune_size(r)
					byte_pos += last_rune_size
				}

				ptree.piece_table_delete(&editor.table, last_rune_start, last_rune_size)
				editor.position = last_rune_start
			}
		}
	}
	editor.has_desired_col = false
}

delete_word :: proc(editor: ^Editor, forward: bool) {
	if editor.selection_active {
		delete_text(editor, true)
		return
	}

	if forward {
		old_pos := editor.position
		move_word_forward(editor, false)
		new_pos := editor.position

		if new_pos > old_pos {
			ptree.piece_table_delete(&editor.table, old_pos, new_pos - old_pos)
			editor.position = old_pos
		}
	} else {
		old_pos := editor.position
		move_word_backward(editor, false)
		new_pos := editor.position

		if new_pos < old_pos {
			ptree.piece_table_delete(&editor.table, new_pos, old_pos - new_pos)
			editor.position = new_pos
		}
	}

	editor.has_desired_col = false
}

copy_selection :: proc(editor: ^Editor) {
	if !editor.selection_active {
		return
	}

	min_pos, max_pos := get_selection_range(editor)
	text := ptree.piece_table_substring(&editor.table, min_pos, max_pos - min_pos)
	defer delete(text)

	c_text := strings.clone_to_cstring(text)
	defer delete(c_text)

	rl.SetClipboardText(c_text)
}

cut_selection :: proc(editor: ^Editor) {
	if !editor.selection_active {
		return
	}

	copy_selection(editor)

	min_pos, max_pos := get_selection_range(editor)
	ptree.piece_table_delete(&editor.table, min_pos, max_pos - min_pos)
	editor.position = min_pos
	clear_selection(editor)
	editor.has_desired_col = false
}

paste_clipboard :: proc(editor: ^Editor) {
	clipboard := rl.GetClipboardText()
	if clipboard == nil {
		return
	}

	text := string(clipboard)
	insert_text(editor, text)
}

handle_input :: proc(editor: ^Editor) {
	input_buffer: [dynamic]u8
	defer delete(input_buffer)

	key := rl.GetCharPressed()
	for key > 0 {
		if key >= 32 {
			buf, bytes_written := utf8.encode_rune(key)
			if bytes_written > 0 {
				append(&input_buffer, ..buf[:bytes_written])
			}
		}
		key = rl.GetCharPressed()
	}

	if len(input_buffer) > 0 {
		text := string(input_buffer[:])
		insert_text(editor, text)
		return
	}

	ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)

	if ctrl && rl.IsKeyPressed(.SPACE) {
		set_marker(editor)
		return
	}

	if ctrl && rl.IsKeyPressed(.M) {
		swap_cursor_with_marker(editor)
		return
	}

	if rl.IsKeyPressed(.ESCAPE) {
		clear_selection(editor)
		// Optionally also clear marker:
		// clear_marker(editor)
		return
	}

	if ctrl && rl.IsKeyPressed(.C) {
		if editor.marker_active {
			copy_to_marker(editor)
		} else if editor.selection_active {
			copy_selection(editor)
		}
		return
	}

	if ctrl && rl.IsKeyPressed(.X) {
		if editor.marker_active {
			cut_to_marker(editor)
		} else if editor.selection_active {
			cut_selection(editor)
		}
		return
	}

	if ctrl && rl.IsKeyPressed(.V) {
		paste_clipboard(editor)
		return
	}

	if ctrl && rl.IsKeyPressed(.W) {
		delete_to_marker(editor)
		return
	}

	// Undo/Redo
	if ctrl && rl.IsKeyPressed(.Z) {
		ptree.piece_table_undo(&editor.table)
		clear_selection(editor)
		return
	}

	if ctrl && rl.IsKeyPressed(.Y) {
		ptree.piece_table_redo(&editor.table)
		clear_selection(editor)
		return
	}

	if ctrl && rl.IsKeyPressed(.S) {
		save_file(editor)
		return
	}

	if ctrl && rl.IsKeyPressed(.G) {
		go_to_line(editor, 500 - 1)
		return
	}

	if ctrl && rl.IsKeyPressed(.L) {
		editor.show_line_numbers = !editor.show_line_numbers
		return
	}

	if ctrl && (rl.IsKeyPressed(.RIGHT_BRACKET) || rl.IsKeyPressedRepeat(.RIGHT_BRACKET)) {
		editor.font_size = min(64, editor.font_size + 1)
		return
	}

	if ctrl && (rl.IsKeyPressed(.SLASH) || rl.IsKeyPressedRepeat(.SLASH)) {
		editor.font_size = max(14, editor.font_size - 1)
		return
	}

	if ctrl {
		if rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE) {
			delete_word(editor, false)
			return
		}

		if rl.IsKeyPressed(.DELETE) || rl.IsKeyPressedRepeat(.DELETE) {
			delete_word(editor, true)
			return
		}
	}

	if ctrl {
		if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressedRepeat(.RIGHT) {
			move_word_forward(editor, shift)
			return
		}

		if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressedRepeat(.LEFT) {
			move_word_backward(editor, shift)
			return
		}
	}

	if rl.IsKeyPressed(.HOME) || rl.IsKeyPressedRepeat(.HOME) {
		move_to_line_start(editor, shift)
		return
	}

	if rl.IsKeyPressed(.END) || rl.IsKeyPressedRepeat(.END) {
		move_to_line_end(editor, shift)
		return
	}

	if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressedRepeat(.LEFT) {
		move_left(editor, shift)
		return
	}

	if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressedRepeat(.RIGHT) {
		move_right(editor, shift)
		return
	}

	if rl.IsKeyPressed(.UP) || rl.IsKeyPressedRepeat(.UP) {
		move_up(editor, shift)
		return
	}

	if rl.IsKeyPressed(.DOWN) || rl.IsKeyPressedRepeat(.DOWN) {
		move_down(editor, shift)
		return
	}

	if !ctrl {
		if rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE) {
			delete_text(editor, false)
			return
		}

		if rl.IsKeyPressed(.DELETE) || rl.IsKeyPressedRepeat(.DELETE) {
			delete_text(editor, true)
			return
		}
	}

	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressedRepeat(.ENTER) {
		insert_text(editor, "\n")
		return
	}

	if rl.IsKeyPressed(.TAB) || rl.IsKeyPressedRepeat(.TAB) {
		insert_text(editor, "\t")
		return
	}

	if ctrl && rl.IsKeyPressed(.U) {
		editor.should_recenter = true
		return
	}
}

set_marker :: proc(editor: ^Editor) {
	editor.marker_position = editor.position
	editor.marker_active = true
	fmt.println("Marker set at position:", editor.position)
}

clear_marker :: proc(editor: ^Editor) {
	editor.marker_active = false
}

swap_cursor_with_marker :: proc(editor: ^Editor) {
	if !editor.marker_active {
		return
	}

	temp := editor.position
	editor.position = editor.marker_position
	editor.marker_position = temp

	line, col := line_col_from_cursor(editor)
	editor.desired_col_runes = col
	editor.has_desired_col = false
}

get_cursor_marker_range :: proc(editor: ^Editor) -> (min: int, max: int, ok: bool) {
	if !editor.marker_active {
		return 0, 0, false
	}

	if editor.marker_position < editor.position {
		return editor.marker_position, editor.position, true
	}
	return editor.position, editor.marker_position, true
}

delete_to_marker :: proc(editor: ^Editor) {
	min_pos, max_pos, ok := get_cursor_marker_range(editor)
	if !ok {
		return
	}

	ptree.piece_table_delete(&editor.table, min_pos, max_pos - min_pos)
	editor.position = min_pos
	clear_marker(editor)
	editor.has_desired_col = false
}

copy_to_marker :: proc(editor: ^Editor) {
	min_pos, max_pos, ok := get_cursor_marker_range(editor)
	if !ok {
		return
	}

	text := ptree.piece_table_substring(&editor.table, min_pos, max_pos - min_pos)
	defer delete(text)

	c_text := strings.clone_to_cstring(text)
	defer delete(c_text)

	rl.SetClipboardText(c_text)
}

cut_to_marker :: proc(editor: ^Editor) {
	copy_to_marker(editor)
	delete_to_marker(editor)
}

select_to_marker :: proc(editor: ^Editor) {
	if !editor.marker_active {
		return
	}

	editor.selection_start = editor.marker_position
	editor.selection_active = true
	// clear_marker(editor)
}


go_to_line :: proc(editor: ^Editor, line: int) {
	line := line
	if line < 0 {
		line = 0
	}

	total_lines := editor.table.root.subtree_lines
	if line > total_lines {
		line = total_lines
	}

	start_pos, _, ok := ptree.get_line_offset_range(&editor.table, line)
	if !ok {
		return
	}

	editor.cursor.position = start_pos
	editor.cursor.has_desired_col = false
}

is_cursor_offscreen :: proc(editor: ^Editor) -> bool {
	cursor_line, cursor_col_runes := line_col_from_cursor(editor)
	cursor_y: f32 = f32(cursor_line) * editor.line_height
	cursor_x: f32 = 0.0

	if cursor_line < editor.table.root.subtree_lines {
		line_text, ok := ptree.get_line(&editor.table, cursor_line)
		defer delete(line_text)

		if ok && cursor_col_runes > 0 {
			if cursor_col_runes <= strings.rune_count(line_text) {
				rune_idx := 0
				for r, byte_idx in line_text {
					if rune_idx == cursor_col_runes {
						line_prefix := line_text[:byte_idx]
						cstring_prefix := strings.clone_to_cstring(
							line_prefix,
							context.temp_allocator,
						)
						text_size := rl.MeasureTextEx(
							editor.font,
							cstring_prefix,
							f32(editor.font_size),
							0,
						)
						cursor_x = text_size.x
						break
					}
					rune_idx += 1
				}
				if rune_idx == strings.rune_count(line_text) {
					cstring_line := strings.clone_to_cstring(line_text, context.temp_allocator)
					text_size := rl.MeasureTextEx(
						editor.font,
						cstring_line,
						f32(editor.font_size),
						0,
					)
					cursor_x = text_size.x
				}
			}
		}
	}

	if cursor_y < editor.scroll_offset_y {
		return true
	}
	if cursor_y >= editor.scroll_offset_y + editor.viewport_height - editor.line_height {
		return true
	}

	available_width := editor.viewport_width
	if editor.show_line_numbers {
		available_width -= editor.line_number_width
	}

	if cursor_x < editor.scroll_offset_x {
		return true
	}
	if cursor_x >= editor.scroll_offset_x + available_width {
		return true
	}

	return false
}
