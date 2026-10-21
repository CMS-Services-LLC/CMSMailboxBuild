/*
	Read mailbox messages move to the "Viewed" section of CMSNEO's Items Alerted On
	instead of dropping off the list. Requires 011.

	NEO_GetMyAlerts3 (CMSNEO's own proc): same as 011's version, except mailbox
	messages are listed whether read or not:
	  - Viewed = 'True' once the recipient has opened it (MBX_Recipient.DTViewed), and
	  - ViewedBy = '[First Last]' of that recipient, the same shape the other alert
	    types use. That shape is what the "Not Viewed by Me" filter in global.js
	    matches on.
	Archived messages are listed too: archiving a message means it was opened, so they
	show as Viewed. Remove still hides any of them.

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

	SELECT id, MainID, Date_Alerted, Viewed, ViewedBy, Type, URL, Item, Details, addtl_Info
	FROM NEOAlertedItemsDetails2(@uid)

	UNION ALL

	SELECT
		-(1000000000 + m.MessageID) AS id,
		-(1000000000 + m.MessageID) AS MainID,
		m.DTCreated AS Date_Alerted,
		CASE WHEN r.DTViewed IS NULL THEN 'False' ELSE 'True' END AS Viewed,
		CASE WHEN r.DTViewed IS NULL THEN NULL ELSE '[' + ru.Fname + ' ' + ru.Lname + ']' END AS ViewedBy,
		'Secure Mailbox' AS Type,
		'mailbox:' + CAST(m.MessageID AS VARCHAR(20)) AS URL,
		m.Subject AS Item,
		'From: ' + fu.Fname + ' ' + fu.Lname + ' (' + fc.Company + ')' +
			CASE WHEN t.Tasks > 0 THEN '|' + CAST(t.Tasks AS VARCHAR(10)) + ' task' + CASE WHEN t.Tasks > 1 THEN 's' ELSE '' END ELSE '' END +
			CASE WHEN r.DTViewed IS NULL THEN '' ELSE '|Read ' + CONVERT(VARCHAR, r.DTViewed, 100) END AS Details,
		NULL AS addtl_Info
	FROM Users me
	JOIN Users ru ON ru.Email = me.Email AND ru.Active = 1
	JOIN MBX_Recipient r ON r.ToUID = ru.UID
	JOIN MBX_Message m ON m.MessageID = r.MessageID AND m.IsDeleted = 0
	JOIN Users fu ON fu.UID = m.FromUID
	JOIN Companies fc ON fc.CID = m.FromCID
	OUTER APPLY (
		SELECT COUNT(*) AS Tasks
		FROM MBX_MessageItem mi JOIN MBX_Task tk ON tk.MessageItemID = mi.MessageItemID
		WHERE mi.MessageID = m.MessageID
	) t
	-- @onlyUnviewed is ignored, as it already was for the other alert types:
	-- global.js filters on Viewed itself.
	WHERE me.UID = @uid
	AND NOT EXISTS (
		SELECT 1 FROM NEO_RemovedAlertedItems ra
		WHERE ra.Email = me.Email
		AND ra.MainID = -(1000000000 + m.MessageID)
		AND ra.active = 1
	)
END
GO
