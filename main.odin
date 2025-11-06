package main

import fmt "core:fmt"
import mem "core:mem"
import os "core:os"
import os2 "core:os/os2"
import strings "core:strings"
import time "core:time"
import utf8 "core:unicode/utf8"
import ptree "piecetable"
import rl "vendor:raylib"

SCREEN_WIDTH :: 1280
SCREEN_HEIGHT :: 720

Cursor :: struct {
	position:          int,
	cursor_blink_time: f32,
	cursor_visible:    bool,
	cursor_color:      rl.Color,
	desired_col_runes: int,
	has_desired_col:   bool,
}

Editor :: struct {
	table:             ptree.Piece_Table,
	using cursor:      Cursor,
	file_name:         string,
	font:              rl.Font,
	scroll_offset_y:   f32,
	scroll_offset_x:   f32,
	line_height:       f32,
	viewport_width:    f32,
	viewport_height:   f32,
	font_size:         i32,
	status_bar_height: f32,
	line_number_width: f32,
	show_line_numbers: bool,
}

editor_init :: proc(
	editor: ^Editor,
	custom_font_path: string = "NotoSansJP-Regular.ttf",
	filename: string,
) {
	editor := editor
	editor.font = load_unicode_font(custom_font_path)
	editor.cursor.position = 0
	editor.scroll_offset_y = 0
	editor.scroll_offset_x = 0
	editor.font_size = 20
	editor.line_height = f32(editor.font_size) * 1
	editor.cursor_visible = true
	editor.viewport_width = SCREEN_WIDTH
	editor.viewport_height = SCREEN_HEIGHT
	editor.status_bar_height = 40
	editor.desired_col_runes = -1
	editor.has_desired_col = false
	editor.show_line_numbers = true
	editor.line_number_width = 60
	ok := load_file(editor, filename)
	if !ok do return
	editor.file_name = filename
}

editor_cleanup :: proc(editor: ^Editor) {
	ptree.piece_table_destroy(&editor.table)
	if editor.font.texture.id != rl.GetFontDefault().texture.id {
		rl.UnloadFont(editor.font)
	}
}


load_file :: proc(editor: ^Editor, filename: string) -> bool {
	editor := editor
	data, ok := os.read_entire_file(filename)
	defer delete(data)
	if !ok {
		fmt.printf("Failed to read file: %s\n", filename)
		return false
	}
	text := string(data)
	editor.table = ptree.piece_table_init(text)
	return true
}

load_unicode_font :: proc(custom_font_path: string = "") -> rl.Font {
	if len(custom_font_path) > 0 {
		cstring_path := strings.clone_to_cstring(custom_font_path)
		defer delete(cstring_path)
		//need to figure out how to load codepoints properly (dynamically?)in order to support unicode
		font := rl.LoadFontEx(cstring_path, 20, nil, 0)

		if font.texture.id != 0 {
			fmt.printf("Loaded custom Unicode font: %s\n", custom_font_path)
			return font
		} else {
			fmt.printf("Warning: Failed to load custom font: %s\n", custom_font_path)
		}
	}
	return rl.GetFontDefault()
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
	}

	if rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) {
		if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.LEFT_SHIFT) {

		} else {
			if rl.IsKeyPressed(.RIGHT) {
				move_word_forward(editor)
				line, col := line_col_from_cursor(editor)
				a, ok := ptree.get_line(&editor.table, line)
				fmt.println(transmute([]u8)a)
			}
			if rl.IsKeyPressed(.LEFT) {
				move_word_backward(editor)
			}
		}
	}


	if (rl.IsKeyPressedRepeat(.ENTER) || rl.IsKeyPressed(.ENTER)) {
		insert_text(editor, "\n")
	}
	if rl.IsKeyPressedRepeat(.TAB) || rl.IsKeyPressed(.TAB) {
		insert_text(editor, "\t")
	}

	if rl.IsKeyPressedRepeat(.BACKSPACE) || rl.IsKeyPressed(.BACKSPACE) {
		delete_text(editor, forward = false)
	}

	if rl.IsKeyPressedRepeat(.DELETE) || rl.IsKeyPressed(.DELETE) {
		delete_text(editor, forward = true)
	}

	if rl.IsKeyPressedRepeat(.LEFT) || rl.IsKeyPressed(.LEFT) {
		move_left(editor)
	}
	if rl.IsKeyPressedRepeat(.RIGHT) || rl.IsKeyPressed(.RIGHT) {
		move_right(editor)
	}
	if rl.IsKeyPressedRepeat(.UP) || rl.IsKeyPressed(.UP) {
		move_up(editor)
	}
	if rl.IsKeyPressedRepeat(.DOWN) || rl.IsKeyPressed(.DOWN) {
		move_down(editor)
	}
	if rl.IsKeyDown(.LEFT_CONTROL) && rl.IsKeyPressed(.Z) {
		result := ptree.piece_table_undo(&editor.table)
		fmt.println("undo", result)
	}
	if rl.IsKeyDown(.LEFT_CONTROL) && rl.IsKeyPressed(.Y) {
		result := ptree.piece_table_redo(&editor.table) // Changed from undo
		fmt.println("redo", result)
	}

	if rl.IsKeyDown(.LEFT_CONTROL) && rl.IsKeyPressed(.S) {
		result := save_file(editor)
		fmt.println("saved at:", editor.file_name)
	}
	if rl.IsKeyDown(.LEFT_CONTROL) && rl.IsKeyPressed(.G) {
		go_to_line(editor, 500 - 1)
	}
	// Toggle line numbers
	if rl.IsKeyDown(.LEFT_CONTROL) && rl.IsKeyPressed(.L) {
		editor.show_line_numbers = !editor.show_line_numbers
	}

}

