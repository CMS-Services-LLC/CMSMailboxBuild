/*
	Exam tasks (Phase 3 of WizardAssignments_Plan.md). Requires 006-015.

	A management-company user assigns one of its exams, already shared with a
	downstream company, to a user at that company (the examined company). The
	assignee works it in CMSMailbox's exam viewer (a port of CMSNEO's
	managementExamsNEW.js). The scope is answering questions and uploading documents
	for document requests.

	Status: Open, then Pending Review as soon as the assignee begins (first answer or
	upload: MBX_MarkExamTaskStarted sets ResultID = ExamID), then Completed only when
	the assigner clicks Mark as Completed (the existing MBX_ReviewTask). Exam tasks are
	always created with RequiresReview = 1, because an exam is a back-and-forth that
	only the assigner can call finished.

	CMSNEO's exam write procs (NEO_MgtUpdateAnswers, NEO_MgtUpdateAnswer,
	NEO_MgtDeleteFormDoc, ...) check nothing, so CMSMailbox's ExamViewerController
	gates every call with MBX_GetExamTask (below) and pins examid/xcid to the task's.

	- MBX_MessageItem.ItemType: allows 'ExamTask'.
	- MBX_CreateTask: also takes @ExamID / @ExamCID (columns since 006).
	- MBX_GetAssignableExams: the exams the caller's company owns that are shared with
	  a downstream company the caller can see (the Assign Tasks Exams tab).
	- MBX_GetExamTaskCandidates: users at the examined company with Exams access.
	- MBX_GetExamTask: the gate for the exam viewer.
	- MBX_MarkExamTaskStarted: Open, then Pending Review.
	- MBX_TaskIsDone: an exam task counts as "done" (so Pending Review) once started.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER TABLE [dbo].[MBX_MessageItem] DROP CONSTRAINT [CK_MBX_MessageItem_ItemType]
GO
ALTER TABLE [dbo].[MBX_MessageItem] WITH CHECK ADD CONSTRAINT [CK_MBX_MessageItem_ItemType]
CHECK ([ItemType] IN ('File','FollowupAttachment','IAField','DRField','ExamFile','IAFormRecord','DRTask','DynamicReport','ExamTask'))
GO
ALTER TABLE [dbo].[MBX_MessageItem] CHECK CONSTRAINT [CK_MBX_MessageItem_ItemType]
GO

-- Same as 009's version plus @ExamID / @ExamCID.
CREATE OR ALTER PROCEDURE [dbo].[MBX_CreateTask]
	@UID INT,
	@MessageItemID INT,
	@TaskType VARCHAR(20),
	@AssignedToUID INT,
	@FormID VARCHAR(100) = NULL,
	@DueDate VARCHAR(20) = NULL,
	@ReportName NVARCHAR(255) = NULL,
	@ReportType NVARCHAR(100) = NULL,
	@TemplateFileName NVARCHAR(255) = NULL,
	@TemplateHeaders NVARCHAR(MAX) = NULL,
	@TemplateBytes VARBINARY(MAX) = NULL,
	@RequiresReview BIT = 0,
	@ExamID VARCHAR(100) = NULL,
	@ExamCID INT = NULL
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF NOT EXISTS (
		SELECT 1
		FROM MBX_MessageItem mi
		JOIN MBX_Message m ON m.MessageID = mi.MessageID AND m.FromUID = @UID
		JOIN MBX_Recipient r ON r.MessageID = mi.MessageID AND r.ToUID = @AssignedToUID
		WHERE mi.MessageItemID = @MessageItemID
	)
	BEGIN
		SELECT 'not the author of this message, or assignee is not a recipient' AS err
		RETURN
	END

	INSERT INTO MBX_Task (MessageItemID, TaskType, AssignedByUID, AssignedToUID, FormID, DueDate,
		ReportName, ReportType, TemplateFileName, TemplateHeaders, TemplateBytes, RequiresReview, ExamID, ExamCID)
	SELECT @MessageItemID, @TaskType, @UID, @AssignedToUID, NULLIF(@FormID, ''), TRY_CONVERT(date, NULLIF(@DueDate, '')),
		NULLIF(@ReportName, ''), NULLIF(@ReportType, ''), NULLIF(@TemplateFileName, ''), NULLIF(@TemplateHeaders, ''), @TemplateBytes,
		CASE WHEN @TaskType = 'Exam' THEN 1 ELSE ISNULL(@RequiresReview, 0) END,
		NULLIF(@ExamID, ''), @ExamCID

	SELECT SCOPE_IDENTITY() AS TaskID
END
GO

-- Exams the caller's company owns, shared (Shared = 1, active) with a downstream
-- company the caller can see (AccessTreeDown, Down = 1). Only shared exams are
-- listed: the examined company can't open an exam that isn't shared with it.
CREATE OR ALTER PROCEDURE [dbo].[MBX_GetAssignableExams]
	@UID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @MyCID INT = dbo.mycid(@UID)

	SELECT DISTINCT s.xCID AS XCID, c.Company, n.ExamID, n.Name AS ExamName
	FROM a_aMgtExamNames n
	JOIN a_aMgtExamShare s ON s.ExamID = n.ExamID AND s.Active = 1 AND s.Shared = 1
	JOIN AccessTreeDown(@UID) atd ON atd.CID = s.xCID AND atd.Down = 1
	JOIN Companies c ON c.CID = s.xCID
	WHERE n.Active = 1
	AND n.OwnerCID = @MyCID
	AND s.xCID <> @MyCID
	ORDER BY c.Company, n.Name
END
GO

-- Users at the examined company (@XCID) who can work exams: the 'Exams' user-group
-- permission or Global Admin, deduped to each person's real MGT account. Empty unless
-- @ExamID is one MBX_GetAssignableExams would offer the caller for @XCID.
CREATE OR ALTER PROCEDURE [dbo].[MBX_GetExamTaskCandidates]
	@UID INT,
	@XCID INT,
	@ExamID VARCHAR(100)
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @MyCID INT = dbo.mycid(@UID)

	IF NOT EXISTS (
		SELECT 1
		FROM a_aMgtExamNames n
		JOIN a_aMgtExamShare s ON s.ExamID = n.ExamID AND s.xCID = @XCID AND s.Active = 1 AND s.Shared = 1
		JOIN AccessTreeDown(@UID) atd ON atd.CID = @XCID AND atd.Down = 1
		WHERE n.ExamID = @ExamID AND n.Active = 1 AND n.OwnerCID = @MyCID AND @XCID <> @MyCID
	)
		RETURN

	SELECT DISTINCT u.MgtUID AS UID, u.Name, u.Email, u.Company
	FROM neousers(@UID) u
	JOIN NEO_SecurityGroupAssignments sga ON sga.uid = u.MgtUID AND sga.active = 1
	JOIN vwSecurityGroups sg ON sg.GroupID = sga.groupid AND sg.action IN ('Exams', 'Global Administrator')
	WHERE u.cid = @XCID
	AND u.MgtUID <> @UID
	ORDER BY u.Name
END
GO

-- The exam viewer's gate, run on every request. Returns the task only when:
--   - the item is an ExamTask on a message the caller received,
--   - the caller is the task's assignee (any of their accounts, by email),
--   - the caller's company tree reaches the examined company (AccessTreeDown, Down = 1,
--     the same rule as exam snapshots; never mgtCID),
--   - the exam is still active and shared with that company.
-- CanWrite = 0 once the task is Completed or Cancelled (the viewer goes read-only).
CREATE OR ALTER PROCEDURE [dbo].[MBX_GetExamTask]
	@UID INT,
	@MessageItemID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	SELECT t.TaskID, t.ExamID, t.ExamCID, n.Name AS ExamName, c.Company AS ExamCompany,
		dbo.MBX_TaskStatusText(t.TaskID) AS TaskStatus,
		CAST(CASE WHEN dbo.MBX_TaskStatusText(t.TaskID) IN ('Completed', 'Cancelled') THEN 0 ELSE 1 END AS BIT) AS CanWrite
	FROM MBX_Task t
	JOIN MBX_MessageItem mi ON mi.MessageItemID = t.MessageItemID AND mi.ItemType = 'ExamTask'
	JOIN MBX_Recipient r ON r.MessageID = mi.MessageID AND r.ToUID = @UID
	JOIN a_aMgtExamNames n ON n.ExamID = t.ExamID AND n.Active = 1
	JOIN a_aMgtExamShare s ON s.ExamID = t.ExamID AND s.xCID = t.ExamCID AND s.Active = 1 AND s.Shared = 1
	JOIN AccessTreeDown(@UID) atd ON atd.CID = t.ExamCID AND atd.Down = 1
	JOIN Companies c ON c.CID = t.ExamCID
	WHERE t.MessageItemID = @MessageItemID
	AND t.TaskType = 'Exam'
	AND dbo.MBX_IsTaskAssignee(t.TaskID, @UID) = 1
END
GO

-- First answer or upload: Open, then Pending Review (see MBX_TaskIsDone).
CREATE OR ALTER PROCEDURE [dbo].[MBX_MarkExamTaskStarted]
	@UID INT,
	@MessageItemID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	UPDATE t SET ResultID = t.ExamID
	FROM MBX_Task t
	WHERE t.MessageItemID = @MessageItemID
	AND t.TaskType = 'Exam'
	AND t.ResultID IS NULL
	AND dbo.MBX_IsTaskAssignee(t.TaskID, @UID) = 1
END
GO

-- Same as 009's version plus: an exam task is "done" (so Pending Review, since exam
-- tasks always require review) once the assignee has started it.
CREATE OR ALTER FUNCTION [dbo].[MBX_TaskIsDone](@TaskID INT)
RETURNS BIT
AS
BEGIN
	DECLARE @done BIT = 0

	SELECT @done = 1
	FROM MBX_Task t
	WHERE t.TaskID = @TaskID
	AND t.Status <> 'Cancelled'
	AND (
		(t.TaskType = 'DynamicReport' AND t.Status = 'Completed')
		OR (t.TaskType = 'Exam' AND t.ResultID IS NOT NULL)
		OR (t.TaskType = 'FormApplication' AND EXISTS (
			SELECT 1
			FROM NEO_IAFormRecords xfr
			JOIN NEO_IAFormRecords fr ON fr.RecordID = xfr.RecordID AND fr.active = 1
			WHERE xfr.ID = TRY_CAST(t.ResultID AS INT) AND fr.DTReleased IS NOT NULL
		))
	)

	RETURN @done
END
GO
