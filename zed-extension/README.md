# zed-aether

[Aether](https://github.com/leodouglas/aether) language support for [Zed](https://github.com/zed-industries/zed).

## Features

- Syntax highlighting for `.ae` files via [tree-sitter-aether](../tree-sitter-aether)
  (a fork of tree-sitter-kotlin extended with Aether syntax)
- ES6-style imports (`import { X } from "mod"`), `test` and `lib` blocks,
  ternary expressions, union types (`Int | Null`), bare `try`/`catch`
- Bracket matching and auto-closing pairs
- Comment toggling (`//` and `/* */`)
- Symbol outline (classes, objects, functions, properties)

## Limitations

- No language server (LSP) yet: no autocomplete, go-to-definition or diagnostics.
- Two declarations on the same line without a newline between them
  (e.g. `} class Foo {`) don't parse, since the underlying Kotlin grammar
  requires statement separators.

## Installing (dev extension)

1. Clone this repository.
2. In Zed, open the command palette and run `zed: install dev extension`.
3. Select this directory (`zed-extension/`).

Zed will download and compile the tree-sitter grammar on first install.
