/*
	Mailbox list: filter by task state, search by task name. Requires 005-021.

	- MBX_MessageTaskState(@MessageID): one row with TaskState for a message that
	  carries tasks (MBX_Task on its own items): 'Pending' while any non-cancelled task
	  isn't Completed (Open, Saved or Pending Review), 'Completed' once every
	  non-cancelled task is, 'Cancelled' if all its tasks were cancelled. No row (NULL)
	  for a message without tasks, e.g. a reply.
	- MBX_GetFolder: same as 005's version plus TaskState, which the page's
	  All / Pending / Completed filter and the row tag use, and ItemLabels (the names of
	  the message's items and tasks, e.g. 'New Annual Report', 'Exam: 2026 Audit (Acme)'),
	  which the search box also searches.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER FUNCTION [dbo].[MBX_MessageTaskState](@MessageID INT)
RETURNS TABLE
AS
RETURN (
	SELECT CASE
			WHEN SUM(CASE WHEN st.s NOT IN ('Completed', 'Cancelled') THEN 1 ELSE 0 END) > 0 THEN 'Pending'
			WHEN SUM(CASE WHEN st.s = 'Completed' THEN 1 ELSE 0 END) > 0 THEN 'Completed'
			ELSE 'Cancelled'
		END AS TaskState
	FROM MBX_Task t
	JOIN MBX_MessageItem mi ON mi.MessageItemID = t.MessageItemID AND mi.MessageID = @MessageID
	CROSS APPLY (SELECT dbo.MBX_TaskStatusText(t.TaskID) AS s) st
	HAVING COUNT(*) > 0
)
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
			CAST(NULL AS NVARCHAR(MAX)) AS ToNames,
			ts.TaskState,
			(SELECT STRING_AGG(CAST(mi.ItemLabel AS NVARCHAR(MAX)), ' | ') FROM MBX_MessageItem mi WHERE mi.MessageID = m.MessageID) AS ItemLabels
		FROM MBX_Recipient r
		JOIN MBX_Message m ON m.MessageID = r.MessageID AND m.IsDeleted = 0
		JOIN Users u ON u.UID = m.FromUID
		JOIN Companies c ON c.CID = m.FromCID
		OUTER APPLY dbo.MBX_MessageTaskState(m.MessageID) ts
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
			dbo.MBX_ToNames(m.MessageID) AS ToNames,
			ts.TaskState,
			(SELECT STRING_AGG(CAST(mi.ItemLabel AS NVARCHAR(MAX)), ' | ') FROM MBX_MessageItem mi WHERE mi.MessageID = m.MessageID) AS ItemLabels
		FROM MBX_Message m
		JOIN Users u ON u.UID = m.FromUID
		JOIN Companies c ON c.CID = m.FromCID
		OUTER APPLY dbo.MBX_MessageTaskState(m.MessageID) ts
		WHERE m.FromUID = @UID AND m.IsDeleted = 0
		ORDER BY m.DTCreated DESC
	END
END
GO
