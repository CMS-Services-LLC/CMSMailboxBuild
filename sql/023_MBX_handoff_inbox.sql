/*
	CMS's "Secure Mailbox" menu link. Requires 011 and 021.

	- MBX_CreateHandoffCode: with no @MessageID, issues the one-time handoff code
	  (60 seconds, single use) for the caller's own account, so the link signs them into
	  the mailbox's inbox without a second login. Same reasoning as the Items Alerted On
	  handoff: the caller already passed CMS's NEO_Login + 2FA. With a @MessageID it's
	  unchanged from 021.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- @UID is the CMSNEO caller (from their validated JWT); @Code comes from a
-- cryptographic RNG in CMSNEO. The code is issued for the caller's own account on
-- @MessageID: a recipient account with the caller's email, or else (sql/021) the
-- message's author account with the caller's email. Returns nothing if the caller has
-- no account on that message. With no @MessageID (sql/023, CMS's "Secure Mailbox"
-- menu link) the code is for the caller's own account and just opens the inbox.
CREATE OR ALTER PROCEDURE [dbo].[MBX_CreateHandoffCode]
	@UID INT,
	@MessageID INT = NULL,
	@Code VARCHAR(64)
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @MailboxUID INT

	IF ISNULL(@MessageID, 0) = 0
	BEGIN
		SELECT @MailboxUID = UID FROM Users WHERE UID = @UID AND Active = 1
		IF @MailboxUID IS NULL RETURN

		DELETE FROM MBX_HandoffCode WHERE DTExpires < DATEADD(DAY, -1, getdate())

		INSERT INTO MBX_HandoffCode (Code, UID, MessageID, CreatedByUID, DTExpires)
		SELECT @Code, @MailboxUID, NULL, @UID, DATEADD(SECOND, 60, getdate())

		SELECT @Code AS Code, CAST(NULL AS INT) AS MessageID
		RETURN
	END

	SELECT TOP 1 @MailboxUID = r.ToUID
	FROM MBX_Recipient r
	JOIN Users ru ON ru.UID = r.ToUID AND ru.Active = 1
	JOIN Users me ON me.UID = @UID AND me.Active = 1
	WHERE r.MessageID = @MessageID
	AND ru.Email = me.Email
	ORDER BY CASE WHEN r.ToUID = @UID THEN 0 ELSE 1 END

	IF @MailboxUID IS NULL
		SELECT @MailboxUID = m.FromUID
		FROM MBX_Message m
		JOIN Users au ON au.UID = m.FromUID AND au.Active = 1
		JOIN Users me ON me.UID = @UID AND me.Active = 1
		WHERE m.MessageID = @MessageID
		AND m.IsDeleted = 0
		AND au.Email = me.Email

	IF @MailboxUID IS NULL RETURN

	-- Housekeeping: codes are worthless after a minute.
	DELETE FROM MBX_HandoffCode WHERE DTExpires < DATEADD(DAY, -1, getdate())

	INSERT INTO MBX_HandoffCode (Code, UID, MessageID, CreatedByUID, DTExpires)
	SELECT @Code, @MailboxUID, @MessageID, @UID, DATEADD(SECOND, 60, getdate())

	SELECT @Code AS Code, @MessageID AS MessageID
END
GO
