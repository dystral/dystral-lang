# Composition-Based Type System (type/object/contract/skill/enum)

## Goal
Replace class/inheritance OOP with the composition model from the spec: `type` (state), `object` (singleton), `contract` (API), `skill` (reusable behavior), with `:` for contract implementation and `+` for skill composition. No implementation inheritance anywhere.

## Tasks

- [x] **1. Lexer/AST: new declaration keywords** — Add tokens & AST nodes for `type`, `object`, `contract`, `skill`, `implement`; header clauses `:` (contract list) and `+` (skill list). Remove/deprecate `class`, `open`, `abstract`, `extends`, `override`. → Verify: `src/frontend/parser` parses all spec examples without error; old `class` syntax rejected.

- [x] **2. Parser: header grammar** — Parse `type Name(params) : C1, C2 + S1, S2 { ... }`, `contract Name { fun ... }` (bodyless funs only), `skill Name : C1 { ... }`, `object Name { ... }`. → Verify: AST round-trip test for `type Button : Drawable, Serializable + Clickable + Hoverable`.

- [x] **3. Type checker: contract rules** — `contract` = methods only: reject state, constructors, bodies, instantiation. Types implementing a contract must provide every method with the `implement` keyword (`override` is removed with `class`). → Verify: negative tests — contract with `val` fails; `type` missing an implementation fails.

- [x] **4. Type checker: skill rules** — `skill` = no state, no constructors, no instantiation; required contracts (`:`) are *not* implemented, only callable. Resolve `draw()` inside `Shadow` against required contracts. → Verify: `skill Shadow : Drawable { fun render() { draw() } }` type-checks.

- [x] **5. Type checker: composition validation** — A `type` composing `+ Skill` must implement every contract the skill requires; error: `Skill 'Shadow' requires contract 'Drawable'. Type 'Button' does not implement it.` → Verify: spec's invalid example produces exactly this error.

- [x] **6. Type checker: skill conflict resolution** — Two composed skills declaring the same member → ambiguity error until the type resolves it with `implement`; `SkillName.member()` qualified call inside the implementation. → Verify: `MouseInput`/`TouchInput` `click()` example fails without `implement`, passes with `MouseInput.click()`.

- [x] **7. Exceptions via `Throwable` contract** — Replace `Exception` base-class checks in `src/core/type_checker/infer_stmt.zig:133,159` with contract-implementation checks (`throw`/`catch` accept any type implementing `Throwable`). → Verify: `throw AssertionException("...")` and `catch (e: Throwable)` from the spec compile; throwing a non-`Throwable` fails.

- [x] **8. Singleton `object` semantics** — Enforce single instance; `object` members accessed via `Logger.info(...)`; reject instantiation. → Verify: `Logger.info("x")` works; `Logger()` is an error.

- [x] **9. Backend: C transpiler support** — Lower `type`→struct+methods, `object`→global instance, skill methods→inlined/static functions on the consuming type, contract calls→direct dispatch (no vtables needed for now). Remove inherited-member emission in `src/backend/c_transpiler`. → Verify: spec's `Button` example compiles to C and runs.

- [x] **10. Migrate samples & stdlib; delete inheritance** — Remove inheritance logic from `infer_decl.zig:247-290` and `infer_expr.zig`/`infer_when.zig` hierarchy checks; rewrite `samples/oop.ae`, `inheritance_sample.ae`, `hybrid_conflict.ae` and any `src/std/*.ae` using classes. → Verify: `zig build` + full sample suite passes; no `class`/`extends` remains in `src/`.

## Done When
- [x] Every code example in the spec (valid and invalid) behaves as specified.
- [x] No inheritance machinery remains (no superclasses, `final`/inheritance errors, Exception hierarchy).
- [x] Full test suite + samples pass.

## Notes
- Order matters: parser (1–2) → checker rules (3–7) can partly parallelize → backend (9) → migration (10) last.
- Keep `when` type-check working using contract conformance instead of hierarchy.
- `enum` listed but unspecified — treat as existing enum support; only ensure it coexists with the new keywords.
