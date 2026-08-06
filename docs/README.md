# Documentation

| Doc | When to read |
| :-- | :-- |
| [contributing.md](contributing.md) | First. Setup, ports, the gate, and the things that will bite you. |
| [architecture.md](architecture.md) | To see the whole shape and the decisions behind it. |
| [code-structure.md](code-structure.md) | Before adding a file. Where code goes and why. |
| [transport.md](transport.md) | Before touching `proto/`, or when a request fails in the client but not the server. |
| [testing.md](testing.md) | Before writing a test — particularly the "what not to test" list. |
| [observability.md](observability.md) | Before adding a log line. |

## Documentation policy

**Document rationale next to the pattern.** There is no separate decision log. When a design decision is made, the reasoning goes in the doc that covers that area, or in the doc comment on the code itself. A decision log rots because nothing forces it to be read; a paragraph above the code that surprised you gets read by the next person to touch it.

**Keep docs verifiable.** Reference specific file paths and type names. Prefer pointing at code over describing behaviour that can drift from it — `mise run check:doc-links` catches a path that stops resolving, but nothing catches a paragraph that quietly stopped being true.

**New cross-cutting pattern?** Create or update the doc, then add a row to the table in [CLAUDE.md](../CLAUDE.md) §2. A pattern nobody can find is a pattern nobody follows.