save_file :: proc(editor: ^Editor) -> bool {
	// TODO: i can probably make this much faster
	file, err := os.open(editor.file_name, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0)
	if err != nil {
		fmt.println("Failed to open file for writing:", err)
		return false
	}
	defer os.close(file)

	pt := &editor.table
	total := pt.root.subtree_size

	remaining := total
	pos := 0

	for remaining > 0 {
		node, offset := ptree.find_node_at_position(pt, pos)
		if node == nil {
			break
		}

		available := node.piece.length - offset
		to_write := min(remaining, available)

		buffer: []u8
		switch node.piece.buffer_type {
		case .ORIGINAL:
			buffer = pt.original_buffer[:]
		case .ADD:
			buffer = pt.add_buffer[:]
		}

		piece_start := node.piece.start + offset
		piece_end := piece_start + to_write
		data := buffer[piece_start:piece_end]

		// write this chunk
		written, err := os.write(file, data)
		if err != nil || written != len(data) {
			fmt.println("Write failed:", err)
			return false
		}

		remaining -= to_write
		pos += to_write
	}

	return true
}


move_left :: proc(editor: ^Editor) {
	if editor.cursor.position > 0 {
		backtrack := min(editor.cursor.position, 4)
		text := ptree.piece_table_substring(
			&editor.table,
			editor.cursor.position - backtrack,
			backtrack,
		)
		defer delete(text)

		if len(text) > 0 {
			r, size := utf8.decode_last_rune_in_string(text)
			if r != utf8.RUNE_ERROR {
				editor.cursor.position -= size
			} else {
				editor.cursor.position -= 1
			}
		}
	}

	line, col := line_col_from_cursor(editor)
	editor.cursor.desired_col_runes = col
	editor.cursor.has_desired_col = false
}


move_right :: proc(editor: ^Editor) {
	if editor.cursor.position < editor.table.root.subtree_size {
		remaining := editor.table.root.subtree_size - editor.cursor.position
		if remaining > 0 {
			text := ptree.piece_table_substring(
				&editor.table,
				editor.cursor.position,
				min(remaining, 4),
			)
			defer delete(text)

			if len(text) > 0 {
				r, size := utf8.decode_rune_in_string(text)
				if r != utf8.RUNE_ERROR {
					editor.cursor.position += size
				} else {
					editor.cursor.position += 1
				}
			}
		}
	}

	line, col := line_col_from_cursor(editor)
	editor.cursor.desired_col_runes = col
	editor.cursor.has_desired_col = false
}

move_up :: proc(editor: ^Editor) {
	line, col := line_col_from_cursor(editor)

	if line == 0 {
		editor.cursor.position = 0
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

	if !editor.cursor.has_desired_col {
		editor.cursor.desired_col_runes = col
		editor.cursor.has_desired_col = true
	}

	target_col := editor.cursor.desired_col_runes
	rune_count := utf8.rune_count(prev_line)

	if target_col > rune_count {
		target_col = rune_count
	}

	byte_offset := 0
	if target_col > 0 {
		byte_offset = utf8.rune_offset(prev_line, target_col)
	}

	editor.cursor.position = start_pos + byte_offset
}


move_down :: proc(editor: ^Editor) {
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

	if !editor.cursor.has_desired_col {
		editor.cursor.desired_col_runes = col
		editor.cursor.has_desired_col = true
	}

	target_col := editor.cursor.desired_col_runes
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

	editor.cursor.position = start_pos + byte_offset
}

move_word_backward :: proc(editor: ^Editor) {
	if editor.cursor.position == 0 {
		return
	}

	pos := editor.cursor.position
	step := 32
	in_whitespace := true

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

			if in_whitespace {
				// keep skipping whitespace
				if !is_space {
					in_whitespace = false
				}
			} else {
				// now inside a word — stop when we hit whitespace
				if is_space {
					pos = (pos - backtrack) + (i + size)
					break loop
				}
			}
		}

		pos -= backtrack
	}

	// clamp and update cursor
	editor.cursor.position = clamp(pos, 0, editor.table.root.subtree_size)
	line, col := line_col_from_cursor(editor)
	editor.cursor.desired_col_runes = col
	editor.cursor.has_desired_col = false
}

