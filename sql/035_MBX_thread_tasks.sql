/*
	Show the original task(s) in a reply's conversation view. Requires 030 (MBX_GetThread)
	and 033 (MBX_CanOpenItem with the sender rule).

	- Why: MBX_SendReply only copies a task onto a reply once it has been started
	  (Form Application / Dynamic Report items with ItemID <> '0'; exams always). A reply
	  sent before that carries no task, and a task started after the reply never appears
	  on it, so the reply showed the conversation text with no task in it.
	- MBX_GetThread: same as 030's version, plus a THIRD result set: the task items on the
	  thread's messages (one row per MBX_Task), with the task's current status. Only items
	  the caller can open (dbo.MBX_CanOpenItem), so an assignee-share colleague still sees
	  only the shared task. Nothing is copied or changed; the page lists these tasks under
	  each earlier message with a link that opens that message.

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

	-- sql/035: the tasks on the thread's messages, with their current status.
	SELECT mi.MessageItemID, mi.MessageID, mi.ItemType, mi.ItemLabel,
		tk.TaskID, tk.TaskType,
		dbo.MBX_TaskStatusText(tk.TaskID) AS TaskStatus,
		tk.DueDate,
		n.Name AS ExamName
	FROM @thread t
	JOIN MBX_MessageItem mi ON mi.MessageID = t.MessageID
	JOIN MBX_Task tk ON tk.MessageItemID = mi.MessageItemID
	LEFT JOIN a_aMgtExamNames n ON tk.TaskType = 'Exam' AND n.ExamID = tk.ExamID AND n.Active = 1
	WHERE dbo.MBX_CanOpenItem(mi.MessageItemID, @UID) = 1
	ORDER BY mi.MessageID, mi.MessageItemID
END
GO
