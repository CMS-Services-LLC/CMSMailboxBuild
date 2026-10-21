/*
	"Mark as Completed" from the assignee's reply, not only from Sent. Requires 006-013.

	A reply carries the finished Form Application record ('IAFormRecord', ItemID = the
	MainID) or Dynamic Report ('DynamicReport', ItemID = the ReportID), but not the task
	itself. MBX_GetMessage now also returns, for such an item, ReviewTaskItemID: the
	task item (on the original message) whose result it is, when that task is
	waiting for THIS caller's review (Pending Review). The page shows Mark as Completed
	for it, calling the existing item/{ReviewTaskItemID}/task/review.

	"The assigner" is now matched by email as well as UID, in both MBX_GetMessage
	(IsAssigner, ReviewTaskItemID) and MBX_ReviewTask. This is the same rule as the
	alerts (011): a management user who assigned the tasks while switched into a
	downstream company is on a different Users row (same email) from the account they
	log in to the mailbox with.

	- MBX_GetMessage: same as 009's version plus ReviewTaskItemID; IsAssigner by email.
	- MBX_ReviewTask: same as 009's version, assigner matched by email.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 1 when @UID is (any account of) the person who assigned @TaskID.
CREATE OR ALTER FUNCTION [dbo].[MBX_IsTaskAssigner](@TaskID INT, @UID INT)
RETURNS BIT
AS
BEGIN
	DECLARE @r BIT = 0
	SELECT @r = 1
	FROM MBX_Task t
	JOIN Users a ON a.UID = t.AssignedByUID
	JOIN Users me ON me.UID = @UID
	WHERE t.TaskID = @TaskID
	AND (t.AssignedByUID = @UID OR (a.Email = me.Email AND me.Active = 1))
	RETURN @r
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_ReviewTask]
	@UID INT,
	@MessageItemID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @TaskID INT

	SELECT @TaskID = TaskID
	FROM MBX_Task
	WHERE MessageItemID = @MessageItemID
	AND RequiresReview = 1
	AND DTReviewed IS NULL

	IF @TaskID IS NULL OR dbo.MBX_IsTaskAssigner(@TaskID, @UID) = 0
	BEGIN
		SELECT 'no task awaiting your review on this item' AS err
		RETURN
	END

	IF dbo.MBX_TaskIsDone(@TaskID) = 0
	BEGIN
		SELECT 'the assignee has not finished this task yet' AS err
		RETURN
	END

	UPDATE MBX_Task SET ReviewedByUID = @UID, DTReviewed = getdate() WHERE TaskID = @TaskID

	SELECT @TaskID AS TaskID
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
		CASE
			WHEN t.TaskID IS NULL THEN NULL
			WHEN t.Status = 'Cancelled' THEN 'Cancelled'
			WHEN d.Done = 1 AND t.RequiresReview = 1 AND t.DTReviewed IS NULL THEN 'Pending Review'
			WHEN d.Done = 1 THEN 'Completed'
			WHEN t.TaskType = 'FormApplication' AND t.ResultID IS NOT NULL THEN 'Saved'
			WHEN t.TaskType = 'FormApplication' THEN 'Open'
			ELSE t.Status
		END AS TaskStatus,
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
		rv.ReviewTaskItemID
	FROM MBX_MessageItem mi
	LEFT JOIN MBX_Task t ON t.MessageItemID = mi.MessageItemID
	OUTER APPLY (SELECT dbo.MBX_TaskIsDone(t.TaskID) AS Done) d
	OUTER APPLY (
		SELECT TOP 1 fr.DTReleased
		FROM NEO_IAFormRecords xfr
		JOIN NEO_IAFormRecords fr ON fr.RecordID = xfr.RecordID AND fr.active = 1
		WHERE t.TaskType = 'FormApplication' AND xfr.ID = TRY_CAST(t.ResultID AS INT)
	) rel
	-- A reply's copy of a finished task's record/report: the task waiting for this
	-- caller's review, if any.
	OUTER APPLY (
		SELECT TOP 1 rt.MessageItemID AS ReviewTaskItemID
		FROM MBX_Task rt
		WHERE t.TaskID IS NULL
		AND mi.ItemID <> '0'
		AND rt.ResultID = mi.ItemID
		AND rt.TaskType = CASE mi.ItemType WHEN 'IAFormRecord' THEN 'FormApplication' WHEN 'DynamicReport' THEN 'DynamicReport' END
		AND rt.RequiresReview = 1
		AND rt.DTReviewed IS NULL
		AND rt.Status <> 'Cancelled'
		AND dbo.MBX_TaskIsDone(rt.TaskID) = 1
		AND dbo.MBX_IsTaskAssigner(rt.TaskID, @UID) = 1
		ORDER BY rt.TaskID DESC
	) rv
	WHERE mi.MessageID = @MessageID
END
GO
