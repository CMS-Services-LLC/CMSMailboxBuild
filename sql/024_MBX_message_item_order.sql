/*
	Message items in the order they were sent. Requires 020.

	- MBX_GetMessage: same as 020's version, but its items come back ORDER BY
	  MessageItemID, which is the order the sender added them. Assign Tasks lets the
	  assigner put tasks in order, and CMS adds them in that order, so the mailbox shows
	  them the same way. Without an ORDER BY the order wasn't guaranteed.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
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

	SELECT mi.MessageItemID, mi.ItemType, mi.ItemID, mi.ItemLabel, mi.FormID,
		t.TaskID, t.TaskType,
		dbo.MBX_TaskStatusText(t.TaskID) AS TaskStatus,
		CASE
			WHEN d.Done = 0 THEN NULL
			WHEN t.RequiresReview = 1 THEN t.DTReviewed
			WHEN t.TaskType = 'FormApplication' THEN rel.DTReleased
			ELSE t.DTCompleted
		END AS TaskCompleted,
		t.DueDate,
		t.RequiresReview,
		CASE WHEN t.AssignedToUID = @UID THEN 1 ELSE 0 END AS IsMyTask,
		CASE WHEN t.TaskID IS NOT NULL THEN dbo.MBX_IsTaskAssigner(t.TaskID, @UID) ELSE 0 END AS IsAssigner,
		ot.OriginTaskType,
		ot.OriginTaskStatus,
		ot.OriginDueDate,
		CASE WHEN ot.OriginTaskStatus = 'Pending Review' AND ot.CallerIsAssigner = 1 THEN ot.OriginTaskItemID END AS ReviewTaskItemID
	FROM MBX_MessageItem mi
	LEFT JOIN MBX_Task t ON t.MessageItemID = mi.MessageItemID
	OUTER APPLY (SELECT dbo.MBX_TaskIsDone(t.TaskID) AS Done) d
	OUTER APPLY (
		SELECT TOP 1 fr.DTReleased
		FROM NEO_IAFormRecords xfr
		JOIN NEO_IAFormRecords fr ON fr.RecordID = xfr.RecordID AND fr.active = 1
		WHERE t.TaskType = 'FormApplication' AND xfr.ID = TRY_CAST(t.ResultID AS INT)
	) rel
	-- A reply's copy of a task's record/report/exam: the task it came from, if the
	-- caller is that task's assignee or assigner.
	OUTER APPLY (
		SELECT TOP 1
			rt.MessageItemID AS OriginTaskItemID,
			rt.TaskType AS OriginTaskType,
			dbo.MBX_TaskStatusText(rt.TaskID) AS OriginTaskStatus,
			rt.DueDate AS OriginDueDate,
			dbo.MBX_IsTaskAssigner(rt.TaskID, @UID) AS CallerIsAssigner
		FROM MBX_Task rt
		WHERE t.TaskID IS NULL
		AND mi.ItemID <> '0'
		AND (
			(mi.ItemType = 'ExamRef' AND rt.TaskType = 'Exam' AND rt.MessageItemID = TRY_CAST(mi.ItemID AS INT))
			OR (rt.ResultID = mi.ItemID
				AND rt.TaskType = CASE mi.ItemType WHEN 'IAFormRecord' THEN 'FormApplication' WHEN 'DynamicReport' THEN 'DynamicReport' END)
		)
		AND (dbo.MBX_IsTaskAssigner(rt.TaskID, @UID) = 1 OR dbo.MBX_IsTaskAssignee(rt.TaskID, @UID) = 1)
		ORDER BY rt.TaskID DESC
	) ot
	WHERE mi.MessageID = @MessageID
	ORDER BY mi.MessageItemID
END
GO
