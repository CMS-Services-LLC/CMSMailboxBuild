/*
	Phase 6: file attachments on secure messages, separate from tasks, and composing a new
	message in the mailbox. Requires 028.

	- MBX_Attachment: files on a message. Added only by the message's author, within an hour
	  of sending it (CMSMailbox uploads them right after sending), at most 10 per message;
	  CMSMailbox enforces the 25 MB size and allowed types before calling.
	- MBX_CanReadMessage: who may see a message, and so download its attachments: its author,
	  a recipient, or (John's choice) a colleague a task on it was shared with, either side.
	- MBX_GetAttachments lists a message's files (no bytes); MBX_GetAttachment returns one.
	- MBX_GetComposeRecipients: who a new mailbox message can go to: the sender's CMS network
	  (neousers), one row per real person (their MGT account), active, not the sender.
	- MBX_GetMessageRecipientEmails: who to notify about a message the caller just sent.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.MBX_Attachment', 'U') IS NULL
BEGIN
	CREATE TABLE [dbo].[MBX_Attachment](
		[AttachmentID] [int] IDENTITY(1,1) NOT NULL,
		[MessageID] [int] NOT NULL,
		[FileName] [nvarchar](255) NOT NULL,
		[ContentType] [varchar](150) NULL,
		[SizeBytes] [bigint] NOT NULL,
		[Bytes] [varbinary](max) NOT NULL,
		[UploadedByUID] [int] NOT NULL,
		[DTUploaded] [datetime] NOT NULL CONSTRAINT [DF_MBX_Attachment_DTUploaded] DEFAULT (getdate()),
	 CONSTRAINT [PK_MBX_Attachment] PRIMARY KEY CLUSTERED ([AttachmentID] ASC),
	 CONSTRAINT [FK_MBX_Attachment_MBX_Message] FOREIGN KEY([MessageID]) REFERENCES [dbo].[MBX_Message] ([MessageID])
	) ON [PRIMARY]

	CREATE INDEX [IX_MBX_Attachment_MessageID] ON [dbo].[MBX_Attachment] ([MessageID])
END
GO

CREATE OR ALTER FUNCTION [dbo].[MBX_CanReadMessage](@MessageID INT, @UID INT)
RETURNS BIT
AS
BEGIN
	IF EXISTS (SELECT 1 FROM MBX_Message WHERE MessageID = @MessageID AND FromUID = @UID AND IsDeleted = 0) RETURN 1
	IF EXISTS (SELECT 1 FROM MBX_Recipient WHERE MessageID = @MessageID AND ToUID = @UID) RETURN 1
	IF dbo.MBX_IsSharedOnMessage(@MessageID, @UID) = 1 RETURN 1
	RETURN 0
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_AddAttachment]
	@UID INT,
	@MessageID INT,
	@FileName NVARCHAR(255),
	@ContentType VARCHAR(150),
	@Bytes VARBINARY(MAX)
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF NOT EXISTS (
		SELECT 1 FROM MBX_Message
		WHERE MessageID = @MessageID AND FromUID = @UID AND IsDeleted = 0
		AND DTCreated > DATEADD(HOUR, -1, getdate())
	)
	BEGIN
		SELECT 'not_allowed' AS err
		RETURN
	END

	IF (SELECT COUNT(*) FROM MBX_Attachment WHERE MessageID = @MessageID) >= 10
	BEGIN
		SELECT 'too_many' AS err
		RETURN
	END

	INSERT INTO MBX_Attachment (MessageID, FileName, ContentType, SizeBytes, Bytes, UploadedByUID)
	VALUES (@MessageID, @FileName, @ContentType, DATALENGTH(@Bytes), @Bytes, @UID)

	SELECT CAST(SCOPE_IDENTITY() AS INT) AS AttachmentID
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_GetAttachments]
	@UID INT,
	@MessageID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF dbo.MBX_CanReadMessage(@MessageID, @UID) = 0 RETURN

	SELECT AttachmentID, FileName, ContentType, SizeBytes, DTUploaded
	FROM MBX_Attachment
	WHERE MessageID = @MessageID
	ORDER BY AttachmentID
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_GetAttachment]
	@UID INT,
	@AttachmentID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	SELECT a.MessageID, a.FileName, a.ContentType, a.Bytes
	FROM MBX_Attachment a
	WHERE a.AttachmentID = @AttachmentID
	AND dbo.MBX_CanReadMessage(a.MessageID, @UID) = 1
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_GetComposeRecipients]
	@UID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	SELECT DISTINCT u.MgtUID AS UID, ru.Fname + ' ' + ru.Lname AS Name, ru.Email, c.Company
	FROM neousers(@UID) u
	JOIN Users ru ON ru.UID = u.MgtUID AND ru.Active = 1
	LEFT JOIN Companies c ON c.CID = dbo.mycid(u.MgtUID)
	WHERE u.MgtUID <> @UID
	ORDER BY Name
END
GO

-- The recipients of a message the caller authored, with email, for the notification.
CREATE OR ALTER PROCEDURE [dbo].[MBX_GetMessageRecipientEmails]
	@UID INT,
	@MessageID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF NOT EXISTS (SELECT 1 FROM MBX_Message WHERE MessageID = @MessageID AND FromUID = @UID) RETURN

	SELECT u.UID, u.Email, me.Fname + ' ' + me.Lname AS SenderName, mc.Company AS SenderCompany
	FROM MBX_Recipient r
	JOIN Users u ON u.UID = r.ToUID AND u.Active = 1
	JOIN Users me ON me.UID = @UID
	LEFT JOIN Companies mc ON mc.CID = dbo.mycid(@UID)
	WHERE r.MessageID = @MessageID
END
GO
