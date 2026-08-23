# Deez client architecture

Deez keeps one source of truth for study behavior while allowing multiple user interfaces.

## Repository boundaries

The core repository is `chrisbirster/deez`.

Planned client repositories:

- `chrisbirster/deez-web` — SolidJS web UI
- `chrisbirster/deez-mobile` — mobile UI (StingJS selection pending an exact project/package reference)
- `chrisbirster/deez-desktop` — desktop shell, with Wails v3 as the leading candidate
- `chrisbirster/deez-tui` — pure Zig TUI

Client repositories do not reimplement Deez domain behavior.

## Core ownership

The Zig core owns:

- SQLite and MongoDB/Bongo persistence
- immutable review history
- FSRS scheduling
- note-type definitions and validation
- note-to-card generation
- stable generated-card identity
- template rendering
- the structured `RenderedCard` interaction contract
- `.nut` and `.sack` import/export
- media identity and storage

The core is the authority even when a client has its own view state or caches.

## Local daemon

Graphical clients communicate with Deez through a local HTTP daemon implemented in Zig with `http.zig`.

The first public API is versioned beneath:

```text
/api/v1
```

The daemon binds to loopback only by default. A future remote/server mode must be an explicit feature rather than changing the security properties of local Deez.

Initial API areas:

```text
/api/v1/health
/api/v1/version
/api/v1/capabilities
/api/v1/decks
/api/v1/decks/:deck_id
/api/v1/decks/:deck_id/notes
/api/v1/decks/:deck_id/cards
/api/v1/notes/:note_id
/api/v1/notes/preview
/api/v1/cards/:card_id
/api/v1/cards/:card_id/render
```

Study/review, media, and portable-file endpoints follow once deck/note/card editing is stable.

## Notes versus cards

Clients must make the distinction visible:

```text
Note (editable source)
        |
        v
card generation
        |
        v
Card(s) (study/scheduling identities)
```

Users normally edit a note. Deez regenerates the corresponding card content while preserving stable generated-card identities where the note type permits it.

Generated cards are shown for preview, scheduling state, and review history. They are not independent copies of note content to edit.

Legacy standalone cards remain legacy editable content until migrated.

## Render contract

Clients consume the client-facing renderer:

```text
RenderedCard {
    front,
    back,
    css,
    interaction,
}
```

Interaction variants are:

```text
reveal
type_answer
single_choice
multiple_choice
ordering
image_occlusion
```

A client must never parse terminal-formatted text to determine how a card behaves.

## Web

The web client is a separate SPA repository.

Technology direction:

- SolidJS 2.x prerelease/stable line, following `https://v2.solidjs.com/`
- current Solid 2-compatible router line
- Vite
- `@solidjs/vite-plugin` for the Solid 2 compiler/toolchain
- TypeScript
- CSS Modules/component-scoped CSS
- visual/CSS organization inspired by `syntaxfm/website`
- no Tailwind dependency by default

Because the backend is the local Deez daemon, the web client does not need SolidStart as its application backend.

First UI milestone:

1. daemon connection/status
2. deck/nut browser
3. deck detail
4. Notes list
5. note editor
6. generated-card preview
7. Cards inspection view

Study, media management, import/export, statistics, and review-history UI come after the editor foundation.

## Desktop

Wails v3 is the leading shell candidate because it provides native OS WebViews, cross-platform packaging, and a Go-to-JavaScript bridge while allowing reuse of the web frontend.

Deez domain behavior should not move into Go. A Wails shell should primarily own native window/app integration and lifecycle, and launch/connect to the Deez Zig core/daemon.

A thinner custom Go or Zig WebView shell remains an alternative if Wails adds unnecessary complexity.

## TUI

The TUI should be pure Zig.

Because both projects are Zig, the preferred mode is to depend directly on the Deez core module rather than paying an HTTP boundary for every operation. A daemon-backed mode may be useful when controlling an already-running Deez process.

The TUI must use the same note/card/render/scheduler APIs as the CLI and graphical clients.

## Mobile

The selected mobile direction is StingJS, but implementation is intentionally blocked until the exact StingJS project/package is identified. Do not silently substitute another mobile framework.

Regardless of UI framework, mobile must consume the same Deez domain contract and must not implement its own scheduler or note-generation rules.

## API evolution

Clients are separate repositories, so the HTTP API is a compatibility boundary.

Rules:

- version wire endpoints
- use stable IDs for decks, notes, cards, choices, ordering items, and occlusion masks
- use tagged JSON interaction shapes
- return machine-readable error codes
- expose capability discovery
- add fields compatibly where possible
- make breaking wire changes in a new API version

See issue #95 for the first daemon/API implementation milestone and issue #94 for the web-first client milestone.
