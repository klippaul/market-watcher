# Improvement backlog

A scheduled Claude run takes the top unchecked item each week, builds it, and opens a pull request.
Reorder, edit, or add items to steer it. Anything under "Ground rules" applies to every change.

## Ground rules

- Stay lightweight: one `index.html`, no dependencies, no build step, no accounts or API keys.
- Every prediction keeps its "speculative, not financial advice" label and its counterpoints.
- Never invent data. If something cannot be computed, say so in the interface.
- `tests/run.sh` must pass, and new behavior gets a new check.
- One focused change per pull request.

## Next up

- [ ] **Editable watchlist.** Add and remove symbols from the interface and keep the list between sessions, instead of editing `index.html`.
- [ ] **Sector detail sheet.** When a sector is opened, show its short, medium, and long-term signals in a table like the per-stock one, plus its member stocks.
- [ ] **Move alerts.** Flag a stock in the compact ticker when its move passes a chosen size (for example 2 times its typical day), with an optional desktop notification.
- [ ] **Pre-market and after-hours prices.** Show extended-hours moves when the regular session is closed.
- [ ] **Run the tests on every pull request** with a GitHub Actions workflow.
- [ ] **Accessibility pass.** Full keyboard navigation, screen-reader labels, and a table view for each chart.
- [ ] **Lighter refresh.** Update only the numbers that changed instead of redrawing the whole analysis view each minute.
- [ ] **Light and dark toggle.** Let the viewer override the system theme.

## Ideas that need a decision first

- Commentary written by Claude on top of the rule-based leans. Needs an Anthropic API key from the owner.
- Backtest the leans over the past year of prices, so the scorecard has something to show on day one instead of filling in one session at a time. Needs a decision because it replays the rules on history, which is a different claim from a live record.
- A second price source as a backup to Yahoo. Every free one tried so far needs an API key.

## Done

- [x] Compact ticker and full-screen analysis in one window.
- [x] Biggest movers, sector performance, predicted next moves with counterpoints.
- [x] Sector outlook over short, medium, and long term.
- [x] Fallback to saved prices, then labelled demo data, when the feed is unreachable.
- [x] Prediction scorecard: each session's leans are remembered in the browser and checked against the next close, overall and per signal.
