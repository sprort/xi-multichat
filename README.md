# MultiChat

[![Latest Release](https://img.shields.io/github/v/release/sprort/xi-multichat?label=download)](https://github.com/sprort/xi-multichat/releases/latest)

An [Ashita v4](https://ashitaxi.com/) addon that splits FFXI's chat log into one multi-tab window: **LS1, LS2, Party, Tell, Say, Shout/Yell, Craft, Combat, NPC, SYS**.

**Read-only.** It reorganizes and recolors text your client already shows you. It never sends, blocks, injects, or modifies any packet, message, or game state, and has no effect on what anyone else sees — see [How chat is captured](#how-chat-is-captured).

Built and tested on HorizonXI; should work on any Ashita v4 server.

**[⬇ Download](https://github.com/sprort/xi-multichat/releases/latest/download/multichat.zip)** — extract into `Ashita/addons/`, then `/addon load multichat`.

## Features

**Channels**

- **Shout/Yell** — combined tab, each colored differently, with a Both/Shout/Yell filter
- **Craft** — synthesis results, fishing, and skill-ups
- **Combat** — hits, misses, crits, abilities, casting, status effects, recovery, defeats, drops, experience, level changes
- **NPC** — dialogue (with speaker name) and quest reward items
- **Tell** — direction shown in the username: `>>Name` sent, `Name>>` received
- **Party** — also captures emotes between party/alliance members
- **SYS** — system broadcasts, Auction House, delivery box, and the **Checker** / **conquest** addons' output, each labeled by source
- Achievements and hardcore milestones broadcast to *every* tab in a distinct color

**Display**

- Colored by message type and by who's acting (you, party, pets/summons, enemies, other players)
- Item names highlighted; per-channel colors for LS1/LS2/Party/Tell/Say
- Split view (side-by-side or stacked) and multi-window pop-out — pop-outs restore their position after a reload
- Flashing alert for unseen messages (visual only, no sound); click a line to copy it
- 5000 lines per channel, duplicate suppression, settings persist across sessions
- Stays hidden until you're logged in — safe to auto-load from `default.txt`

**Settings** (⚙): transparency, font size, line spacing, timestamp format, and per-channel or global colors.

Craft/Combat and Shout/Yell filters apply retroactively to messages already captured, not just new ones.

## Commands

| Command | Does |
|---|---|
| `/multichat` | Toggle the window |
| `/multichat show` | Open and re-center |
| `/multichat reset` | Reset all window positions |
| `/multichat reload` | Reload the addon |
| `/multichat checkupdate` | Check for a newer version |
| `/multichat update` | Install the latest version and reload |

## How chat is captured

Every channel reads data the client already has, then displays it. Nothing is sent, blocked, or altered.

| Source | Mechanism |
|---|---|
| Incoming LS1/LS2/Party/Tell/Say | `packet_in`, message packet `0x017` |
| Outgoing say/tell/shout/yell | `command` event — read from what you typed |
| Outgoing LS1/LS2/Party | `packet_out`, packet `0x0B5` (read-only) |
| Craft, Combat | `text_in`, matched against known phrasings |
| NPC dialogue, Shout/Yell, SYS, emotes | `text_in`, by chat mode (150, 10/11, 151, 15) |
| Auction House, delivery box, Checker, conquest | `text_in`, matched by text — these share or lack a usable mode |

Craft/Combat's phrase list isn't exhaustive; uncommon messages may not be categorized yet. Ordinary player chat is excluded from that matching by its chat mode, so a normal chat line can't be mistaken for combat text.

## Updating

Once per session after login, MultiChat makes a single HTTPS request to this repo to compare versions — the only time it reaches outside your client. It only posts the result to SYS; nothing downloads unless you run `/multichat update`, which fetches the files fresh, aborts on any failed download rather than leaving a partial mix, then reloads.

## Japanese text shows as `?`

Expected out of the box, and not something this addon can fix alone: Ashita's default ImGui font has no Japanese glyphs, and that font atlas is shared by every ImGui addon. One-time fix:

1. Download [Noto Sans JP](https://fonts.google.com/noto/specimen/Noto+Sans+JP) and extract the **static Regular** file (`static/NotoSansJP-Regular.ttf` — not the variable-weight one, which ImGui's loader handles poorly).
2. Copy it into `<Ashita install>/resources/fonts/` (create the folder if needed — Ashita only loads fonts from there, not from Windows).
3. In your boot profile (`<Ashita install>/config/boot/ashita.ini` — the one you actually launch with, not the read-only `ashita.xxx.ini` files), set:
   ```ini
   [ashita.imgui.fonts]
   font0.family = NotoSansJP-Regular.ttf
   font0.size   = 14,18,24,32
   font0.is_jp  = true
   ```
4. Relaunch.

This changes the font for every ImGui addon, not just MultiChat. English text is unaffected — Noto Sans JP has full Latin coverage. See the [Ashita configuration docs](https://docs.ashitaxi.com/usage/configurations/) for details.

## Credits

MultiChat's code is its own. These addons were read as references to get chat modes, colors, and techniques right rather than guessing — no code from them is included, except GdiFonts, which is bundled:

- **[Balloon](https://github.com/onimitch/ffxi-balloon-ashitav4)** — chat mode values and the "Name : text" speaker split
- **[FishAid](https://github.com/TheAngryRogue/AshitaFishaid)** — the `text_in` approach and fishing bite/feel colors
- **[SimpleLog](https://github.com/Spike2D/SimpleLog)** — live entity data for telling players, pets, and enemies apart
- **[Checker](https://github.com/AshitaXI/Ashita-v4beta/tree/main/addons/checker)** and **[conquest](https://github.com/AddonsXI/conquest)** (first-party Ashita, GPL-3.0) — their output is captured and colored to match; no code included, so no GPL obligation here
- **[anglin](https://github.com/Astika2/FFXI/tree/main/addons)** — the in-game update-check approach
- **[GdiFonts](https://github.com/ThornyFFXI/gdifonttexture)** (ThornyFFXI, MIT) — **bundled** under `gdifonts/` for Shift-JIS → UTF-8 conversion

## License

MIT — see [LICENSE](LICENSE). Bundled `gdifonts/` is MIT (ThornyFFXI) — see [gdifonts/LICENSE](gdifonts/LICENSE).
