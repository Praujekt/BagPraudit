# Bag Praudit

Bag audit addon for returning players. Scans every bag slot, classifies each item
with heuristics tuned for "I just came back and have no idea what any of this is",
and shows a review window. Built for retail **Midnight** (12.0.7, 12.1-ready).

Nothing is ever sold or deleted automatically.

## Verdicts

| Verdict | Meaning |
|---|---|
| **SELL** | Safe to vendor: grey junk, expired consumables from old expansions, outdated soulbound gear whose appearance you already collected, known toys/recipes |
| **DELETE** | Worthless and no vendor value: conjured food, zero-value greys |
| **REVIEW** | Human judgment: orphaned quest items, holiday items, uncollected transmog, last-expansion consumables, unopened containers, old tokens |
| **BANK** | Sentimental / hard or impossible to reacquire: old legendaries and artifacts, quest-bound rewards from removed content, unique old keepsakes. Bank (or warband-bank), never delete |
| **AH** | Worth listing instead of vendoring: BoE gear, old crafting mats |
| **KEEP** | Current-content items, account-bound gear, battle pets, heirlooms, unlearned toys/mounts |

## Install

1. Copy the `BagPraudit` folder into
   `World of Warcraft/_retail_/Interface/AddOns/`
2. Restart the game (or `/reload` if it was already running).
3. Type `/praudit`.

## Usage

- `/praudit` (or `/bpr`) — open/close the audit window (scans your bags)
- `/praudit bank` — audit your bank, bank tabs, and warband tabs (bank must be open; selling stays bags-only, closing the bank switches back)
- `/praudit export` — copyable text report of the scan (Ctrl+A, Ctrl+C)
- `/praudit reset` — clear your personal keep list
- `/praudit batch` — toggle selling in buyback-safe batches of 12 (default on)
- `/praudit help` — command list

The summary shows a **junk score**: the percentage of scanned slots flagged as clearable (SELL+DELETE+REVIEW+AH), with how many are freeable right now.

In the window:

- **Keep** button on any row — never flag that item again (persists per account).
- **X** button (DELETE/REVIEW rows only) — delete with a confirmation popup.
- **Sell flagged** — enabled while a vendor is open; sells only SELL-verdict items,
  12 at a time by default so everything stays within the buyback window.
- Hover any row for the real tooltip; shift-click links it in chat.
- Scanning is blocked in combat (12.x secret-value restrictions); leave combat first.

## Safety model

- Sell only happens at a merchant, from your click, SELL verdicts only.
- Delete requires a per-item click plus a confirm popup, and re-verifies the bag
  slot still holds the same item before touching it.
- Anything ambiguous lands in REVIEW or BANK, never in SELL/DELETE.
- BANK exists specifically so irreplaceable items are steered away from deletion.

## Feedback loop

Run `/praudit export`, copy the text, and paste it back to Claude. The export includes
itemID, class/subclass, expansion ID, ilvl, verdict, and reason per item, plus your
character context - enough to tune misclassified rules without in-game access.

## Known heuristic limits (v1)

- "Old expansion" detection uses item data's expansionID; expansion-agnostic items
  report 0 (Classic) and land in REVIEW rather than SELL by design.
- Battle pet duplicates are not detected (all cages are KEEP).
- Gear transmog checks use PlayerCanCollectSource: uncollected-but-learnable gear says "EQUIP IT ONCE", wrong-class gear says bank it for an alt, and jewelry/trinkets skip the check (no appearance).
- Void storage is not scanned; bank scanning requires the bank window to be open.
