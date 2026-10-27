/*
	The sender of a message can open its items (form records, downloads) from their Sent
	folder. Requires 028.

	- MBX_CanOpenItem: 028's version plus the message's sender (MBX_Message.FromUID). Until
	  now only recipients and colleagues the task was shared with by its assignee got past
	  this first gate, so "Send via Secure Email" from Form Applications left the sender
	  unable to open the record they sent.

	This grants nothing beyond what the sender already has in CMS: the mailbox's second
	gate still re-checks the caller's own CMS permissions on every open (Gate A = their
	Team grant for the form, Gate B = NEO_IAGetFormData; downloads re-run the CMS file
	procs with their own UID). MBX_GetOpenFormTask and MBX_GetDRTask also require the
	caller to be the task's assignee, so senders get no task work from this.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER FUNCTION [dbo].[MBX_CanOpenItem](@MessageItemID INT, @UID INT)
RETURNS BIT
AS
BEGIN
	IF EXISTS (
		SELECT 1 FROM MBX_MessageItem mi
		JOIN MBX_Recipient r ON r.MessageID = mi.MessageID AND r.ToUID = @UID
		WHERE mi.MessageItemID = @MessageItemID
	) RETURN 1
	-- sql/033: the message's sender.
	IF EXISTS (
		SELECT 1 FROM MBX_MessageItem mi
		JOIN MBX_Message m ON m.MessageID = mi.MessageID AND m.FromUID = @UID
		WHERE mi.MessageItemID = @MessageItemID
	) RETURN 1
	IF EXISTS (
		SELECT 1 FROM MBX_Task t
		WHERE t.MessageItemID = @MessageItemID AND dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) IS NOT NULL
	) RETURN 1
	RETURN 0
END
GO
