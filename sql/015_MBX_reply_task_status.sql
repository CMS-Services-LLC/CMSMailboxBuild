/*
	Replies show the original task's status. Requires 006-014.

	A reply carries a copy of a task's record/report ('IAFormRecord' ItemID = MainID,
	'DynamicReport' ItemID = ReportID) but not the task. 014 only linked that copy back
	to its task for the assigner while it awaited review. Now every reply copy reports
	the original task's current status (Open / Saved / Pending Review / Completed), to
	the task's assignee or assigner (matched by email, as in 014), so e.g. the
	assigner's "well done" reply shows the task as Completed to the assignee.

	- MBX_TaskStatusText: new. The one definition of a task's displayed status (the
	  CASE MBX_GetMessage has used since 009), shared by both uses below.
	- MBX_GetMessage: same as 014's version plus OriginTaskType / OriginTaskStatus /
	  OriginDueDate on reply copies (ReviewTaskItemID unchanged).

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER FUNCTION [dbo].[MBX_TaskStatusText](@TaskID INT)
RETURNS VARCHAR(20)
AS
BEGIN
	DECLARE @s VARCHAR(20)
	SELECT @s = CASE
			WHEN t.Status = 'Cancelled' THEN 'Cancelled'
			WHEN dbo.MBX_TaskIsDone(t.TaskID) = 1 AND t.RequiresReview = 1 AND t.DTReviewed IS NULL THEN 'Pending Review'
			WHEN dbo.MBX_TaskIsDone(t.TaskID) = 1 THEN 'Completed'
			WHEN t.TaskType = 'FormApplication' AND t.ResultID IS NOT NULL THEN 'Saved'
			WHEN t.TaskType = 'FormApplication' THEN 'Open'
			ELSE t.Status
		END
	FROM MBX_Task t
	WHERE t.TaskID = @TaskID
	RETURN @s
END
GO

-- 1 when @UID is (any account of) the assignee of @TaskID.
CREATE OR ALTER FUNCTION [dbo].[MBX_IsTaskAssignee](@TaskID INT, @UID INT)
RETURNS BIT
AS
BEGIN
	DECLARE @r BIT = 0
	SELECT @r = 1
	FROM MBX_Task t
	JOIN Users a ON a.UID = t.AssignedToUID
	JOIN Users me ON me.UID = @UID
	WHERE t.TaskID = @TaskID
	AND (t.AssignedToUID = @UID OR (a.Email = me.Email AND me.Active = 1))
	RETURN @r
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
	-- A reply's copy of a task's record/report: the task it came from, if the caller
	-- is that task's assignee or assigner.
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
		AND rt.ResultID = mi.ItemID
		AND rt.TaskType = CASE mi.ItemType WHEN 'IAFormRecord' THEN 'FormApplication' WHEN 'DynamicReport' THEN 'DynamicReport' END
		AND (dbo.MBX_IsTaskAssigner(rt.TaskID, @UID) = 1 OR dbo.MBX_IsTaskAssignee(rt.TaskID, @UID) = 1)
		ORDER BY rt.TaskID DESC
	) ot
	WHERE mi.MessageID = @MessageID
END
GO
