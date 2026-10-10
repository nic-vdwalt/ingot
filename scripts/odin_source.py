#!/usr/bin/env python3
"""Shared Odin text helpers for the Python guards that still scan source.

The AST-based gates live in tools/odingate; these two helpers remain for the
regex guards whose rules need no parser (design tokens, web startup).
"""


def mask_source(source: str) -> str:
    output = list(source)
    index = 0
    block_depth = 0
    quote = ""
    raw = False
    while index < len(source):
        char = source[index]
        next_char = source[index + 1] if index + 1 < len(source) else ""
        if block_depth:
            if char == "/" and next_char == "*":
                output[index] = output[index + 1] = " "
                block_depth += 1
                index += 2
            elif char == "*" and next_char == "/":
                output[index] = output[index + 1] = " "
                block_depth -= 1
                index += 2
            else:
                if char != "\n":
                    output[index] = " "
                index += 1
            continue
        if quote:
            if char != "\n":
                output[index] = " "
            if raw:
                if char == quote:
                    quote = ""
                    raw = False
            elif char == "\\" and index + 1 < len(source):
                if source[index + 1] != "\n":
                    output[index + 1] = " "
                index += 2
                continue
            elif char == quote:
                quote = ""
            index += 1
            continue
        if char == "/" and next_char == "/":
            while index < len(source) and source[index] != "\n":
                output[index] = " "
                index += 1
            continue
        if char == "/" and next_char == "*":
            output[index] = output[index + 1] = " "
            block_depth = 1
            index += 2
            continue
        if char in ('"', "'"):
            output[index] = " "
            quote = char
            index += 1
            continue
        if char == "`":
            output[index] = " "
            quote = char
            raw = True
            index += 1
            continue
        index += 1
    return "".join(output)


def line_number(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1
