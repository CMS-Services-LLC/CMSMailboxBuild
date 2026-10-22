/*
	018_MBX_mailbox_gate.sql  (2026-10-22)

	Who sees links into the secure mailbox in CMS during the rollout: only users whose AccessTreeDown
	includes CID 1518. That's John's rule, verbatim:
		(select count(*) from accesstreedown(@uid) where cid = 1518) > 0

	CMS uses it in /creds (as CanUseMailbox, which the page reads) to show or hide:
	  - "Send via Secure Email" on a Form Application record (InteractiveForm.js),
	  - "Assign Tasks..." in the dashboard's "What would you like to do?" (dashboard.js),
	  - secure-mailbox messages in Items Alerted On (global.js);
	and MailboxShareController enforces it on the matching routes, so hiding a link is not the only guard.

	To open the mailbox to everyone later, change this one function to return 1.
	Not reachable from CMS's browser dispatcher (that only runs NEO* and a_Suite_* procs).

	Safe to re-run.
*/

create or alter function dbo.MBX_CanUseMailbox(@uid int)
returns bit
as begin
	return case when (select count(*) from accesstreedown(@uid) where cid = 1518) > 0 then 1 else 0 end
end
GO
