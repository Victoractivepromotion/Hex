---
"hex-app": patch
---

Fix the "Hey Larry" wake word going dead after a discarded or failed utterance: listening was suspended on every recording start but only resumed on the successful path, so one short or failed recording switched it off until the app was restarted.
