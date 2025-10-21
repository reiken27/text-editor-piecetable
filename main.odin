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

Cursor :: struct {
	position:          int,
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
	editor.line_height = f32(editor.font_size) * 1.2
	editor.cursor_visible = true
	editor.viewport_width = 1920
	editor.viewport_height = 1080
	editor.status_bar_height = 40
	editor.desired_col_runes = -1
	editor.has_desired_col = false
	editor.show_line_numbers = true
	editor.line_number_width = 60
	load_file(editor, filename)
	editor.file_name = filename
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

editor_cleanup :: proc(editor: ^Editor) {
	ptree.piece_table_destroy(&editor.table)
	if editor.font.texture.id != rl.GetFontDefault().texture.id {
		rl.UnloadFont(editor.font)
	}
	free_all(context.temp_allocator)
	free_all(context.allocator)
}

render_editor :: proc(editor: ^Editor) {
	editor := editor

	editor.viewport_width = f32(rl.GetScreenWidth())
	editor.viewport_height = f32(rl.GetScreenHeight())

	render_text(editor)

	if editor.cursor_visible {
		cursor_screen_x, cursor_screen_y := cursor_to_screen_pos(editor)
		rl.DrawRectangle(i32(cursor_screen_x), i32(cursor_screen_y), 2, editor.font_size, rl.GREEN)
	}
}


render_text :: proc(editor: ^Editor) {
	using editor

	text_x := line_number_width if show_line_numbers else 0
	text_y: f32 = 0

	total_len := table.root.subtree_size
	if total_len == 0 do return

	visible_start := max(0, int(scroll_offset_y / line_height) - 5)
	visible_end := int((scroll_offset_y + viewport_height) / line_height) + 5

	current_line := 0
	line_start_byte := 0
	y_pos: f32 = 0

	text := ptree.piece_table_substring(&table, 0, 5000)
	defer delete(text)

	for i := 0; i < len(text); {
		r, size := utf8.decode_rune_in_string(text[i:])

		is_newline := r == '\n'
		is_end := i + size >= len(text)

		if is_newline || is_end {
			line_end_byte := i + size if is_end else i

			if current_line >= visible_start && current_line <= visible_end {
				y_pos = f32(current_line) * line_height - scroll_offset_y

				if show_line_numbers {
					line_num_text := fmt.tprintf("%4d", current_line + 1)
					rl.DrawTextEx(
						font,
						strings.clone_to_cstring(line_num_text, context.temp_allocator),
						{5, y_pos},
						f32(font_size),
						1,
						rl.Color{100, 100, 100, 255},
					)
				}

				if line_end_byte > line_start_byte {
					line_text := text[line_start_byte:line_end_byte]

					x_offset: f32 = text_x - scroll_offset_x
					byte_pos := line_start_byte

					for j := 0; j < len(line_text); {
						char_r, char_size := utf8.decode_rune_in_string(line_text[j:])
						char_str := line_text[j:j + char_size]

						// Determine color based on selection
						char_color := rl.WHITE

						// Draw the character
						rl.DrawTextEx(
							font,
							strings.clone_to_cstring(char_str, context.temp_allocator),
							{x_offset, y_pos},
							f32(font_size),
							1,
							char_color,
						)

						// Measure character width for next position
						char_width := rl.MeasureTextEx(
							font,
							strings.clone_to_cstring(char_str, context.temp_allocator),
							f32(font_size),
							1,
						)
						x_offset += char_width.x

						j += char_size
						byte_pos += char_size
					}
				}
			}

			current_line += 1
			line_start_byte = i + size
		}

		i += size
	}
}

cursor_to_line_col :: proc(editor: ^Editor) -> (line: int, col_runes: int) {
	total_len := editor.table.root.subtree_size
	if total_len == 0 || editor.cursor.position == 0 {
		return 0, 0
	}

	text := ptree.piece_table_substring(&editor.table, 0, min(editor.cursor.position, total_len))
	defer delete(text)

	line = 0
	col_runes = 0

	for i := 0; i < len(text); {
		r, size := utf8.decode_rune_in_string(text[i:])

		if r == '\n' {
			line += 1
			col_runes = 0
		} else {
			col_runes += 1
		}

		i += size
	}

	return line, col_runes
}


cursor_to_screen_pos :: proc(editor: ^Editor) -> (screen_x: f32, screen_y: f32) {
	line, col_runes := cursor_to_line_col(editor)

	screen_y = f32(line) * editor.line_height - editor.scroll_offset_y

	text_x := editor.line_number_width if editor.show_line_numbers else 0
	screen_x = text_x - editor.scroll_offset_x

	if col_runes > 0 {
		total_len := editor.table.root.subtree_size
		if total_len > 0 {
			text := ptree.piece_table_substring(&editor.table, 0, editor.cursor.position)
			defer delete(text)

			line_start := 0
			for i := len(text) - 1; i >= 0; i -= 1 {
				if text[i] == '\n' {
					line_start = i + 1
					break
				}
			}

			if line_start < len(text) {
				line_text := text[line_start:]
				text_width := rl.MeasureTextEx(
					editor.font,
					strings.clone_to_cstring(line_text, context.temp_allocator),
					f32(editor.font_size),
					0,
				)
				screen_x += text_width.x
			}
		}
	}

	return screen_x, screen_y
}


insert_text :: proc(editor: ^Editor, text: string) {
	if len(text) == 0 do return
	insert_pos := editor.cursor.position
	ptree.piece_table_insert(&editor.table, insert_pos, text)
	editor.cursor.position += len(text)
}

delete_text :: proc(editor: ^Editor, forward: bool) {

	total_len := editor.table.root.subtree_size

	if forward {
		if editor.cursor.position >= total_len do return

		text := ptree.piece_table_substring(&editor.table, editor.cursor.position, 1)
		defer delete(text)

		if len(text) > 0 {
			_, size := utf8.decode_rune_in_string(text)
			// Make sure we don't go past the end
			delete_len := min(size, total_len - editor.cursor.position)
			ptree.piece_table_delete(&editor.table, editor.cursor.position, delete_len)
		}
	} else {
		if editor.cursor.position == 0 do return

		bytes_to_check := min(4, editor.cursor.position) // UTF-8 max is 4 bytes
		text := ptree.piece_table_substring(
			&editor.table,
			editor.cursor.position - bytes_to_check,
			bytes_to_check,
		)
		defer delete(text)

		last_rune_start := 0
		last_rune_size := 1

		for i := 0; i < len(text); {
			_, size := utf8.decode_rune_in_string(text[i:])
			last_rune_start = i
			last_rune_size = size
			i += size
		}

		delete_pos := editor.cursor.position - last_rune_size
		ptree.piece_table_delete(&editor.table, delete_pos, last_rune_size)
		editor.cursor.position = delete_pos
	}

	editor.has_desired_col = false
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
		result := ptree.piece_table_undo(&editor.table)
		fmt.println("redo", result)

	}
	if rl.IsKeyDown(.LEFT_CONTROL) && rl.IsKeyPressed(.S) {
		result := save_file(editor)
		fmt.println("saved at:", editor.file_name)
	}

	// Toggle line numbers
	if rl.IsKeyDown(.LEFT_CONTROL) && rl.IsKeyPressed(.L) {
		editor.show_line_numbers = !editor.show_line_numbers
	}

}


