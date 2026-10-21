/*
	Unread secure-mailbox messages in CMSNEO's "Items Alerted On", and a one-time
	handoff so clicking one opens CMSMailbox already logged in. Requires 006-010.

	HANDOFF (no security is bypassed). The mailbox's own login is the same check as
	CMSNEO's: NEO_Login plus the same Google Authenticator 2FA. A user already logged
	in to CMSNEO has passed it. So CMSNEO (main/MailboxHandoff, authenticated by the
	user's validated JWT) stores a random one-time code here. CMSMailbox
	(auth/handoff) exchanges it for its normal login token. A code:
	  - is 256 bits from a cryptographic RNG (generated in C#, never in SQL),
	  - expires 60 seconds after it's created,
	  - works once (redeeming is a single atomic UPDATE ... WHERE DTUsed IS NULL),
	  - never carries the CMSNEO token itself.
	CMSMailbox strips it from the address bar as soon as the page loads.

	Which account: a management user switched into a downstream company is on a
	different Users row (a "basic account") from the one their mailbox messages are
	addressed to. Both have the same email. The code is issued for the recipient
	account of that message that has the caller's email. That's the same person,
	and the same account the mailbox addressed.

	ALERTS. NEO_GetMyAlerts3 (behind Items Alerted On and the dashboard's "N new
	alerts" banner) now also returns each unread, unarchived mailbox message
	addressed to the caller (matched by email, as above) with Type 'Secure Mailbox'.
	  - MainID = -(1000000000 + MessageID). NEO_RemovedAlertedItems is matched on
	    MainID alone elsewhere (not Type), so mailbox alerts use their own number
	    range and Remove on one can never hide a form or file alert.
	  - URL = 'mailbox:<MessageID>'. CMSNEO's click handler (global.js) turns that
	    into a handoff instead of navigating.
	  - A message drops off once it's read in the mailbox (MBX_Recipient.DTViewed).

	- MBX_HandoffCode: new table.
	- MBX_CreateHandoffCode, MBX_RedeemHandoffCode: new.
	- NEO_GetMyAlerts3: CMSNEO's own proc. Same output as before plus the mailbox rows.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.MBX_HandoffCode', 'U') IS NULL
BEGIN
	CREATE TABLE [dbo].[MBX_HandoffCode](
		[Code] [varchar](64) NOT NULL,
		[UID] [int] NOT NULL,
		[MessageID] [int] NULL,
		[CreatedByUID] [int] NOT NULL,
		[DTCreated] [datetime] NOT NULL CONSTRAINT [DF_MBX_HandoffCode_DTCreated] DEFAULT (getdate()),
		[DTExpires] [datetime] NOT NULL,
		[DTUsed] [datetime] NULL,
	 CONSTRAINT [PK_MBX_HandoffCode] PRIMARY KEY CLUSTERED ([Code] ASC)
	) ON [PRIMARY]
END
GO

-- @UID is the CMSNEO caller (from their validated JWT); @Code comes from a
-- cryptographic RNG in CMSNEO. The code is issued for the recipient account of
-- @MessageID that has the caller's email. Returns nothing if the caller has no such
-- account on that message.
CREATE OR ALTER PROCEDURE [dbo].[MBX_CreateHandoffCode]
	@UID INT,
	@MessageID INT,
	@Code VARCHAR(64)
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @MailboxUID INT

	SELECT TOP 1 @MailboxUID = r.ToUID
	FROM MBX_Recipient r
	JOIN Users ru ON ru.UID = r.ToUID AND ru.Active = 1
	JOIN Users me ON me.UID = @UID AND me.Active = 1
	WHERE r.MessageID = @MessageID
	AND ru.Email = me.Email
	ORDER BY CASE WHEN r.ToUID = @UID THEN 0 ELSE 1 END

	IF @MailboxUID IS NULL RETURN

	-- Housekeeping: codes are worthless after a minute.
	DELETE FROM MBX_HandoffCode WHERE DTExpires < DATEADD(DAY, -1, getdate())

	INSERT INTO MBX_HandoffCode (Code, UID, MessageID, CreatedByUID, DTExpires)
	SELECT @Code, @MailboxUID, @MessageID, @UID, DATEADD(SECOND, 60, getdate())

	SELECT @Code AS Code, @MessageID AS MessageID
END
GO

-- Atomic: only one caller can ever get a row back for a given code, and only within
-- its 60 seconds.
CREATE OR ALTER PROCEDURE [dbo].[MBX_RedeemHandoffCode]
	@Code VARCHAR(64)
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @out TABLE (UID INT, MessageID INT)

	UPDATE MBX_HandoffCode
	SET DTUsed = getdate()
	OUTPUT inserted.UID, inserted.MessageID INTO @out
	WHERE Code = @Code AND DTUsed IS NULL AND DTExpires > getdate()

	SELECT o.UID, o.MessageID
	FROM @out o
	JOIN Users u ON u.UID = o.UID AND u.Active = 1
END
GO

-- CMSNEO's own proc: same as before (NEOAlertedItemsDetails2) plus unread mailbox
-- messages. Column list/order matches NEOAlertedItemsDetails2's output.
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
		'False' AS Viewed,
		NULL AS ViewedBy,
		'Secure Mailbox' AS Type,
		'mailbox:' + CAST(m.MessageID AS VARCHAR(20)) AS URL,
		m.Subject AS Item,
		'From: ' + fu.Fname + ' ' + fu.Lname + ' (' + fc.Company + ')' +
			CASE WHEN t.Tasks > 0 THEN '|' + CAST(t.Tasks AS VARCHAR(10)) + ' task' + CASE WHEN t.Tasks > 1 THEN 's' ELSE '' END ELSE '' END AS Details,
		NULL AS addtl_Info
	FROM Users me
	JOIN Users ru ON ru.Email = me.Email AND ru.Active = 1
	JOIN MBX_Recipient r ON r.ToUID = ru.UID AND r.DTViewed IS NULL AND r.IsArchived = 0
	JOIN MBX_Message m ON m.MessageID = r.MessageID AND m.IsDeleted = 0
	JOIN Users fu ON fu.UID = m.FromUID
	JOIN Companies fc ON fc.CID = m.FromCID
	OUTER APPLY (
		SELECT COUNT(*) AS Tasks
		FROM MBX_MessageItem mi JOIN MBX_Task tk ON tk.MessageItemID = mi.MessageItemID
		WHERE mi.MessageID = m.MessageID
	) t
	WHERE me.UID = @uid
	AND NOT EXISTS (
		SELECT 1 FROM NEO_RemovedAlertedItems ra
		WHERE ra.Email = me.Email
		AND ra.MainID = -(1000000000 + m.MessageID)
		AND ra.active = 1
	)
END
GO
