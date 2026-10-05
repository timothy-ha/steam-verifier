# steam-verifier

Parses installed steam games and verifies integrity.

Requires steamcmd.

Results are written to `logs\results.csv` (per-game steamcmd output in `logs\<appid>.log`).
Re-running skips games already verified OK, so an interrupted run picks up where it left off.
