/*
	The whole conversation a message belongs to. Requires 029.

	- MBX_GetThread: from any message the caller can read, finds the thread's first message
	  (following ReplyToMessageID up) and every reply under it (down), and returns the ones
	  the caller can read (MBX_CanReadMessage), oldest first, with sender, recipients and
	  body; then the attachments of those messages. Nothing for a message the caller can't
	  read, same as MBX_GetMessage.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_GetThread]
	@UID INT,
	@MessageID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF dbo.MBX_CanReadMessage(@MessageID, @UID) = 0 RETURN

	DECLARE @RootID INT

	;WITH up AS (
		SELECT MessageID, ReplyToMessageID, 0 AS Depth FROM MBX_Message WHERE MessageID = @MessageID
		UNION ALL
		SELECT m.MessageID, m.ReplyToMessageID, up.Depth + 1
		FROM MBX_Message m JOIN up ON m.MessageID = up.ReplyToMessageID
		WHERE up.Depth < 200
	)
	SELECT TOP 1 @RootID = MessageID FROM up ORDER BY Depth DESC
	OPTION (MAXRECURSION 200)

	DECLARE @thread TABLE (MessageID INT PRIMARY KEY)

	;WITH down AS (
		SELECT MessageID, 0 AS Depth FROM MBX_Message WHERE MessageID = @RootID
		UNION ALL
		SELECT m.MessageID, down.Depth + 1
		FROM MBX_Message m JOIN down ON m.ReplyToMessageID = down.MessageID
		WHERE down.Depth < 200
	)
	INSERT INTO @thread SELECT DISTINCT MessageID FROM down
	OPTION (MAXRECURSION 200)

	DELETE t FROM @thread t
	WHERE dbo.MBX_CanReadMessage(t.MessageID, @UID) = 0
	OR EXISTS (SELECT 1 FROM MBX_Message m WHERE m.MessageID = t.MessageID AND m.IsDeleted = 1)

	SELECT m.MessageID, m.ReplyToMessageID, m.Subject, m.Body, m.DTCreated,
		u.Fname + ' ' + u.Lname AS FromName,
		c.Company AS FromCompany,
		CAST(CASE WHEN m.FromUID = @UID THEN 1 ELSE 0 END AS BIT) AS FromMe,
		dbo.MBX_ToNames(m.MessageID) AS ToNames
	FROM @thread t
	JOIN MBX_Message m ON m.MessageID = t.MessageID
	JOIN Users u ON u.UID = m.FromUID
	JOIN Companies c ON c.CID = m.FromCID
	ORDER BY m.DTCreated, m.MessageID

	SELECT a.AttachmentID, a.MessageID, a.FileName, a.SizeBytes
	FROM MBX_Attachment a
	JOIN @thread t ON t.MessageID = a.MessageID
	ORDER BY a.MessageID, a.AttachmentID
END
GO
