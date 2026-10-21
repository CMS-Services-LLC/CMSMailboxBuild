/*
	Items Alerted On shows only the LATEST message of each mailbox thread (an original
	message plus its chain of replies), not one row per message. Requires 012.

	NEO_GetMyAlerts3 (CMSNEO's own proc): same as 012's version, except:
	  - each message the caller received is mapped to its thread's root (following
	    MBX_Message.ReplyToMessageID up to the message with none), and only the
	    newest message per thread is listed;
	  - Viewed/ViewedBy are that newest message's, so a new reply makes the thread
	    "not viewed" again;
	  - Details adds how many messages the caller has received in the thread.
	The alert's MainID is the newest message's (same -(1000000000 + MessageID) range as
	before), so after Remove, a later reply in the same thread shows up again.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[NEO_GetMyAlerts3]
	@uid int, @onlyUnviewed bit = 0
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	-- Messages addressed to this person (any of their accounts, matched by email —
	-- see 011's header).
	SELECT r.MessageID, r.DTViewed, ru.Fname + ' ' + ru.Lname AS ReaderName
	INTO #mine
	FROM Users me
	JOIN Users ru ON ru.Email = me.Email AND ru.Active = 1
	JOIN MBX_Recipient r ON r.ToUID = ru.UID
	JOIN MBX_Message m ON m.MessageID = r.MessageID AND m.IsDeleted = 0
	WHERE me.UID = @uid

	-- Each of those messages' thread root.
	;WITH chain AS (
		SELECT m.MessageID AS Leaf, m.MessageID AS Cur, m.ReplyToMessageID AS Parent, 0 AS Depth
		FROM MBX_Message m
		WHERE m.MessageID IN (SELECT MessageID FROM #mine)
		UNION ALL
		SELECT c.Leaf, p.MessageID, p.ReplyToMessageID, c.Depth + 1
		FROM chain c
		JOIN MBX_Message p ON p.MessageID = c.Parent
		WHERE c.Depth < 200
	)
	SELECT Leaf AS MessageID, Cur AS RootID
	INTO #roots
	FROM chain
	WHERE Parent IS NULL
	OPTION (MAXRECURSION 200)

	SELECT x.*
	INTO #latest
	FROM (
		SELECT mi.MessageID, mi.DTViewed, mi.ReaderName, rt.RootID,
			ROW_NUMBER() OVER (PARTITION BY rt.RootID ORDER BY m.DTCreated DESC, m.MessageID DESC) AS rn,
			COUNT(*) OVER (PARTITION BY rt.RootID) AS InThread
		FROM #mine mi
		JOIN #roots rt ON rt.MessageID = mi.MessageID
		JOIN MBX_Message m ON m.MessageID = mi.MessageID
	) x
	WHERE x.rn = 1

	SELECT id, MainID, Date_Alerted, Viewed, ViewedBy, Type, URL, Item, Details, addtl_Info
	FROM NEOAlertedItemsDetails2(@uid)

	UNION ALL

	SELECT
		-(1000000000 + m.MessageID) AS id,
		-(1000000000 + m.MessageID) AS MainID,
		m.DTCreated AS Date_Alerted,
		CASE WHEN l.DTViewed IS NULL THEN 'False' ELSE 'True' END AS Viewed,
		CASE WHEN l.DTViewed IS NULL THEN NULL ELSE '[' + l.ReaderName + ']' END AS ViewedBy,
		'Secure Mailbox' AS Type,
		'mailbox:' + CAST(m.MessageID AS VARCHAR(20)) AS URL,
		m.Subject AS Item,
		'From: ' + fu.Fname + ' ' + fu.Lname + ' (' + fc.Company + ')' +
			CASE WHEN l.InThread > 1 THEN '|' + CAST(l.InThread AS VARCHAR(10)) + ' messages in this thread' ELSE '' END +
			CASE WHEN t.Tasks > 0 THEN '|' + CAST(t.Tasks AS VARCHAR(10)) + ' task' + CASE WHEN t.Tasks > 1 THEN 's' ELSE '' END ELSE '' END +
			CASE WHEN l.DTViewed IS NULL THEN '' ELSE '|Read ' + CONVERT(VARCHAR, l.DTViewed, 100) END AS Details,
		NULL AS addtl_Info
	FROM #latest l
	JOIN MBX_Message m ON m.MessageID = l.MessageID
	JOIN Users fu ON fu.UID = m.FromUID
	JOIN Companies fc ON fc.CID = m.FromCID
	JOIN Users me ON me.UID = @uid
	OUTER APPLY (
		SELECT COUNT(*) AS Tasks
		FROM MBX_MessageItem mi JOIN MBX_Task tk ON tk.MessageItemID = mi.MessageItemID
		WHERE mi.MessageID = m.MessageID
	) t
	-- @onlyUnviewed is ignored, as it already was for the other alert types:
	-- global.js filters on Viewed itself.
	WHERE NOT EXISTS (
		SELECT 1 FROM NEO_RemovedAlertedItems ra
		WHERE ra.Email = me.Email
		AND ra.MainID = -(1000000000 + m.MessageID)
		AND ra.active = 1
	)

	DROP TABLE #mine, #roots, #latest
END
GO