move_word_forward :: proc(editor: ^Editor) {
	total_size := editor.table.root.subtree_size
	if editor.cursor.position >= total_size {
		return
	}

	pos := editor.cursor.position
	step := 32
	in_word := false
	in_whitespace := true

	loop: for pos < total_size {
		remaining := total_size - pos
		read_len := min(remaining, step)
		text := ptree.piece_table_substring(&editor.table, pos, read_len, context.temp_allocator)

		i := 0
		for i < len(text) {
			r, size := utf8.decode_rune_in_string(text[i:])
			is_space := (r == ' ' || r == '\n' || r == '\t' || r == '\r' || r == 10)

			if in_whitespace {
				if !is_space {
					in_whitespace = false
					in_word = true
				}
			} else if in_word {
				// stop when we hit next whitespace
				if is_space {
					pos += i - 1
					break loop
				}
			}

			i += size
		}

		pos += read_len
	}

	editor.cursor.position = clamp(pos, 0, total_size)
	line, col := line_col_from_cursor(editor)
	editor.cursor.desired_col_runes = col
	editor.cursor.has_desired_col = false
}


insert_text :: proc(editor: ^Editor, text: string) {
	if len(text) == 0 do return
	ptree.piece_table_insert(&editor.table, editor.cursor.position, text)
	editor.cursor.position += len(text)
	editor.cursor.has_desired_col = false
}

delete_text :: proc(editor: ^Editor, forward: bool) {
	if forward {
		if editor.cursor.position < editor.table.root.subtree_size {
			remaining := editor.table.root.subtree_size - editor.cursor.position
			text := ptree.piece_table_substring(
				&editor.table,
				editor.cursor.position,
				min(remaining, 4),
			)
			defer delete(text)

			if len(text) > 0 {
				r, size := utf8.decode_rune_in_string(text)
				if r != utf8.RUNE_ERROR {
					ptree.piece_table_delete(&editor.table, editor.cursor.position, size)
				}
			}
		}
	} else {
		if editor.cursor.position > 0 {
			text := ptree.piece_table_substring(&editor.table, 0, editor.cursor.position)
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
				editor.cursor.position = last_rune_start
			}
		}
	}
	editor.cursor.has_desired_col = false
}


