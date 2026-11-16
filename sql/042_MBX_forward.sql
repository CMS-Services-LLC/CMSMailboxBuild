/*
	042: Forward a secure message to colleagues (John 2026-11-16: "a direct recipient of a secure
	email should be able to forward that message to anyone within their organization").

	- Only a DIRECT recipient may forward (a row in MBX_Recipient for them). The author, a colleague
	  a task was shared with, and a Global Administrator viewing it (sql/041) cannot.
	- Recipients: active people in the forwarder's own company (dbo.mycid, the company they're
	  signed in to), the same "colleague" rule as MBX_TaskShareCandidates (sql/028), minus the
	  forwarder. MBX_ForwardMessage re-derives that list itself; nothing from the page is trusted.
	- What goes: a new message (its own conversation, ReplyToMessageID NULL) from the forwarder with
	  "Fwd: <subject>", their note, then the original's From / Date / To / Subject and text, and a
	  copy of the original message's own attachments. Tasks, form records, reports and exams on
	  the message are NOT forwarded: they stay with the people they were sent to.

	Needs 029 (MBX_Attachment). Independent of 041. Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- Colleagues the caller can forward this message to; no rows unless the caller is a direct recipient.
CREATE OR ALTER FUNCTION [dbo].[MBX_ForwardCandidates](@UID INT, @MessageID INT)
RETURNS @r TABLE (UID INT, Name VARCHAR(200), Email VARCHAR(300), Company VARCHAR(300))
AS
BEGIN
	IF NOT EXISTS (SELECT 1 FROM MBX_Recipient WHERE MessageID = @MessageID AND ToUID = @UID) RETURN
	IF NOT EXISTS (SELECT 1 FROM MBX_Message WHERE MessageID = @MessageID AND IsDeleted = 0) RETURN

	DECLARE @MyCID INT = dbo.mycid(@UID)

	INSERT INTO @r
	SELECT DISTINCT u.MgtUID, ru.Fname + ' ' + ru.Lname, ru.Email, c.Company
	FROM neousers(@UID) u
	JOIN Users ru ON ru.UID = u.MgtUID AND ru.Active = 1
	LEFT JOIN Companies c ON c.CID = @MyCID
	WHERE u.cid = @MyCID AND dbo.mycid(u.MgtUID) = @MyCID
	AND u.MgtUID <> @UID

	RETURN
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_GetForwardRecipients]
	@UID INT,
	@MessageID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	SELECT UID, Name, Email, Company
	FROM dbo.MBX_ForwardCandidates(@UID, @MessageID)
	ORDER BY Name
END
GO

-- Returns MessageID of the new message, or err: not_allowed | recipients_required | recipient_not_allowed.
CREATE OR ALTER PROCEDURE [dbo].[MBX_ForwardMessage]
	@UID INT,
	@MessageID INT,
	@Note NVARCHAR(MAX) = NULL,
	@RecipientUIDsCSV VARCHAR(MAX)
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF NOT EXISTS (SELECT 1 FROM MBX_Recipient WHERE MessageID = @MessageID AND ToUID = @UID)
	OR NOT EXISTS (SELECT 1 FROM MBX_Message WHERE MessageID = @MessageID AND IsDeleted = 0)
	BEGIN
		SELECT 'not_allowed' AS err
		RETURN
	END

	DECLARE @to TABLE (UID INT PRIMARY KEY)
	INSERT INTO @to
	SELECT DISTINCT TRY_CAST(value AS INT)
	FROM STRING_SPLIT(@RecipientUIDsCSV, ',')
	WHERE TRY_CAST(value AS INT) IS NOT NULL

	IF NOT EXISTS (SELECT 1 FROM @to)
	BEGIN
		SELECT 'recipients_required' AS err
		RETURN
	END

	DECLARE @ok TABLE (UID INT PRIMARY KEY)
	INSERT INTO @ok SELECT DISTINCT UID FROM dbo.MBX_ForwardCandidates(@UID, @MessageID)

	IF EXISTS (SELECT 1 FROM @to t WHERE NOT EXISTS (SELECT 1 FROM @ok o WHERE o.UID = t.UID))
	BEGIN
		SELECT 'recipient_not_allowed' AS err
		RETURN
	END

	-- The original, as the forwarded block.
	DECLARE @Subject NVARCHAR(255), @Body NVARCHAR(MAX), @FromName NVARCHAR(400), @DT DATETIME, @ToNames NVARCHAR(MAX)
	SELECT @Subject = m.Subject, @Body = m.Body, @DT = m.DTCreated,
		@FromName = fu.Fname + ' ' + fu.Lname + ISNULL(' (' + fc.Company + ')', '')
	FROM MBX_Message m
	JOIN Users fu ON fu.UID = m.FromUID
	LEFT JOIN Companies fc ON fc.CID = m.FromCID
	WHERE m.MessageID = @MessageID

	SELECT @ToNames = STRING_AGG(CAST(ru.Fname + ' ' + ru.Lname AS NVARCHAR(MAX)), ', ') WITHIN GROUP (ORDER BY ru.Lname, ru.Fname)
	FROM MBX_Recipient r
	JOIN Users ru ON ru.UID = r.ToUID
	WHERE r.MessageID = @MessageID

	DECLARE @NewSubject NVARCHAR(255) = LEFT(CASE WHEN @Subject LIKE 'Fwd:%' THEN @Subject ELSE 'Fwd: ' + @Subject END, 255)
	DECLARE @NewBody NVARCHAR(MAX) =
		CASE WHEN LTRIM(RTRIM(ISNULL(@Note, ''))) <> '' THEN @Note + CHAR(13) + CHAR(10) + CHAR(13) + CHAR(10) ELSE '' END +
		N'---------- Forwarded message ----------' + CHAR(13) + CHAR(10) +
		N'From: ' + ISNULL(@FromName, '') + CHAR(13) + CHAR(10) +
		N'Date: ' + FORMAT(@DT, 'MMMM d, yyyy') + CHAR(13) + CHAR(10) +
		N'To: ' + ISNULL(@ToNames, '') + CHAR(13) + CHAR(10) +
		N'Subject: ' + ISNULL(@Subject, '') + CHAR(13) + CHAR(10) + CHAR(13) + CHAR(10) +
		ISNULL(@Body, '')

	BEGIN TRAN

	INSERT INTO MBX_Message (FromUID, FromCID, Subject, Body)
	SELECT @UID, dbo.mycid(@UID), @NewSubject, @NewBody

	DECLARE @NewID INT = CAST(SCOPE_IDENTITY() AS INT)

	INSERT INTO MBX_Recipient (MessageID, ToUID, ToCID)
	SELECT @NewID, u.UID, u.CID
	FROM @to t
	JOIN Users u ON u.UID = t.UID AND u.Active = 1

	INSERT INTO MBX_Attachment (MessageID, FileName, ContentType, SizeBytes, Bytes, UploadedByUID)
	SELECT @NewID, a.FileName, a.ContentType, a.SizeBytes, a.Bytes, @UID
	FROM MBX_Attachment a
	WHERE a.MessageID = @MessageID
	ORDER BY a.AttachmentID

	COMMIT

	SELECT @NewID AS MessageID
END
GO
