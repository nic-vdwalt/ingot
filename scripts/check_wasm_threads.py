#!/usr/bin/env python3

import argparse
import json


def unsigned_leb(data, offset):
    value = 0
    shift = 0
    while True:
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if byte & 0x80 == 0:
            return value, offset
        shift += 7


def name(data, offset):
    length, offset = unsigned_leb(data, offset)
    return data[offset:offset + length].decode("utf-8"), offset + length


def sections(data):
    offset = 8
    while offset < len(data):
        section_id = data[offset]
        size, payload = unsigned_leb(data, offset + 1)
        yield section_id, data[payload:payload + size]
        offset = payload + size


def limits(data, offset):
    flags, offset = unsigned_leb(data, offset)
    minimum, offset = unsigned_leb(data, offset)
    maximum = None
    if flags & 1:
        maximum, offset = unsigned_leb(data, offset)
    return flags, minimum, maximum, offset


def memory_import(data):
    count, offset = unsigned_leb(data, 0)
    for _ in range(count):
        module, offset = name(data, offset)
        field, offset = name(data, offset)
        kind = data[offset]
        offset += 1
        if kind == 0:
            _, offset = unsigned_leb(data, offset)
        elif kind == 1:
            offset += 1
            _, _, _, offset = limits(data, offset)
        elif kind == 2:
            flags, minimum, maximum, offset = limits(data, offset)
            return module, field, flags, minimum, maximum
        elif kind == 3:
            offset += 2
        else:
            raise ValueError(f"unknown import kind {kind}")
    return None


def exports(data):
    count, offset = unsigned_leb(data, 0)
    result = set()
    for _ in range(count):
        export_name, offset = name(data, offset)
        offset += 1
        _, offset = unsigned_leb(data, offset)
        result.add(export_name)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("module")
    args = parser.parse_args()
    data = open(args.module, "rb").read()
    if data[:8] != b"\0asm\x01\0\0\0":
        raise SystemExit("not a WebAssembly module")
    imported_memory = None
    export_names = set()
    target_features = b""
    for section_id, payload in sections(data):
        if section_id == 2:
            imported_memory = memory_import(payload)
        elif section_id == 7:
            export_names = exports(payload)
        elif section_id == 0:
            section_name, offset = name(payload, 0)
            if section_name == "target_features":
                target_features = payload[offset:]
    if imported_memory is None:
        raise SystemExit("threaded module does not import memory")
    module, field, flags, minimum, maximum = imported_memory
    if (module, field) != ("env", "memory"):
        raise SystemExit(f"unexpected memory import {module}.{field}")
    if flags & 2 == 0:
        raise SystemExit("imported memory is not shared")
    if maximum is None:
        raise SystemExit("shared memory has no maximum")
    required_exports = {
        "__stack_pointer",
        "ingot_box3d_worker_dispatch",
        "ingot_box3d_worker_step",
    }
    missing = required_exports - export_names
    if missing:
        raise SystemExit(f"missing worker exports: {sorted(missing)}")
    if b"atomics" not in target_features:
        raise SystemExit("module does not advertise atomics")
    print(json.dumps({
        "memory": {"minimum": minimum, "maximum": maximum, "shared": True},
        "worker_exports": sorted(required_exports),
        "atomics": True,
    }, indent=2))


if __name__ == "__main__":
    main()
