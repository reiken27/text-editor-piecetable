package main

import c "core:c"
import fmt "core:fmt"
import mem "core:mem"
import os2 "core:os/os2"
import slice "core:slice"
import strings "core:strings"
import time "core:time"
import utf8 "core:unicode/utf8"
import ts "odin-tree-sitter"
import ts_odin "odin-tree-sitter/parsers/odin"
import ptree "piecetable"
import rl "vendor:raylib"

Treesitter_tree :: struct {
	ts_tree:         ts.Tree,
	highlight_query: ts.Query,
	query_cursor:    ts.Query_Cursor,
	capture_colors:  map[u32]rl.Color,
	ts_parser:       ts.Parser,
	ts_language:     ts.Language,
	highlights:      [dynamic]Highlight,
	ts_dirty:        bool,
}

Highlight :: struct {
	start_byte: int,
	end_byte:   int,
	color:      rl.Color,
}

TextSegment :: struct {
	text:  string,
	color: rl.Color,
}

treesitter_init :: proc(editor: ^Editor) -> bool {
	editor := editor
	editor.ts_parser = ts.parser_new()
	if editor.ts_parser == nil {
		return false
	}

	editor.ts_language = ts_odin.tree_sitter_odin()
	if editor.ts_language == nil {
		ts.parser_delete(editor.ts_parser)
		editor.ts_parser = nil
		return false
	}

	ok := ts.parser_set_language(editor.ts_parser, editor.ts_language)
	if !ok {
		fmt.println("Version mismatch between tree-sitter-odin and tree-sitter")
		ts.parser_delete(editor.ts_parser)
		editor.ts_parser = nil
		editor.ts_language = nil
		return false
	}
	editor.highlights = make([dynamic]Highlight)
	editor.ts_tree = nil
	editor.ts_dirty = true
	editor.query_cursor = ts.query_cursor_new()
	query, err_offset, err := ts.query_new(editor.ts_language, ts_odin.HIGHLIGHTS)
	if err != nil {
		fmt.printf("Could not create highlights query: %v at %v\n", err, err_offset)
		return false
	}
	editor.highlight_query = query


	for i in 0 ..< ts.query_capture_count(query) {
		name := ts.query_capture_name_for_id(query, u32(i))
		editor.capture_colors[u32(i)] = get_color_for_capture(name)
	}
	return true
}


number: rl.Color = {0x91, 0xD8, 0x6D, 255}
variable: rl.Color = {255, 255, 255, 255}
field: rl.Color = {156, 220, 254, 255}
type: rl.Color = {0xF2, 0x9C, 0x14, 255}
include: rl.Color = {0x13, 0x99, 0x87, 255}
namespace: rl.Color = {220, 220, 170, 255}
operator: rl.Color = {0xF2, 0x9C, 0x14, 255}
keyword: rl.Color = {0x0E, 0xD5, 0xB6, 255}
spell: rl.Color = {220, 220, 170, 255}
comment: rl.Color = {0x8A, 0x87, 0x8C, 255}
conditional: rl.Color = {197, 134, 192, 255}
parameter: rl.Color = {0xFE, 0xE5, 0x6C, 255}
function: rl.Color = {0xFE, 0xE5, 0x6C, 255}
repeat: rl.Color = {0x16, 0x8A, 0x7A, 255}
string_type: rl.Color = {237, 153, 21, 255}
function_call: rl.Color = {0x16, 0x8A, 0x7A, 255}
punctuation_delimeter: rl.Color = {147, 161, 161, 255}
punctuation_bracket: rl.Color = {255, 255, 255, 255}
string_escape: rl.Color = {255, 121, 198, 255}
keyword_function: rl.Color = {0xF2, 0x9C, 0x14, 255}
keyword_operator: rl.Color = {0xF2, 0x9C, 0x14, 255}
error_type: rl.Color = {0xFF, 0x00, 0x00, 0xff}
punctuation_special: rl.Color = {0xFF, 0xff, 0x00, 0xff}
preproc: rl.Color = {0xFE, 0xE5, 0x6C, 0xff}
boolean: rl.Color = {0xF2, 0x9C, 0x14, 0xff}
storageclass: rl.Color = {0x16, 0x8A, 0x7A, 0xff}
constant: rl.Color = {0xF2, 0x9C, 0x14, 0xff}
attribute: rl.Color = {0xF2, 0x9C, 0x14, 0xFF}
character: rl.Color = {0x00, 0xff, 0xff, 0xff}
keyword_return: rl.Color = {0x16, 0x8A, 0x7A, 0xff}
float_type: rl.Color = {0x91, 0xD8, 0x6D, 0xff}
function_special: rl.Color = {0xF2, 0x9C, 0x14, 0xff} //function.special
background: rl.Color = {0x26, 0x29, 0x33, 0xff}
conditional_ternary: rl.Color = {0x26, 0x29, 0x33, 0xff}
type_builtin: rl.Color = {0x26, 0x29, 0x33, 0xff}
function_macro: rl.Color = {0x26, 0x29, 0x33, 0xff}
label: rl.Color = {0x26, 0x29, 0x33, 0xff}
variable_builtin: rl.Color = {0x26, 0x29, 0x33, 0xff}

