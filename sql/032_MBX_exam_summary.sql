/*
	Exam details for the mailbox's one-line exam summary. Requires 028.

	- MBX_GetMessage: same as 028's version plus ExamName, ExamCompany (the examined
	  company) and ExamMgtCompany (the company that owns the exam,
	  a_aMgtExamNames.OwnerCID) on ExamTask items and on ExamRef copies (taken from the
	  task they came from). The page now shows exams and form applications as a single
	  line with an Open button instead of an embedded viewer.

	Idempotent; safe to run more than once.
*/

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
	DECLARE @IsAuthor BIT = CASE WHEN EXISTS (SELECT 1 FROM MBX_Message WHERE MessageID = @MessageID AND FromUID = @UID) THEN 1 ELSE 0 END
	-- sql/026: or a colleague a task on this message is shared with. They see it as its
	-- sender does in Sent; SharedAccess tells the page how it was shared.
	DECLARE @SharedAccess VARCHAR(10) = NULL
	IF @IsRecipient = 0 AND @IsAuthor = 0
		SELECT TOP 1 @SharedAccess = dbo.MBX_TaskShareAccess(t.TaskID, @UID)
		FROM MBX_MessageItem mi
		JOIN MBX_Task t ON t.MessageItemID = mi.MessageItemID
		WHERE mi.MessageID = @MessageID AND dbo.MBX_TaskShareAccess(t.TaskID, @UID) IS NOT NULL
		ORDER BY CASE dbo.MBX_TaskShareAccess(t.TaskID, @UID) WHEN 'manage' THEN 0 ELSE 1 END

	-- sql/028: or a colleague the assignee shared a task on this message with. They see the
	-- shared task's item as a recipient would, nothing else (no reply, no archive).
	DECLARE @AssigneeSharedAccess VARCHAR(10) = NULL
	IF @IsRecipient = 0 AND @IsAuthor = 0 AND @SharedAccess IS NULL
		SELECT TOP 1 @AssigneeSharedAccess = dbo.MBX_AssigneeShareAccess(t.TaskID, @UID)
		FROM MBX_MessageItem mi
		JOIN MBX_Task t ON t.MessageItemID = mi.MessageItemID
		WHERE mi.MessageID = @MessageID AND dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) IS NOT NULL
		ORDER BY CASE dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) WHEN 'manage' THEN 0 ELSE 1 END

	IF @IsRecipient = 0 AND @IsAuthor = 0 AND @SharedAccess IS NULL AND @AssigneeSharedAccess IS NULL
	BEGIN
		RETURN
	END

	SELECT
		m.MessageID, m.Subject, m.Body, m.DTCreated, m.ReplyToMessageID,
		u.Fname + ' ' + u.Lname AS FromName,
		c.Company AS FromCompany,
		@IsRecipient AS IsRecipient,
		@IsArchived AS IsArchived,
		dbo.MBX_ToNames(m.MessageID) AS ToNames,
		@SharedAccess AS SharedAccess,
		@AssigneeSharedAccess AS AssigneeSharedAccess
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
		CASE WHEN t.TaskID IS NOT NULL THEN dbo.MBX_IsTaskAssignee(t.TaskID, @UID) ELSE 0 END AS IsMyTask,
		CASE WHEN t.TaskID IS NOT NULL THEN dbo.MBX_IsTaskAssigneeOwner(t.TaskID, @UID) ELSE 0 END AS IsAssigneeOwner,
		CASE WHEN t.TaskID IS NOT NULL THEN dbo.MBX_IsTaskAssigner(t.TaskID, @UID) ELSE 0 END AS IsAssigner,
		ot.OriginTaskType,
		ot.OriginTaskStatus,
		ot.OriginDueDate,
		CASE WHEN ot.OriginTaskStatus = 'Pending Review' AND ot.CallerIsAssigner = 1 THEN ot.OriginTaskItemID END AS ReviewTaskItemID,
		ex.ExamName,
		ex.ExamCompany,
		ex.ExamMgtCompany
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
	-- sql/032: an exam item's name and companies, for the one-line summary.
	OUTER APPLY (
		SELECT TOP 1
			n.Name AS ExamName,
			tc.Company AS ExamCompany,
			oc.Company AS ExamMgtCompany
		FROM MBX_Task et
		JOIN a_aMgtExamNames n ON n.ExamID = et.ExamID AND n.Active = 1
		LEFT JOIN Companies tc ON tc.CID = et.ExamCID
		LEFT JOIN Companies oc ON oc.CID = n.OwnerCID
		WHERE mi.ItemType IN ('ExamTask', 'ExamRef')
		AND et.TaskType = 'Exam'
		AND et.MessageItemID = CASE mi.ItemType WHEN 'ExamTask' THEN mi.MessageItemID ELSE TRY_CAST(mi.ItemID AS INT) END
	) ex
	WHERE mi.MessageID = @MessageID
	AND (@AssigneeSharedAccess IS NULL OR dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) IS NOT NULL)
	ORDER BY mi.MessageItemID
END
GO
