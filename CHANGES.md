# ChopPool changes

Each release can be undone with `git revert <commit>` (app) plus the database note below.

## Update 55 · 26 Nov 2026 · Vendor branches
- One vendor, several branches: the owner's phone number and PIN sign in to all of them. Each branch has its own location, menu, days, capacity and an optional phone for riders.
- Customer invites her number far (over 300 m) from all her branches: "Another branch of …?" Yes asks the owner to confirm ("Is this your branch?" with the pinned spot); No sends the customer back to check the number. Within 300 m: joins that branch.
- New branches copy her menu, days and payout. She can also add a branch herself from her vendor page (branch switcher at the top).
- Team: "Link as branch of…" on Vendors and New vendors; "Owner says this isn't her branch" shows in New vendors.
- sms function: branch checks go to the owner's number (WhatsApp template `branch_check`, else SMS, else the team).
- Undo: revert the commit; the parent_id column can stay.

## Update 54 · 25 Nov 2026 · Invite a vendor, vendor PIN sign-in, WhatsApp messages
- Customers **invite** a vendor in 3 steps (name + phone, search/map pin, optional dish names). ChopPool sends her the link by WhatsApp or SMS; the customer never sees it. Signed-in customers only, 3 new vendors a day each (Settings).
- Duplicates: same phone (any format) joins the existing vendor; a similar name within 300 m asks "Is this her?"; "different vendor" is flagged for the team to merge. One vendor per phone number in the database.
- "Waiting for…" cards on the Vendors tab. **Remind** goes to the team only, once a day.
- Vendor: opens the link → 3 steps (confirm, menu with quick dishes and prices, days + MoMo + 4-digit PIN, "also serve other buildings"). "Let ChopPool set it up for me" option. Stays signed in; phone + PIN on a new phone; Forgot PIN by code. "Not interested" pauses invites for 30 days.
- Team: New vendors shows invite status, waiting customers, reminders, possible duplicates (Merge), "Send setup link", "Fill in for her", approve for every building, and vendors asked for at other buildings. Waiting customers get a bell alert when she's live.
- Messages: sms function now sends sign-in codes, invites and vendor codes by WhatsApp or SMS (order set in Admin › Settings › Messages), logs them, retries a failed WhatsApp invite by SMS, auto-replies to messages on the alerts number.
- Old "Add a vendor" (which gave the customer the vendor's link) is closed.
- Undo database: leave it (the new tables and columns are unused by the old app); the old app's add_vendor would need update 41's version restored.