get_color_for_capture :: proc(capture_name: string) -> rl.Color {
	switch capture_name {
	case "number":
		return number
	case "variable":
		return variable
	case "field":
		return field
	case "type":
		return type
	case "comment":
		return comment
	case "string":
		return string_type
	case "namespace":
		return namespace
	case "operator":
		return operator
	case "keyword":
		return keyword
	case "spell":
		return spell
	case "function.call":
		return function_call
	case "keyword.operator":
		return keyword_operator
	case "conditional":
		return conditional
	case "function":
		return function
	case "parameter":
		return parameter
	case "repeat":
		return repeat
	case "keyword.function":
		return function_call
	case "punctuation.delimiter":
		return punctuation_delimeter
	case "punctuation.bracket":
		return punctuation_bracket
	case "string.escape":
		return string_escape
	case "include":
		return include
	case "error":
		return error_type
	case "punctuation.special":
		return punctuation_special
	case "preproc":
		return preproc
	case "boolean":
		return boolean
	case "constant":
		return constant
	case "constant.builtin":
		return constant
	case "float":
		return float_type
	case "storageclass":
		return storageclass
	case "character":
		return character
	case "keyword.return":
		return keyword_return
	case "attribute":
		return attribute
	case "type.builtin":
		return type_builtin
	case "function.macro":
		return function_macro
	case "label":
		return label
	case "conditional.ternary":
		return conditional_ternary
	case "variable.builtin":
		return variable_builtin
	case:
		fmt.println("name: ", capture_name)
		return rl.Color{255, 255, 255, 255}
	}
}


treesitter_update :: proc(editor: ^Editor, source: string) -> bool {
	editor := editor
	if editor.ts_parser == nil || editor.ts_language == nil {
		return false
	}

	if editor.ts_tree != nil {
		ts.tree_delete(editor.ts_tree)
		editor.ts_tree = nil
	}

	editor.ts_tree = ts.parser_parse_string(editor.ts_parser, source)
	if editor.ts_tree == nil {
		return false
	}

	update_highlights(editor, source)
	editor.ts_dirty = false
	input := ts.Input {
		encoding = .UTF8,
	}
	ts.parser_parse(editor.treesitter.ts_parser, editor.treesitter.ts_tree, input)
	return true
}


update_highlights :: proc(editor: ^Editor, source: string) {
	tree := &editor.treesitter

	clear(&tree.highlights)

	root := ts.tree_root_node(tree.ts_tree)
	ts.query_cursor_exec(editor.query_cursor, editor.highlight_query, root)

	for match, cap_idx in ts.query_cursor_next_capture(editor.query_cursor) {
		cap := match.captures[cap_idx]
		if len(ts.query_predicates_for_pattern(editor.highlight_query, u32(match.pattern_index))) >
		   0 {
			continue
		}

		color := editor.capture_colors[cap.index]
		append(
			&tree.highlights,
			Highlight {
				start_byte = int(ts.node_start_byte(cap.node)),
				end_byte = int(ts.node_end_byte(cap.node)),
				color = color,
			},
		)
	}
}