save_file :: proc(editor: ^Editor) -> bool {
	if editor.table.root.subtree_size == 0 {
		return os.write_entire_file(editor.file_name, {})
	}

	content := ptree.piece_table_substring(&editor.table, 0, editor.table.root.subtree_size)

	data := transmute([]u8)content
	return os.write_entire_file(editor.file_name, data)
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
	rl.InitWindow(1280, 720, rl.TextFormat("HM-EDITOR: %s", filename))
	defer rl.CloseWindow()
	rl.SetTargetFPS(75000)

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
		free_all(context.allocator)
		free_all(context.temp_allocator)
	}
}


move_left :: proc(editor: ^Editor) {
	if editor.cursor.position == 0 do return

	bytes_to_check := min(4, editor.cursor.position)
	text := ptree.piece_table_substring(
		&editor.table,
		editor.cursor.position - bytes_to_check,
		bytes_to_check,
	)
	defer delete(text)

	last_rune_start := 0
	last_rune_size := 1

	for i := 0; i < len(text); {
		_, size := utf8.decode_rune_in_string(text[i:])
		last_rune_start = i
		last_rune_size = size
		i += size
	}

	editor.cursor.position -= last_rune_size
	editor.has_desired_col = false
}

move_right :: proc(editor: ^Editor) {
	total_len := editor.table.root.subtree_size
	if editor.cursor.position >= total_len do return

	// Get the next character
	text := ptree.piece_table_substring(
		&editor.table,
		editor.cursor.position,
		min(4, total_len - editor.cursor.position),
	)
	defer delete(text)

	if len(text) > 0 {
		_, size := utf8.decode_rune_in_string(text)
		editor.cursor.position += size
	}

	editor.has_desired_col = false
}

move_up :: proc(editor: ^Editor) {
	if editor.cursor.position == 0 do return

	current_line, current_col := cursor_to_line_col(editor)
	if current_line == 0 do return

	if !editor.has_desired_col {
		editor.desired_col_runes = current_col
		editor.has_desired_col = true
	}

	target_line := current_line - 1
	target_col := editor.desired_col_runes

	editor.cursor.position = line_col_to_byte_pos(editor, target_line, target_col)
}

move_down :: proc(editor: ^Editor) {
	total_len := editor.table.root.subtree_size
	if total_len == 0 do return

	current_line, current_col := cursor_to_line_col(editor)

	if !editor.has_desired_col {
		editor.desired_col_runes = current_col
		editor.has_desired_col = true
	}

	target_line := current_line + 1
	target_col := editor.desired_col_runes

	// Move to target position
	new_pos := line_col_to_byte_pos(editor, target_line, target_col)
	if new_pos != editor.cursor.position {
		editor.cursor.position = new_pos
	}
}

line_col_to_byte_pos :: proc(editor: ^Editor, target_line: int, target_col_runes: int) -> int {
	total_len := editor.table.root.subtree_size
	if total_len == 0 do return 0

	text := ptree.piece_table_substring(&editor.table, 0, total_len)
	defer delete(text)

	current_line := 0
	current_col := 0

	for i := 0; i < len(text); {
		if current_line == target_line && current_col == target_col_runes {
			return i
		}
		r, size := utf8.decode_rune_in_string(text[i:])

		if current_line == target_line && r == '\n' {
			return i
		}

		if r == '\n' {
			current_line += 1
			current_col = 0
		} else {
			current_col += 1
		}

		i += size

		if current_line == target_line && i >= len(text) {
			return i
		}
	}
	return len(text)
}
