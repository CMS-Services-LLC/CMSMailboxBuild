/*
	Mailbox folders: Inbox / Archived / Sent.

	- MBX_GetFolder: new. Inbox = messages addressed to @UID that aren't archived,
	  Archived = messages addressed to @UID that are, Sent = messages @UID authored.
	  Anything else returns nothing. (MBX_GetInbox is left as-is and is no longer
	  called by the app.)
	- MBX_GetMessage: now also lets the AUTHOR of a message open it (needed so Sent
	  can be read), and additionally returns IsRecipient / IsArchived / ToNames so the
	  UI can pick the right buttons without guessing from which folder it came from.
	  Existing columns are unchanged, so the currently deployed app keeps working.

	Archiving stays per-recipient (MBX_Recipient.IsArchived, already set by
	MBX_MarkArchived) — archiving a message never affects anyone else's copy.

	Idempotent (CREATE OR ALTER); safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- Comma-separated "First Last" of everyone a message was addressed to. FOR XML PATH
-- (rather than STRING_AGG) so this works regardless of the database's compat level.
CREATE OR ALTER FUNCTION [dbo].[MBX_ToNames](@MessageID INT)
RETURNS NVARCHAR(MAX)
AS
BEGIN
	RETURN STUFF((
		SELECT ', ' + u.Fname + ' ' + u.Lname
		FROM MBX_Recipient r
		JOIN Users u ON u.UID = r.ToUID
		WHERE r.MessageID = @MessageID
		ORDER BY u.Lname, u.Fname
		FOR XML PATH(''), TYPE
	).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
END
GO


CREATE OR ALTER PROCEDURE [dbo].[MBX_GetFolder]
	@UID INT,
	@Folder VARCHAR(20)
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF @Folder IN ('inbox', 'archived')
	BEGIN
		SELECT
			m.MessageID,
			m.Subject,
			LEFT(ISNULL(m.Body,''), 200) AS Preview,
			m.DTCreated,
			r.DTViewed,
			r.IsArchived,
			u.Fname + ' ' + u.Lname AS FromName,
			c.Company AS FromCompany,
			(SELECT COUNT(*) FROM MBX_MessageItem mi WHERE mi.MessageID = m.MessageID) AS ItemCount,
			CAST(NULL AS NVARCHAR(MAX)) AS ToNames
		FROM MBX_Recipient r
		JOIN MBX_Message m ON m.MessageID = r.MessageID AND m.IsDeleted = 0
		JOIN Users u ON u.UID = m.FromUID
		JOIN Companies c ON c.CID = m.FromCID
		WHERE r.ToUID = @UID
		  AND r.IsArchived = CASE WHEN @Folder = 'archived' THEN 1 ELSE 0 END
		ORDER BY m.DTCreated DESC
	END
	ELSE IF @Folder = 'sent'
	BEGIN
		SELECT
			m.MessageID,
			m.Subject,
			LEFT(ISNULL(m.Body,''), 200) AS Preview,
			m.DTCreated,
			CAST(NULL AS DATETIME) AS DTViewed,
			CAST(0 AS BIT) AS IsArchived,
			u.Fname + ' ' + u.Lname AS FromName,
			c.Company AS FromCompany,
			(SELECT COUNT(*) FROM MBX_MessageItem mi WHERE mi.MessageID = m.MessageID) AS ItemCount,
			dbo.MBX_ToNames(m.MessageID) AS ToNames
		FROM MBX_Message m
		JOIN Users u ON u.UID = m.FromUID
		JOIN Companies c ON c.CID = m.FromCID
		WHERE m.FromUID = @UID AND m.IsDeleted = 0
		ORDER BY m.DTCreated DESC
	END
END
GO


CREATE OR ALTER PROCEDURE [dbo].[MBX_GetMessage]
	@UID INT,
	@MessageID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @IsRecipient BIT = 0, @IsArchived BIT = 0

	SELECT @IsRecipient = 1, @IsArchived = IsArchived
	FROM MBX_Recipient
	WHERE MessageID = @MessageID AND ToUID = @UID

	-- Recipient OR author. Deliberately returns nothing distinguishable from "message
	-- doesn't exist" for anyone else — never confirm existence of a message the
	-- caller has no relationship to.
	IF @IsRecipient = 0 AND NOT EXISTS (
		SELECT 1 FROM MBX_Message WHERE MessageID = @MessageID AND FromUID = @UID
	)
	BEGIN
		RETURN
	END

	SELECT
		m.MessageID, m.Subject, m.Body, m.DTCreated, m.ReplyToMessageID,
		u.Fname + ' ' + u.Lname AS FromName,
		c.Company AS FromCompany,
		@IsRecipient AS IsRecipient,
		@IsArchived AS IsArchived,
		dbo.MBX_ToNames(m.MessageID) AS ToNames
	FROM MBX_Message m
	JOIN Users u ON u.UID = m.FromUID
	JOIN Companies c ON c.CID = m.FromCID
	WHERE m.MessageID = @MessageID AND m.IsDeleted = 0

	SELECT MessageItemID, ItemType, ItemID, ItemLabel, FormID
	FROM MBX_MessageItem
	WHERE MessageID = @MessageID
END
GO
