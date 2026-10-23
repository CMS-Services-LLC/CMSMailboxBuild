/*
	Paperclip in the message list. Requires 029.

	- MBX_GetFolder: same as 028's version plus AttachmentCount for each message, which the
	  page shows as a paperclip next to the subject.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
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
			(SELECT COUNT(*) FROM MBX_Attachment att WHERE att.MessageID = m.MessageID) AS AttachmentCount,
			CAST(NULL AS NVARCHAR(MAX)) AS ToNames,
			ts.TaskState,
			(SELECT STRING_AGG(CAST(mi.ItemLabel AS NVARCHAR(MAX)), ' | ') FROM MBX_MessageItem mi WHERE mi.MessageID = m.MessageID) AS ItemLabels,
			CAST(0 AS BIT) AS IsShared
		FROM MBX_Recipient r
		JOIN MBX_Message m ON m.MessageID = r.MessageID AND m.IsDeleted = 0
		JOIN Users u ON u.UID = m.FromUID
		JOIN Companies c ON c.CID = m.FromCID
		OUTER APPLY dbo.MBX_MessageTaskState(m.MessageID) ts
		WHERE r.ToUID = @UID
		  AND r.IsArchived = CASE WHEN @Folder = 'archived' THEN 1 ELSE 0 END

		UNION ALL

		-- sql/028: messages with a task the assignee shared with the caller (Inbox only)
		SELECT
			m.MessageID,
			m.Subject,
			LEFT(ISNULL(m.Body,''), 200) AS Preview,
			m.DTCreated,
			CAST(getdate() AS DATETIME) AS DTViewed,
			CAST(0 AS BIT) AS IsArchived,
			u.Fname + ' ' + u.Lname AS FromName,
			c.Company AS FromCompany,
			(SELECT COUNT(*) FROM MBX_MessageItem mi WHERE mi.MessageID = m.MessageID) AS ItemCount,
			(SELECT COUNT(*) FROM MBX_Attachment att WHERE att.MessageID = m.MessageID) AS AttachmentCount,
			CAST(NULL AS NVARCHAR(MAX)) AS ToNames,
			ts.TaskState,
			(SELECT STRING_AGG(CAST(mi.ItemLabel AS NVARCHAR(MAX)), ' | ') FROM MBX_MessageItem mi WHERE mi.MessageID = m.MessageID) AS ItemLabels,
			CAST(1 AS BIT) AS IsShared
		FROM MBX_Message m
		JOIN Users u ON u.UID = m.FromUID
		JOIN Companies c ON c.CID = m.FromCID
		OUTER APPLY dbo.MBX_MessageTaskState(m.MessageID) ts
		WHERE @Folder = 'inbox' AND m.IsDeleted = 0
		  AND NOT EXISTS (SELECT 1 FROM MBX_Recipient r2 WHERE r2.MessageID = m.MessageID AND r2.ToUID = @UID)
		  AND EXISTS (
			SELECT 1 FROM MBX_MessageItem mi
			JOIN MBX_Task t ON t.MessageItemID = mi.MessageItemID
			JOIN MBX_TaskShare sh ON sh.TaskID = t.TaskID AND sh.Active = 1 AND sh.Side = 'assignee'
			WHERE mi.MessageID = m.MessageID AND dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) IS NOT NULL)

		ORDER BY DTCreated DESC
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
			(SELECT COUNT(*) FROM MBX_Attachment att WHERE att.MessageID = m.MessageID) AS AttachmentCount,
			dbo.MBX_ToNames(m.MessageID) AS ToNames,
			ts.TaskState,
			(SELECT STRING_AGG(CAST(mi.ItemLabel AS NVARCHAR(MAX)), ' | ') FROM MBX_MessageItem mi WHERE mi.MessageID = m.MessageID) AS ItemLabels,
			CAST(0 AS BIT) AS IsShared
		FROM MBX_Message m
		JOIN Users u ON u.UID = m.FromUID
		JOIN Companies c ON c.CID = m.FromCID
		OUTER APPLY dbo.MBX_MessageTaskState(m.MessageID) ts
		WHERE m.FromUID = @UID AND m.IsDeleted = 0
		ORDER BY m.DTCreated DESC
	END
END
GO