line_col_from_cursor :: proc(editor: ^Editor) -> (line: int, col_runes: int) {
	if editor.cursor.position == 0 {
		return 0, 0
	}
	line_num := ptree.get_line_number_from_offset(&editor.table, editor.cursor.position)
	//TODO add function to do this without string building
	line_str, ok := ptree.get_line(&editor.table, line_num)
	defer delete(line_str)
	if !ok {
		return 0, 0
	}

	start_pos, _, ok2 := ptree.get_line_offset_range(&editor.table, line_num)
	if !ok2 {
		return 0, 0
	}

	// Compute column as rune offset within the line
	byte_offset_in_line := editor.cursor.position - start_pos
	col_runes = 0
	total_bytes := 0

	for r in line_str {
		rune_bytes := utf8.rune_size(r)
		if total_bytes + rune_bytes > byte_offset_in_line {
			break
		}
		total_bytes += rune_bytes
		col_runes += 1
	}

	return line_num, col_runes
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


render_editor :: proc(editor: ^Editor) {
	editor.viewport_width = f32(rl.GetScreenWidth())
	editor.viewport_height = f32(rl.GetScreenHeight())
	cursor_line, cursor_col_runes := line_col_from_cursor(editor)

	cursor_y: f32 = f32(cursor_line) * editor.line_height
	cursor_x: f32 = 0.0

	if cursor_line < editor.table.root.subtree_lines {
		line_text, ok := ptree.get_line(&editor.table, cursor_line)
		defer delete(line_text)

		if ok && cursor_col_runes > 0 {
			// Measure text up to cursor position
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
				// If cursor is past the end of the line, measure the whole line
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
	// Vertical scrolling
	if cursor_y < editor.scroll_offset_y {
		editor.scroll_offset_y = cursor_y
	} else if cursor_y >= editor.scroll_offset_y + editor.viewport_height - editor.line_height {
		editor.scroll_offset_y = cursor_y - editor.viewport_height + editor.line_height
	}

	// Horizontal scrolling
	available_width := editor.viewport_width
	if editor.show_line_numbers {
		available_width -= editor.line_number_width
	}

	if cursor_x < editor.scroll_offset_x {
		editor.scroll_offset_x = cursor_x
	} else if cursor_x >= editor.scroll_offset_x + available_width {
		editor.scroll_offset_x = cursor_x - available_width
	}

	render_text(editor)

	// Draw cursor
	if editor.cursor_visible {
		text_offset_x: f32 = 0
		if editor.show_line_numbers {
			text_offset_x = editor.line_number_width
		}

		cursor_screen_x := text_offset_x + cursor_x - editor.scroll_offset_x
		cursor_screen_y := cursor_y - editor.scroll_offset_y

		rl.DrawRectangle(i32(cursor_screen_x), i32(cursor_screen_y), 2, editor.font_size, rl.GREEN)
	}

	// Status bar - display 1-indexed
	status_y := editor.viewport_height
	rl.DrawRectangle(
		0,
		i32(status_y - editor.status_bar_height),
		i32(editor.viewport_width),
		40,
		{40, 40, 40, 255},
	)

	line_nums_status := editor.show_line_numbers ? "ON" : "OFF"
	status_text := fmt.aprintf(
		"Position: %d | Line: %d, Col: %d | Line Numbers: %s | Ctrl+S: Save, Ctrl+L: Toggle Line Numbers | desired: %d",
		editor.cursor.position,
		cursor_line + 1,
		cursor_col_runes + 1,
		line_nums_status,
		editor.cursor.desired_col_runes,
	)
	defer delete(status_text)
	cstring_status := strings.clone_to_cstring(status_text, context.temp_allocator)
	rl.DrawTextEx(
		editor.font,
		cstring_status,
		{10, status_y - editor.status_bar_height},
		30,
		0,
		rl.GRAY,
	)
}

render_text :: proc(editor: ^Editor) {
	line_height := editor.line_height
	first_visible := int(editor.scroll_offset_y / line_height)
	if first_visible < 1 do first_visible = 0

	last_visible := int((editor.scroll_offset_y + editor.viewport_height) / line_height) + 1
	if last_visible > editor.table.root.subtree_lines {
		last_visible = editor.table.root.subtree_lines
	}
	text_offset_x: f32 = 0

	if editor.show_line_numbers {
		text_offset_x = editor.line_number_width

		// draw line number background
		rl.DrawRectangle(
			0,
			0,
			i32(editor.line_number_width),
			i32(editor.viewport_height),
			{30, 30, 30, 255},
		)

		// separator line
		rl.DrawLine(
			i32(editor.line_number_width - 1),
			0,
			i32(editor.line_number_width - 1),
			i32(editor.viewport_height),
			{50, 50, 50, 255},
		)
	}

	for line_idx in first_visible ..< last_visible {
		y := f32(line_idx) * line_height - editor.scroll_offset_y

		line_text, _ := ptree.get_line(&editor.table, line_idx)
		defer delete(line_text)

		// Remove trailing newline before rendering
		line_without_newline := strings.trim_right(line_text, "\n")
		cstring_line := strings.clone_to_cstring(line_without_newline)
		defer delete(cstring_line)

		rl.DrawTextEx(
			editor.font,
			cstring_line,
			rl.Vector2{text_offset_x - editor.scroll_offset_x, y},
			f32(editor.font_size),
			0,
			rl.WHITE,
		)
		// line numbers
		if editor.show_line_numbers {
			line_num_text := fmt.aprintf("%d", line_idx + 1)
			defer delete(line_num_text)
			cstring_line_num := strings.clone_to_cstring(line_num_text, context.temp_allocator)
			text_width :=
				rl.MeasureTextEx(editor.font, cstring_line_num, f32(editor.font_size), 0).x
			line_num_x := editor.line_number_width - text_width - 5
			rl.DrawTextEx(
				editor.font,
				cstring_line_num,
				rl.Vector2{line_num_x, y},
				f32(editor.font_size),
				0,
				{120, 120, 120, 255},
			)
		}

	}

}

main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				for _, entry in track.allocation_map {
					fmt.eprintf("%v leaked %v bytes\n", entry.location, entry.size)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	args := os.args
	if len(args) < 2 {
		fmt.println("Usage: raylib-editor <filename>")
		return
	}
	filename := args[1]
	rl.SetConfigFlags(rl.ConfigFlags{.WINDOW_RESIZABLE})
	rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, rl.TextFormat("HM-EDITOR: %s", filename))
	defer rl.CloseWindow()
	rl.SetTargetFPS(75)
	editor: Editor
	editor_init(&editor, "./NotoSansJP-Regular.ttf", filename)
	defer editor_cleanup(&editor)

	for !rl.WindowShouldClose() {
		handle_input(&editor)

		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{25, 25, 25, 255})
		render_editor(&editor)
		rl.DrawText(
			rl.TextFormat("%d", rl.GetFPS()),
			cast(i32)editor.viewport_width - 80,
			0,
			20,
			rl.RED,
		)
		rl.EndDrawing()
	}

}
