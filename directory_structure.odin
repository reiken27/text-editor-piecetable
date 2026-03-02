package main

import c "core:c"
import fmt "core:fmt"
import mem "core:mem"
import os "core:os"
import os2 "core:os/os2"
import slice "core:slice"
import strings "core:strings"
import time "core:time"
import utf8 "core:unicode/utf8"
import ts "odin-tree-sitter"
import ptree "piecetable"
import mu "vendor:microui"
import rl "vendor:raylib"

// get_current_dir :: proc() {
// 	result, err := os2.read_directory_by_path("/home/reiken27", 0, context.temp_allocator)
// 	if err != os2.General_Error.None {
// 		fmt.println(err)
// 		return
// 	}
// 	for i in result {
// 		fmt.printfln("%-v | %-v", i.type, i.name)
// 	}
// }

// file_explorer :: struct {}
