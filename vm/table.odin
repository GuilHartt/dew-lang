package vm

import "base:runtime"

TABLE_MAX_LOAD :: 0.75

Entry :: struct {
    key: ^ObjectString,
    value: Value,
}

Table :: struct {
    entries: []Entry,
    count: int,
}

init_table :: proc(table: ^Table) {
    table.entries = nil
    table.count = 0
}

free_table :: proc(table: ^Table) {
    if table.entries != nil {
        delete(table.entries)
    }
    init_table(table)
}

@(private="file")
find_entry :: proc(entries: []Entry, key: ^ObjectString) -> ^Entry {
    index := key.hash % u32(len(entries))
    tombstone: ^Entry

    for {
        entry := &entries[index]
        if entry.key == nil {
            if is_nil(entry.value) {
                return tombstone != nil ? tombstone : entry
            } else {
                if tombstone == nil do tombstone = entry
            }
        } else if entry.key == key {
            return entry
        }

        index = (index + 1) % u32(len(entries))
    }
}

table_get :: proc "contextless" (table: ^Table, key: ^ObjectString) -> (Value, bool) {
    context = runtime.default_context()
    if table.count == 0 do return val_nil(), false

    entry := find_entry(table.entries, key)
    if entry.key == nil do return val_nil(), false

    return entry.value, true
}

@(private="file")
adjust_capacity :: proc(table: ^Table, capacity: int) {
    entries := make([]Entry, capacity)

    for i in 0..<capacity {
        entries[i].value = val_nil()
    }

    table.count = 0
    for i in 0..<len(table.entries) {
        entry := &table.entries[i]
        if entry.key == nil do continue

        dest := find_entry(entries, entry.key)
        dest.key = entry.key
        dest.value = entry.value
        table.count += 1
    }

    if table.entries != nil do delete(table.entries)
    table.entries = entries
}

table_set :: proc "contextless" (table: ^Table, key: ^ObjectString, value: Value) -> bool {
    context = runtime.default_context()

    if cap := len(table.entries); f64(table.count + 1) > f64(cap) * TABLE_MAX_LOAD {
        capacity := cap < 8 ? 8 : cap * 2
        adjust_capacity(table, capacity)
    }

    entry := find_entry(table.entries, key)
    is_new_key := entry.key == nil
    if is_new_key && is_nil(entry.value) do table.count += 1

    entry.key = key
    entry.value = value
    return is_new_key
}

table_delete :: proc "contextless" (table: ^Table, key: ^ObjectString) -> bool {
    context = runtime.default_context()
    
    if table.count == 0 do return false

    entry := find_entry(table.entries, key)
    if entry.key == nil do return false

    entry.key = nil
    entry.value = val_bool(true)
    return true
}

@(private="file")
table_add_all :: proc(from: ^Table, to: ^Table) {
    for i in 0..<len(from.entries) {
        entry := &from.entries[i]
        if entry.key != nil {
            table_set(to, entry.key, entry.value)
        }
    }
}

table_find_string :: proc(table: ^Table, chars: string, hash: u32) -> ^ObjectString {
    if table.count == 0 do return nil

    index := hash % u32(len(table.entries))
    for {
        entry := &table.entries[index]

        if entry.key == nil {
            if is_nil(entry.value) do return nil
        } else if entry.key.hash == hash && entry.key.chars == chars {
            return entry.key
        }

        index = (index + 1) % u32(len(table.entries))
    }
}

@(private)
table_remove_white :: proc(table: ^Table) {
    for i in 0..<len(table.entries) {
        entry := &table.entries[i]
        if entry.key != nil && !entry.key.is_marked {
            table_delete(table, entry.key)
        }
    }
}

@(private)
mark_table :: proc(vm: ^VM, table: ^Table) {
    for i in 0..<len(table.entries) {
        entry := &table.entries[i]
        mark_object(vm, entry.key)
        mark_value(vm, entry.value)
    }
}